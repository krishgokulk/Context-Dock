// ClipboardIngestBus.swift
// Context-Dock
//
// Typed hand-off for clips the app itself produces (Capture Text, Capture Area,
// Screenshot). The clipboard scope's own poll can only guess where a clip came from —
// screencapture is frontmost while it runs, so a polled import would land with the
// wrong source app, and for OCR text it would race the pasteboard write. Producers
// publish here instead: the payload carries the real source app, the pasteboard
// changeCount their write produced (so the poll doesn't import the same clip twice),
// and the exact bytes.

import Combine
import Foundation

struct ClipboardCapturePayload: Sendable {
    enum Content: Sendable {
        case text(String)
        /// PNG bytes plus the on-disk screenshot the user asked us to keep, if any.
        case image(Data, savedFilePath: String?)
    }

    let content: Content
    let sourceAppName: String
    let sourceBundleId: String
    /// `NSPasteboard.general.changeCount` right after the producer wrote the clip.
    let pasteboardChangeCount: Int
    /// Capture Text / Capture Area / Screenshot rather than a Cmd-C somewhere else.
    var isScreenCapture: Bool = true
}

@MainActor
final class ClipboardIngestBus {
    static let shared = ClipboardIngestBus()
    private init() {}

    let captures = PassthroughSubject<ClipboardCapturePayload, Never>()

    func publish(_ payload: ClipboardCapturePayload) {
        captures.send(payload)
    }
}
