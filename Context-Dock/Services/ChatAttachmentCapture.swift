// ChatAttachmentCapture.swift
// Context-Dock
//
// File picking, screenshots and OCR for any AI surface's "+" menu.
//
// These lived as methods on LauncherView, which meant the chat window could offer
// only a bare file picker while the dock offered five ways to attach — the same
// button doing different things on different surfaces. Nothing here ever touched
// LauncherView's state, so it is plain shared code and both surfaces call it.

import AppKit
import UniformTypeIdentifiers
import Vision

@MainActor
enum ChatAttachmentCapture {

    /// Open panel that returns the chosen file URLs.
    static func pickFiles(imagesOnly: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = imagesOnly ? [.image] : [.image, .pdf, .plainText, .data]
        panel.message = "Choose files to attach to your message"
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Capture a screenshot and hand the PNG to `append` on the main actor. Modes:
    /// full screen (`-x`); interactive area (`-i`, drag a region); or `windowFirst`, which
    /// uses our custom overlay (InteractiveCaptureOverlay) — hover a window to highlight and
    /// click it, or move over the empty desktop to auto-switch to a crosshair for a custom
    /// area, with NO Space key. Requires Screen Recording permission; a denied capture writes
    /// nothing.
    static func captureScreenshot(
        interactive: Bool, windowFirst: Bool = false, append: @escaping (URL) -> Void
    ) {
        // Post-capture: mirror to clipboard (like Capture Text) then hand back the URL.
        let deliver: (URL?) -> Void = { url in
            guard let url,
                FileManager.default.fileExists(atPath: url.path),
                (try? Data(contentsOf: url))?.isEmpty == false
            else { return }
            if let image = NSImage(contentsOf: url) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
            }
            append(url)
        }

        // Window-first uses the custom overlay: cursor over a window → window capture; over
        // the desktop → crosshair area capture. No Space toggle.
        if interactive, windowFirst {
            InteractiveCaptureOverlay.capture(completion: deliver)
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-dock-shot-\(UUID().uuidString).png")
        let args: [String] = (interactive ? ["-i"] : ["-x"]) + [url.path]
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = args
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return
            }
            await MainActor.run { deliver(url) }
        }
    }

    /// Select a screen region, recognize its text locally with Vision, copy the
    /// result to the clipboard, and return it to the calling surface.
    static func captureScreenText(append: @escaping (String) -> Void) {
        captureScreenshot(interactive: true) { url in
            Task.detached(priority: .userInitiated) {
                defer { try? FileManager.default.removeItem(at: url) }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                do {
                    try VNImageRequestHandler(url: url, options: [:]).perform([request])
                    let text = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    await MainActor.run {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                        append(text)
                    }
                } catch {
                    return
                }
            }
        }
    }
}
