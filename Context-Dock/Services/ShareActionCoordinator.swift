import AppKit
import ObjectiveC
import SwiftUI

@MainActor
final class ShareActionCoordinator {
    static let shared = ShareActionCoordinator()

    private init() {}

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
