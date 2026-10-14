import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

extension DockCore {
    // MARK: - Intelligent L2 Query Handling



    /// On-screen text / files the user attached to the frontmost-app chat via its +
    /// menu (Capture Text, screenshots, uploads) — injected so the scoped model can
    /// act on what's visible (e.g. a captured Messages thread).
    func contextDockChatAttachmentPromptBlock() -> String {
        contextDockChatAttachmentPromptBlock(
            files: contextDockChatFiles,
            capturedText: contextDockChatCapturedText
        )
    }

    func contextDockChatAttachmentPromptBlock(files: [URL], capturedText: String?) -> String {
        var parts: [String] = []
        if let captured = capturedText?
            .trimmingCharacters(in: .whitespacesAndNewlines), !captured.isEmpty
        {
            parts.append(
                "CAPTURED ON-SCREEN TEXT (use this to answer the user):\n"
                    + String(captured.prefix(4000)))
        }
        if !files.isEmpty {
            let imageExts: Set<String> = [
                "png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp",
            ]
            let submittedFiles = Array(files.prefix(10))
            let imageFiles = submittedFiles.filter { imageExts.contains($0.pathExtension.lowercased()) }
            let docFiles = submittedFiles.filter { !imageExts.contains($0.pathExtension.lowercased()) }

            // Screenshots / Capture Area are images — the scoped agentic path can't send vision,
            // so OCR them locally and inject the recognized text. This is what makes a captured
            // screen actually usable in the chat (e.g. "summarize this error").
            var blocks: [String] = []
            for url in imageFiles {
                let outcome = ocrOutcomeFromImageFile(url)
                let text = outcome.text
                if text.isEmpty {
                    blocks.append("- " + outcome.summary(label: url.lastPathComponent))
                } else {
                    blocks.append(
                        "### \(url.lastPathComponent) (screenshot, recognized text)\n"
                            + String(text.prefix(3000)))
                }
            }
            if !docFiles.isEmpty {
                let analyzed = ContextDetector.shared.analyzeFiles(docFiles)
                for item in analyzed {
                    guard let content = item.content?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
                    else {
                        blocks.append("- \(item.url.lastPathComponent) (\(item.type))")
                        continue
                    }
                    blocks.append(
                        "### \(item.url.lastPathComponent) (\(item.type))\n"
                            + String(content.prefix(3000)))
                }
            }
            if !blocks.isEmpty {
                parts.append("ATTACHED FILES (use these):\n\n" + blocks.joined(separator: "\n\n"))
            }
        }
        return parts.isEmpty ? "" : "\n\n" + parts.joined(separator: "\n\n")
    }

    /// Local Vision OCR for an image file the user attached/captured in the scoped chat.
    /// Synchronous (Vision `perform` is sync) — fine for a single user-initiated capture.
    /// The shared recogniser (`ScreenCaptureService`), so the Dock and the Corner read an
    /// attached screenshot the same way and both can tell "no text" from "could not read".
    func ocrOutcomeFromImageFile(_ url: URL) -> OCROutcome {
        guard let data = try? Data(contentsOf: url) else {
            return .failed(reason: "the file could not be read")
        }
        return ScreenCaptureService.recognizeTextOutcome(in: data)
    }



}
