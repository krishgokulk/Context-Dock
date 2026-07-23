import AppKit
import ObjectiveC
import SwiftUI

/// A single resolved native share destination, ready to render as a DoraX pill.
/// Carries the actual NSSharingService OBJECT so execution is by object identity
/// (`service.perform(withItems:)`) — never resolved by title, which mis-picked the
/// first service (the "always AirDrop" bug). Discovered via
/// `NSSharingService.sharingServices(forItems:)`, so it includes every installed
/// share-extension (Downie, LocalSend, Bridges, …), exactly like the system sheet.
struct ShareDestinationEntry: Identifiable {
    let title: String
    let image: NSImage?
    let service: NSSharingService
    var id: String { title }

    /// Run this exact service with freshly-resolved items (e.g. the live page URL).
    /// Routed through the coordinator so share-EXTENSION targets get a host window to
    /// present their compose sheet (see `performDirectShare`).
    @MainActor
    func perform(withItems items: [Any]) {
        ShareActionCoordinator.shared.performDirectShare(
            service, items: items, title: title
        ) {}
    }
}

@MainActor
final class ShareActionCoordinator {
    static let shared = ShareActionCoordinator()

    private init() {}

    /// One row per native macOS share destination for the given items — the exact
    /// list the system Share Sheet would show (AirDrop, Mail, Messages, Notes, plus
    /// every installed share-extension), with each app's real icon. Lets DoraX render
    /// the share sheet inline as pills instead of bouncing to NSSharingServicePicker.
    func shareDestinations(items: [Any]) -> [ShareDestinationEntry] {
        guard !items.isEmpty else { return [] }
        return NSSharingService.sharingServices(forItems: items).compactMap { service in
            let title = service.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ShareDestinationEntry(title: title, image: service.image, service: service)
        }
    }

    func presentSharingPicker(
        items: [Any],
        setActive: @escaping (Bool) -> Void
    ) {
        guard !items.isEmpty else { return }

        let picker = NSSharingServicePicker(items: items)
        let coordinator = SharePickerCoordinator {
            setActive(false)
        }
        picker.delegate = coordinator
        objc_setAssociatedObject(
            picker,
            &SharePickerCoordinator.key,
            coordinator,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        setActive(true)
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                let view = window.contentView
            else {
                setActive(false)
                return
            }
            let rect = NSRect(x: window.frame.width / 2 - 60, y: 52, width: 120, height: 1)
            picker.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        }
    }

