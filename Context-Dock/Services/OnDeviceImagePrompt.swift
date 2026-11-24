// OnDeviceImagePrompt.swift
// Context-Dock
//
// Runtime-safe multimodal image prompt bridge for Apple's FoundationModels framework.
//
// Why this wrapper exists instead of calling `FoundationModels.Attachment(imageURL:)` directly:
//   1. GitHub Actions CI builds on macOS 26 (`compiler(<6.4)`), where `Attachment` does not exist
//      in the FoundationModels SDK (`cannot find 'Attachment' in scope`).
//   2. Between the Xcode 27.0 beta SDK (`27A5194q`) and shipping macOS 27.x (`26B131`), Apple
//      removed the `AttachmentContent` generic constraint on `Attachment<Content>`, changing the
//      mangled `Attachment.init(imageURL:)` symbol from `...RszrlE8imageURL...` to
//      `...RszlE8imageURL...`. Because Context-Dock's deployment target is macOS 26.0, the beta
//      symbol is weak-linked and resolves to `0x0` at runtime on shipping macOS 27.x — crashing
//      with `EXC_BAD_ACCESS (SIGSEGV)` at `pc = 0x0`.
//
// `CIImage`'s `PromptRepresentable` witness (`$sSo7CIImageC16FoundationModelsE20promptRepresentationAC6PromptVvg`)
// has an identical mangled ABI in both the Xcode 27 SDK `.tbd` and shipping macOS 27.x runtime,
// AND we verify its presence via `dlsym` before calling so a missing weak symbol can never jump
// to `0x0`.

import CoreImage
import Darwin
import Foundation

#if canImport(FoundationModels)
import FoundationModels

#if compiler(>=6.4)
@available(macOS 27.0, *)
private extension CIImage {
    @_silgen_name("$sSo7CIImageC16FoundationModelsE20promptRepresentationAC6PromptVvg")
    func _foundationModelsPromptRepresentation() -> Prompt
}
#endif

@available(macOS 26.0, *)
enum OnDeviceImagePrompt {
    /// Maximum number of native image prompts attached to a single on-device turn so multimodal
    /// tokens never crowd out the 4,096-token context window (~130–200 tokens per image).
    static let maxImagesPerTurn = 4

    /// Conservative token budget reserved per native image attachment (~131 measured on screenshots).
    static let estimatedTokensPerImage = 200

    /// Maximum character budget for supplemental Vision OCR text sent alongside or instead of
    /// native images, keeping total prompt size well inside `OnDevicePromptBudget.maxPromptTokens`.
    static let maxOCRCharacters = 2_000

    private static let ciImagePromptSymbol =
        "$sSo7CIImageC16FoundationModelsE20promptRepresentationAC6PromptVvg"

    /// True only when both the SDK was compiled with macOS 27+ multimodal support AND the running
    /// OS `FoundationModels.framework` actually exports the `CIImage` prompt bridge symbol.
    static let isSupportedAtRuntime: Bool = {
        #if compiler(>=6.4)
        guard #available(macOS 27.0, *) else { return false }
        let path = "/System/Library/Frameworks/FoundationModels.framework/FoundationModels"
        let altPath = "/System/Library/Frameworks/FoundationModels.framework/Versions/A/FoundationModels"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD)
            ?? dlopen(path, RTLD_LAZY)
            ?? dlopen(altPath, RTLD_LAZY)
        else {
            return false
        }
        return dlsym(handle, ciImagePromptSymbol) != nil
        #else
        return false
        #endif
    }()

    /// Converts readable local image URLs into native `FoundationModels.Prompt` values when
    /// supported by both build SDK and runtime OS. Unreadable, non-file, or corrupt images are
    /// skipped safely without throwing or crashing. Returns `[]` on macOS 26.x runtimes or
    /// builds compiled against the macOS 26 SDK, signaling callers to rely on Vision OCR text.
    static func prompts(from imageURLs: [URL]) -> [Prompt] {
        guard !imageURLs.isEmpty, isSupportedAtRuntime else { return [] }
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            var results: [Prompt] = []
            for url in imageURLs {
                guard results.count < maxImagesPerTurn else { break }
                guard url.isFileURL,
                      FileManager.default.isReadableFile(atPath: url.path),
                      let ciImage = CIImage(
                          contentsOf: url,
                          options: [.applyOrientationProperty: true]
                      ),
                      ciImage.extent.width > 0,
                      ciImage.extent.height > 0
                else {
                    continue
                }
                results.append(ciImage._foundationModelsPromptRepresentation())
            }
            return results
        }
        #endif
        return []
    }

    /// Truncates supplemental OCR text on a line boundary so dense table screenshots do not
    /// exhaust the 4,096-token on-device context window.
    static func boundedOCRText(_ text: String, limit: Int = maxOCRCharacters) -> String {
        guard text.count > limit else { return text }
        let prefixSlice = text.prefix(limit)
        if let lastNewline = prefixSlice.lastIndex(of: "\n"), lastNewline > text.startIndex {
            return String(prefixSlice[..<lastNewline]) + "\n… (image text truncated)"
        }
        return String(prefixSlice) + "… (image text truncated)"
    }
}
#endif
