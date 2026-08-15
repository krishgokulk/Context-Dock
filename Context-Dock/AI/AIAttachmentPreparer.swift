import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Converts user attachments into model-ready inputs before a request is sent.
///
/// Third-party chat-completion endpoints only accept a narrow shape: text plus a
/// few image MIME types. They do not take raw PDFs or office documents, and most
/// reject anything outside png/jpeg/gif/webp. Apple's Siri sidesteps this by running
/// every file through a system parser before the model sees it. We do the same here:
///
/// - `imageBlocks` normalizes *any* image format (heic, tiff, bmp, …) to png/jpeg so
///   it survives the Anthropic/OpenAI vision endpoints, which silently 400 on the
///   formats `mediaType(for:)` used to mislabel.
/// - `extractedText` pulls readable text out of PDFs and documents so a provider that
///   "doesn't support files" can still reason about them — the text rides in the prompt.
enum AIAttachmentPreparer {
    /// Per-file cap so a large document can't blow the context window.
    private static let maxCharactersPerFile = 16_000

    /// Image MIME types every supported vision endpoint accepts as-is.
    private static let nativeImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    // MARK: - Images

    /// Returns base64 image blocks with a provider-safe media type. Formats outside the
    /// native set are transcoded to PNG via ImageIO so they are not rejected downstream.
    static func imageBlocks(for attachments: [AIAttachment]) -> [(data: String, mediaType: String)] {
        attachments.compactMap { attachment in
            guard attachment.kind == .image else { return nil }
            let ext = attachment.url.pathExtension.lowercased()
            if nativeImageExtensions.contains(ext),
                let data = try? Data(contentsOf: attachment.url)
            {
                return (data.base64EncodedString(), mediaType(forExtension: ext))
            }
            // Transcode heic/tiff/bmp/etc. to PNG so vision endpoints accept it.
            guard let png = pngData(from: attachment.url) else { return nil }
            return (png.base64EncodedString(), "image/png")
        }
    }

