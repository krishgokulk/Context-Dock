import Testing
import Foundation
import AppKit
import CoreGraphics
@testable import Context_Dock

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Test image helper

private func makeTestImage(
    text: String = "Hello World",
    size: NSSize = NSSize(width: 300, height: 100)
) -> URL? {
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

struct OnDeviceOCRFallbackTests {

    @Test("ocrExtractedText returns empty string for empty URL array")
    @MainActor
    func emptyURLsReturnsEmptyString() {
        guard #available(macOS 26.0, *) else { return }
        let result = OnDeviceToolSession.shared.ocrExtractedText(from: [])
        #expect(result.isEmpty)
    }

    @Test("ocrExtractedText returns empty string for nonexistent file")
    @MainActor
    func nonexistentFileReturnsEmptyString() {
        guard #available(macOS 26.0, *) else { return }
        let bogus = URL(fileURLWithPath: "/tmp/no-such-image-\(UUID()).png")
        let result = OnDeviceToolSession.shared.ocrExtractedText(from: [bogus])
        #expect(result.isEmpty)
    }

    @Test("ocrExtractedText extracts text from a rendered test image")
    @MainActor
    func extractsTextFromTestImage() throws {
        guard #available(macOS 26.0, *) else { return }
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

// MARK: - Runtime-safe native image prompt bridge tests

struct NativeImageAttachmentTests {

    @Test("OnDeviceImagePrompt returns empty array for empty, missing, or corrupt files without crashing")
    func invalidInputsReturnEmptyWithoutCrashing() throws {
        guard #available(macOS 26.0, *) else { return }
        #expect(OnDeviceImagePrompt.prompts(from: []).isEmpty)

        let missing = URL(fileURLWithPath: "/tmp/missing-image-\(UUID()).png")
        #expect(OnDeviceImagePrompt.prompts(from: [missing]).isEmpty)

        let webURL = try #require(URL(string: "https://example.com/image.png"))
        #expect(OnDeviceImagePrompt.prompts(from: [webURL]).isEmpty)

        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        #expect(OnDeviceImagePrompt.prompts(from: [corrupt]).isEmpty)
    }

    @Test("Single image URL builds native Prompt safely when supported at runtime")
    func singleImageBuildsPromptSafely() throws {
        guard #available(macOS 26.0, *) else { return }
        guard let url = makeTestImage(text: "Test") else {
            Issue.record("Could not create test image")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let prompts = OnDeviceImagePrompt.prompts(from: [url])
        if OnDeviceImagePrompt.isSupportedAtRuntime {
            #expect(prompts.count == 1)
            let combined = Prompt {
                prompts
                "Describe this image"
            }
            _ = combined
        } else {
            #expect(prompts.isEmpty)
        }
    }

    @Test("Multiple image attachments combine with text and cap at maxImagesPerTurn")
    func multipleAttachmentsWithTextAndCap() throws {
        guard #available(macOS 26.0, *) else { return }
        var urls: [URL] = []
        for idx in 1...6 {
            if let u = makeTestImage(text: "Img \(idx)") {
                urls.append(u)
            }
        }
        defer {
            for u in urls { try? FileManager.default.removeItem(at: u) }
        }
        #expect(urls.count == 6)

        let prompts = OnDeviceImagePrompt.prompts(from: urls)
        if OnDeviceImagePrompt.isSupportedAtRuntime {
            #expect(prompts.count == OnDeviceImagePrompt.maxImagesPerTurn)
            let combined = Prompt {
                prompts
                "Describe these images"
            }
            _ = combined
        } else {
            #expect(prompts.isEmpty)
        }
    }

    @Test("boundedOCRText truncates on line boundaries")
    func boundedOCRTextTruncatesCleanly() {
        guard #available(macOS 26.0, *) else { return }
        let short = "Line 1\nLine 2"
        #expect(OnDeviceImagePrompt.boundedOCRText(short, limit: 100) == short)

        let long = (1...100).map { "Row \($0): 123,456.78" }.joined(separator: "\n")
        let bounded = OnDeviceImagePrompt.boundedOCRText(long, limit: 120)
        #expect(bounded.contains("Row 1:"))
        #expect(bounded.hasSuffix("… (image text truncated)"))
    }
}

// MARK: - API surface / backward compatibility

struct OnDeviceToolSessionAPITests {

    @Test("respond() accepts imageURLs parameter")
    @MainActor
    func respondAcceptsImageURLs() {
        guard #available(macOS 26.0, *) else { return }
        _ = OnDeviceToolSession.shared.respond(to:imageURLs:systemPrompt:bundleId:axContext:)
    }

    @Test("stream() accepts imageURLs parameter")
    @MainActor
    func streamAcceptsImageURLs() {
        guard #available(macOS 26.0, *) else { return }
        _ = OnDeviceToolSession.shared.stream(to:imageURLs:systemPrompt:bundleId:axContext:onPartial:onComplete:onError:)
    }
}

#endif // canImport(FoundationModels)
