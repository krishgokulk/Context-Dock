import Testing
import Foundation
import AppKit
import CoreGraphics
@testable import Context_Dock

// Tests for Task #397: Foundation Models native image input.
//
// FoundationModels sessions require Apple Intelligence hardware and cannot be mocked,
// so these tests cover the OCR fallback helper, routing conditions, and API surface.

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Test image helper

/// Creates a temporary PNG with known text drawn on it, returns the file URL.
private func makeTestImage(text: String = "Hello World") -> URL? {
    let size = NSSize(width: 300, height: 100)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 10, y: 30), withAttributes: attrs)
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-image-\(UUID().uuidString).png")
    try? png.write(to: url)
    return url
}

// MARK: - OCR fallback helper tests

@available(macOS 26.0, *)
struct OnDeviceOCRFallbackTests {

    @Test("ocrExtractedText returns empty string for empty URL array")
    @MainActor
    func emptyURLsReturnsEmptyString() {
        let result = OnDeviceToolSession.shared.ocrExtractedText(from: [])
        #expect(result.isEmpty)
    }

    @Test("ocrExtractedText returns empty string for nonexistent file")
    @MainActor
    func nonexistentFileReturnsEmptyString() {
        let bogus = URL(fileURLWithPath: "/tmp/no-such-image-\(UUID()).png")
        let result = OnDeviceToolSession.shared.ocrExtractedText(from: [bogus])
        #expect(result.isEmpty)
    }

    @Test("ocrExtractedText extracts text from a rendered test image")
    @MainActor
    func extractsTextFromTestImage() throws {
        guard let url = makeTestImage(text: "Hello World") else {
            Issue.record("Could not create test image")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let result = OnDeviceToolSession.shared.ocrExtractedText(from: [url])
        #expect(result.contains("Image content:"))
        #expect(result.lowercased().contains("hello"))
    }
}

// MARK: - Native image attachment construction (macOS 27.0+)

@available(macOS 27.0, *)
struct NativeImageAttachmentTests {

    @Test("Attachment can be constructed from imageURL")
    func attachmentFromURL() throws {
        guard let url = makeTestImage(text: "Test") else {
            Issue.record("Could not create test image")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let attachment = Attachment(imageURL: url)
        // Verify it conforms to PromptRepresentable by building a Prompt
        let prompt = Prompt(attachment)
        _ = prompt // compilation proves PromptRepresentable conformance
    }

    @Test("Multiple attachments can be combined with text in a Prompt")
    func multipleAttachmentsWithText() throws {
        guard let url1 = makeTestImage(text: "One"),
              let url2 = makeTestImage(text: "Two") else {
            Issue.record("Could not create test images")
            return
        }
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }
        let attachments = [url1, url2].map { Attachment(imageURL: $0) }
        // Verify array of attachments + string builds a Prompt via PromptBuilder
        let prompt = Prompt {
            attachments
            "Describe these images"
        }
        _ = prompt
    }
}

// MARK: - API surface / backward compatibility

@available(macOS 26.0, *)
struct OnDeviceToolSessionAPITests {

    @Test("respond() accepts imageURLs parameter")
    @MainActor
    func respondAcceptsImageURLs() {
        // Compile-time contract: the method exists with the imageURLs parameter.
        _ = OnDeviceToolSession.shared.respond(to:imageURLs:systemPrompt:bundleId:axContext:)
    }

    @Test("stream() accepts imageURLs parameter")
    @MainActor
    func streamAcceptsImageURLs() {
        _ = OnDeviceToolSession.shared.stream(to:imageURLs:systemPrompt:bundleId:axContext:onPartial:onComplete:onError:)
    }
}

#endif // canImport(FoundationModels)