    /// Same as `imageBlocks(for:)` but from raw file URLs — used by the agentic tool loops
    /// (sendWithTools) which carry attachment URLs, not AIAttachment values. Non-image URLs
    /// are dropped; non-native formats are transcoded to PNG.
    static func imageBlocks(forURLs urls: [URL]) -> [(data: String, mediaType: String)] {
        let imageExts: Set<String> = [
            "png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp",
        ]
        return urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard imageExts.contains(ext) else { return nil }
            if nativeImageExtensions.contains(ext), let data = try? Data(contentsOf: url) {
                // A photo straight off a camera or phone is several megabytes, and vision
                // endpoints reject an image over roughly five once base64 has added a
                // third. Downscaling loses nothing that matters for "what is this" and is
                // the difference between an answer and a 400 the user cannot act on.
                if data.count > maxImageBytes, let smaller = downscaledJPEG(from: url) {
                    return (smaller.base64EncodedString(), "image/jpeg")
                }
                return (data.base64EncodedString(), mediaType(forExtension: ext))
            }
            guard let png = pngData(from: url) else { return nil }
            return (png.base64EncodedString(), "image/png")
        }
    }

    private static func mediaType(forExtension ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
    }

    /// Above this, the raw file is re-encoded rather than sent. Chosen below the ~5 MB
    /// endpoint limit so base64's third still fits under it.
    private static let maxImageBytes = 3_500_000
    /// Long edge after downscaling. Vision models sample images down to roughly this
    /// anyway, so sending more costs tokens and latency for detail that is discarded.
    private static let maxImageEdge: CGFloat = 1568

    /// The image re-encoded small enough to send: long edge bounded, JPEG quality 0.8.
    private static func downscaledJPEG(from url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxImageEdge / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy, fraction: 1)
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func pngData(from url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url),
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Files / PDFs

    /// True when the attachment is a file/pdf whose text we can attempt to extract.
    static func canExtractText(from attachment: AIAttachment) -> Bool {
        attachment.kind == .file || attachment.kind == .pdf
    }

    /// Builds a prompt block containing the readable text of every file/pdf attachment.
    /// Empty string when there is nothing extractable, so callers can append freely.
    static func extractedText(for attachments: [AIAttachment]) -> String {
        let blocks: [String] = attachments.compactMap { attachment in
            guard canExtractText(from: attachment) else { return nil }
            guard let text = text(from: attachment.url), !text.isEmpty else { return nil }
            let name = attachment.url.lastPathComponent
            return "### Attached file: \(name)\n```\n\(text)\n```"
        }
        guard !blocks.isEmpty else { return "" }
        return "\n\nThe user attached the following files. Their extracted contents:\n\n"
            + blocks.joined(separator: "\n\n")
    }

    /// Attachments whose contents we could *not* turn into text — callers note these so
    /// the model knows something was attached but unreadable, instead of staying silent.
    static func unreadableFileAttachments(_ attachments: [AIAttachment]) -> [AIAttachment] {
        attachments.filter { attachment in
            canExtractText(from: attachment) && (text(from: attachment.url)?.isEmpty ?? true)
        }
    }

    /// Same extraction the attachment path uses, for callers holding a bare URL — the
    /// preview surface hands the assistant the file it is showing. Exposed rather than
    /// reimplemented so both routes get MarkItDown, the PDF reader and the encoding
    /// sniffing, and both truncate at the same budget.
    static func extractedText(from url: URL) -> String? {
        text(from: url)
    }

    private static func text(from url: URL) -> String? {
        // MarkItDown preserves headings, lists, tables, links, and Office-document structure.
        // It is the preferred shared ingestion path; native readers below remain available when
        // the managed CLI is absent or a particular conversion fails.
        if let converted = MarkItDownService.convert(
            url,
            characterBudget: maxCharactersPerFile
        ) {
            return converted.markdown
        }

        let ext = url.pathExtension.lowercased()
        let extracted: String?
        switch ext {
        case "pdf":
            extracted = pdfText(url)
        case "rtf", "rtfd", "doc", "docx", "odt", "wordml", "html", "htm", "webarchive":
            extracted = attributedText(url) ?? plainText(url)
        default:
            extracted = plainText(url)
        }
        guard let value = extracted?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        if value.count > maxCharactersPerFile {
            return String(value.prefix(maxCharactersPerFile))
                + "\n\n*(truncated — file is larger than shown)*"
        }
        return value
    }

    private static func pdfText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return doc.string
    }

    private static func attributedText(_ url: URL) -> String? {
        guard
            let attributed = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.plain],
                documentAttributes: nil)
        else {
            // Fall back to letting AppKit infer the document type (rtf/docx/html).
            guard
                let inferred = try? NSAttributedString(
                    url: url, options: [:], documentAttributes: nil)
            else { return nil }
            return inferred.string
        }
        return attributed.string
    }

    private static func plainText(_ url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        // Some text files are not UTF-8; let the system sniff the encoding.
        var encoding: String.Encoding = .utf8
        return try? String(contentsOf: url, usedEncoding: &encoding)
    }

    // MARK: - Model-aware vision

    /// Substrings that mark an Ollama / OpenAI-compatible model as vision-capable.
    private static let visionModelMarkers: [String] = [
        "vision", "llava", "bakllava", "moondream", "minicpm-v", "qwen2-vl", "qwen2.5-vl",
        "qwen-vl", "gemma3", "pixtral", "llama3.2-vision", "llama-3.2-vision", "internvl",
        "cogvlm", "phi-3-vision", "phi3-vision", "phi-4-multimodal", "granite-vision",
    ]

    /// Whether a specific model id is multimodal. Used to gate the image attach button
    /// at the *model* level — the provider-level flag is optimistic and wrongly green-lit
    /// text-only local/custom models, which then 400 on an image payload.
    static func modelSupportsVision(modelID: String) -> Bool {
        let id = modelID.lowercased()
        return visionModelMarkers.contains { id.contains($0) }
    }
}