    /// Perform a specific share destination WITHOUT the picker, but reliably for
    /// share-EXTENSION targets (Freeform, Notes, Reminders, Journal, Shortcuts…).
    ///
    /// Those extensions render their own compose sheet, which needs a host window to
    /// anchor to. If DoraX hides its overlay first, `perform` has nothing to present
    /// into and the target app merely launches WITHOUT the shared content. So we:
    ///   1. keep the current key window and hand it back via the service delegate's
    ///      `sourceWindowForShareItems`, and
    ///   2. only run `onFinish` (which hides the launcher) after the share actually
    ///      completes / fails — with a safety timeout in case the extension never
    ///      calls back (e.g. the user dismisses its sheet).
    func performDirectShare(
        _ service: NSSharingService,
        items: [Any],
        title: String,
        onFinish: @escaping () -> Void
    ) {
        guard !items.isEmpty else {
            AppToast.show("Nothing to share", icon: "exclamationmark.triangle", tint: .orange)
            onFinish()
            return
        }

        // A third-party share EXTENSION (Freeform/Notes/Reminders…) will only present its
        // compose sheet when the requesting app is a foreground .regular app. Our launcher
        // runs .accessory, so a direct perform there just launches the target app with no
        // sheet and no content. Elevate to .regular for the duration of the share and
        // restore the previous policy once it completes/fails/times out.
        let previousPolicy = NSApp.activationPolicy()

        var finished = false
        let finishOnce = {
            guard !finished else { return }
            finished = true
            if NSApp.activationPolicy() != previousPolicy {
                NSApp.setActivationPolicy(previousPolicy)
            }
            onFinish()
        }

        // Return NO source window: a foreground .regular app lets the extension present
        // its compose sheet in its OWN standalone window (as Finder does). Donating our
        // launcher panel instead attaches the sheet as a child of our window, so it renders
        // embedded inside our dark overlay. The delegate is kept only for completion.
        let delegate = ShareServiceDelegate(
            sourceWindow: nil,
            onFinish: finishOnce
        )
        service.delegate = delegate
        objc_setAssociatedObject(
            service,
            &ShareServiceDelegate.key,
            delegate,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        // Foreground the app as .regular so the extension presents its own sheet instead of
        // quietly opening the app in the background. Don't pull our launcher window forward.
        if previousPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Let the policy/activation change settle one runloop before performing, otherwise
        // the extension still sees a background host and falls back to a plain app launch.
        DispatchQueue.main.async {
            service.perform(withItems: items)
        }
        AppToast.show("Sharing via \(title)", icon: "square.and.arrow.up", tint: .blue)

        // Safety net: if the extension never reports back, still release the overlay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finishOnce() }
    }

    func executeShareDestination(
        title: String,
        normalizedTitle: String,
        items: [Any],
        presentSharingPicker: @escaping ([Any]) -> Void
    ) {
        guard !normalizedTitle.isEmpty else { return }

        guard !items.isEmpty else {
            AppToast.show("Nothing to share", icon: "exclamationmark.triangle", tint: .orange)
            return
        }

        if normalizedTitle == "share" || normalizedTitle == "share..." || normalizedTitle == "share…" {
            presentSharingPicker(items)
            return
        }

        guard let destination = ShareDestinationResolver.resolve(query: title, items: items) else {
            presentSharingPicker(items)
            return
        }

        performDirectShare(destination.service, items: items, title: destination.title) {}
    }
}

/// Feeds a share EXTENSION the host window it needs to present its compose sheet,
/// and reports completion so the caller can dismiss the launcher afterwards (never
/// before — see `performDirectShare`).
private final class ShareServiceDelegate: NSObject, NSSharingServiceDelegate {
    static var key: UInt8 = 0
    private let sourceWindow: NSWindow?
    private let onFinish: () -> Void

    init(sourceWindow: NSWindow?, onFinish: @escaping () -> Void) {
        self.sourceWindow = sourceWindow
        self.onFinish = onFinish
    }

    func sharingService(
        _ sharingService: NSSharingService,
        sourceWindowForShareItems items: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        sourceWindow
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        onFinish()
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: Error
    ) {
        onFinish()
    }
}

struct TransformShareContentReader {
    static func readableContent(from urls: [URL])
        -> (summary: String, content: String, primaryFileName: String)
    {
        let files = Array(urls.prefix(3))
        let analyses = ContextDetector.shared.analyzeFiles(files)
        var chunks: [String] = []
        var summaryLines: [String] = []

        for analysis in analyses {
            summaryLines.append(
                "- \(analysis.url.lastPathComponent) (\(analysis.type), \(analysis.size))")
            guard
                let content = analysis.content?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !content.isEmpty
            else { continue }
            chunks.append(
                """
                FILE: \(analysis.url.lastPathComponent)
                CONTENT:
                \(String(content.prefix(6000)))
                """
            )
        }

        return (
            summaryLines.joined(separator: "\n"),
            chunks.joined(separator: "\n\n---\n\n"),
            files.first?.lastPathComponent ?? "selected file"
        )
    }

    static func prompt(
        userMessage: String,
        fileSummary: String,
        fileContent: String
    ) -> String {
        """
        The user wants a generated message derived from the selected file, then sent to someone.

        User request:
        \(userMessage)

        Selected file metadata:
        \(fileSummary)

        Selected file text:
        \(fileContent)

        Produce only the message body to send. Keep it short unless the user asked otherwise.
        Do not mention implementation details, file paths, or that you are an AI.
        """
    }
}
