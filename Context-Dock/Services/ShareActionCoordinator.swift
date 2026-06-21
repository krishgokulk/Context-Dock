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
    func perform(withItems items: [Any]) {
        service.perform(withItems: items)
        AppToast.show("Sharing via \(title)", icon: "square.and.arrow.up", tint: .blue)
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

        destination.service.perform(withItems: items)
        AppToast.show("Sharing via \(destination.title)", icon: "square.and.arrow.up", tint: .blue)
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
