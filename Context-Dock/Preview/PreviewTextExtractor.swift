// PreviewTextExtractor.swift
// Context-Dock
//
// What the assistant beside a preview is allowed to read. The panel shows the file;
// without this the model could only see its name and size, so it answered "I cannot
// access the contents" to every question about the document on screen.
//
// Off the main actor: MarkItDown shells out, PDFKit parses, Vision runs OCR. Any of
// those on the render path would stall the window that just opened.

import AppKit
import Foundation
import Vision

enum PreviewTextExtractor {
    /// Roughly what a preview's worth of context should cost. The extractor below
    /// already truncates documents at its own budget; this is the second clamp for
    /// OCR, which has none.
    private static let characterBudget = 16_000

    static func text(for item: PreviewItem) async -> String? {
        let url = item.url
        let kind = item.kind
        return await Task.detached(priority: .userInitiated) { () -> String? in
            switch kind {
            case .text, .document:
                return AIAttachmentPreparer.extractedText(from: url)
            case .image:
                return ocr(url)
            case .folder, .web:
                return nil
            }
        }.value
    }

    /// Screenshots are the common case in this app, and their whole content is text.
    private static func ocr(_ url: URL) -> String? {
        guard let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return nil }

        let joined = lines.joined(separator: "\n")
        return joined.count > characterBudget
            ? String(joined.prefix(characterBudget)) + "\n\n*(truncated)*"
            : joined
    }
}
