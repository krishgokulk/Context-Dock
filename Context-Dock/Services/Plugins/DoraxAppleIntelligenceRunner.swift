// Context-Dock/Services/Plugins/DoraxAppleIntelligenceRunner.swift
// Context-Dock
//
// Native on-device Apple Intelligence Writing Tools & Ask runner for `dorax.appleIntelligence.*`
// Pack v3 commands (inspired by raycast-apple-intelligence, using FoundationModels directly on-device).

import AppKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
enum DoraxAppleIntelligenceRunner {

    static let tintHex = "#EC4899"

    struct OperationSpec {
        let key: String
        let label: String
        let systemInstruction: String
        let requiresInputText: Bool
    }

    static func spec(for rawSource: String, customAction: String? = nil, customInstructions: String? = nil) -> OperationSpec {
        let suffix = rawSource.hasPrefix("dorax.appleIntelligence.")
            ? String(rawSource.dropFirst("dorax.appleIntelligence.".count))
            : rawSource

        let resolvedKey: String = {
            if suffix.lowercased() == "custom" || suffix.lowercased() == "writingtools" {
                switch (customAction ?? "Proofread").lowercased() {
                case "proofread": return "proofread"
                case "rewrite": return "rewrite"
                case "make friendly", "friendly": return "friendly"
                case "make professional", "professional": return "professional"
                case "make concise", "concise": return "concise"
                case "summarize": return "summarize"
                case "key points", "create key points", "keypoints": return "keyPoints"
                case "make list", "makelist": return "makeList"
                case "make table", "maketable": return "makeTable"
                default: return "customPrompt"
                }
            }
            return suffix
        }()

        switch resolvedKey {
        case "proofread":
            return OperationSpec(
                key: "proofread", label: "Proofread",
                systemInstruction: "Proofread the user's text. Fix spelling, grammar, and punctuation errors while keeping the original voice and meaning. Return only the corrected text without preamble.",
                requiresInputText: true)
        case "rewrite":
            return OperationSpec(
                key: "rewrite", label: "Rewrite",
                systemInstruction: "Rewrite the user's text to improve clarity, flow, and phrasing while preserving its meaning. Return only the rewritten text.",
                requiresInputText: true)
        case "friendly":
            return OperationSpec(
                key: "friendly", label: "Make Friendly",
                systemInstruction: "Rewrite the user's text in a warm, friendly, approachable tone while keeping all key information. Return only the rewritten text.",
                requiresInputText: true)
        case "professional":
            return OperationSpec(
                key: "professional", label: "Make Professional",
                systemInstruction: "Rewrite the user's text in a clear, polished, professional tone suitable for work communication. Return only the rewritten text.",
                requiresInputText: true)
        case "concise":
            return OperationSpec(
                key: "concise", label: "Make Concise",
                systemInstruction: "Shorten the user's text to be crisp and concise without losing essential facts. Return only the concise text.",
                requiresInputText: true)
        case "summarize":
            return OperationSpec(
                key: "summarize", label: "Summarize",
                systemInstruction: "Summarize the provided text concisely, capturing the main thesis and essential details.",
                requiresInputText: true)
        case "keyPoints":
            return OperationSpec(
                key: "keyPoints", label: "Create Key Points",
                systemInstruction: "Extract the most important takeaways from the text as concise Markdown bullet points.",
                requiresInputText: true)
        case "makeList":
            return OperationSpec(
                key: "makeList", label: "Make List",
                systemInstruction: "Convert the provided text into a clean, well-structured Markdown list.",
                requiresInputText: true)
        case "makeTable":
            return OperationSpec(
                key: "makeTable", label: "Make Table",
                systemInstruction: "Convert the provided text into a well-structured Markdown table with clear headers.",
                requiresInputText: true)
        case "ask":
            return OperationSpec(
                key: "ask", label: "Ask Apple Intelligence",
                systemInstruction: "You are Apple Intelligence running privately on-device inside DoraX. Answer clearly and concisely using clean Markdown.",
                requiresInputText: false)
        default:
            let extra = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let instr = extra.isEmpty
                ? "Transform the user's text cleanly and directly according to their request."
                : "Follow this instruction carefully: \(extra). Return only the clean Markdown result."
            return OperationSpec(
                key: "custom", label: extra.isEmpty ? "Custom Writing Tool" : String(extra.prefix(28)),
                systemInstruction: instr,
                requiresInputText: true)
        }
    }

    static func resolveInputText(
        spec: OperationSpec,
        query: String,
        formValues: [String: String]?
    ) -> (text: String, sourceLabel: String) {
        if let promptField = formValues?["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !promptField.isEmpty, spec.key == "ask"
        {
            let ctxText = (formValues?["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if ctxText.isEmpty {
                return (promptField, "Prompt")
            }
            return ("\(promptField)\n\nContext:\n\(ctxText)", "Prompt + Text")
        }

        if let formText = formValues?["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !formText.isEmpty {
            return (formText, "Form Input")
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return (q, "Command Input")
        }
        let selectionText = CornerDockController.shared.selection.snapshot.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectionText.isEmpty {
            return (String(selectionText.prefix(10_000)), "Selection")
        }
        if let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty
        {
            return (String(clip.prefix(10_000)), "Clipboard")
        }
        return ("", "Empty")
    }

    static func run(
        source: String,
        query: String = "",
        formValues: [String: String]? = nil,
        commandTitle: String = "Apple Intelligence"
    ) async -> DoraxCommandOutput {
        let operation = spec(
            for: source,
            customAction: formValues?["action"],
            customInstructions: formValues?["instructions"])
        let resolved = resolveInputText(spec: operation, query: query, formValues: formValues)

        if resolved.text.isEmpty {
            let usage = """
            ### \(operation.label) (Apple Intelligence)

            No text or prompt was provided yet.

            **Ways to pass text:**
            1. Select text in any app before opening the Dock
            2. Copy text to your clipboard (`⌘C`)
            3. Type into the launcher search bar or open **Apple Intelligence Writing Tools** form

            *Runs 100% on-device via Apple Foundation Models — zero API keys needed.*
            """
            return DoraxCommandOutput(
                detail: DoraxItemDetail(
                    markdown: usage,
                    metadata: [
                        DoraxMetadataEntry(label: "Engine", value: "On-Device", colorHex: tintHex),
                        DoraxMetadataEntry(label: "Action", value: operation.label),
                    ]),
                appearance: DoraxPackAppearance(tint: tintHex, glow: .soft),
                emptyMessage: "Select text, copy to clipboard, or type text to run \(operation.label)."
            )
        }

        let started = Date()

        // Fast deterministic response during XCTest runs so offline suites stay fast.
        if AppDelegate.isHostingTests {
            let preview = "[\(operation.label) — On-Device Preview]\n\n\(resolved.text)"
            return buildSuccessOutput(
                operation: operation,
                inputText: resolved.text,
                sourceLabel: resolved.sourceLabel,
                resultText: preview,
                durationMs: 1)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                return DoraxCommandOutput(
                    detail: DoraxItemDetail(
                        markdown: """
                        ### Apple Intelligence Not Available

                        macOS reported `SystemLanguageModel.default` is currently unavailable on this Mac.
                        Enable **Apple Intelligence & Siri** in System Settings and ensure the on-device model has finished downloading.
                        """,
                        metadata: [
                            DoraxMetadataEntry(label: "Engine", value: "Unavailable", colorHex: "#F59E0B"),
                            DoraxMetadataEntry(label: "Action", value: operation.label),
                        ]),
                    appearance: DoraxPackAppearance(tint: "#F59E0B", glow: .soft)
                )
            }

            do {
                let session = LanguageModelSession(instructions: operation.systemInstruction)
                var resultText = ""
                let stream = session.streamResponse(to: resolved.text, generating: String.self)
                for try await snapshot in stream {
                    resultText = snapshot.content
                }
                let cleaned = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalResult = cleaned.isEmpty ? "(No output produced)" : cleaned
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                return buildSuccessOutput(
                    operation: operation,
                    inputText: resolved.text,
                    sourceLabel: resolved.sourceLabel,
                    resultText: finalResult,
                    durationMs: ms)
            } catch {
                return DoraxCommandOutput(
                    detail: DoraxItemDetail(
                        markdown: "### Apple Intelligence Error\n\n`\(error.localizedDescription)`",
                        metadata: [
                            DoraxMetadataEntry(label: "Action", value: operation.label),
                            DoraxMetadataEntry(label: "Source", value: resolved.sourceLabel),
                        ]),
                    appearance: DoraxPackAppearance(tint: "#EF4444", glow: .soft)
                )
            }
        }
        #endif

        return DoraxCommandOutput(
            detail: DoraxItemDetail(
                markdown: "### On-Device Apple Intelligence\nRequires macOS 26.0+ with Apple Silicon and Apple Intelligence enabled.",
                metadata: [DoraxMetadataEntry(label: "Command", value: commandTitle)]),
            appearance: DoraxPackAppearance(tint: tintHex, glow: .soft)
        )
    }

    private static func buildSuccessOutput(
        operation: OperationSpec,
        inputText: String,
        sourceLabel: String,
        resultText: String,
        durationMs: Int
    ) -> DoraxCommandOutput {
        let singleItem = DoraxCommandItem(
            id: "ai-\(operation.key)",
            title: "\(operation.label) Result",
            subtitle: String(resultText.replacingOccurrences(of: "\n", with: " ").prefix(80)),
            icon: "apple.intelligence",
            category: operation.label,
            accessories: [
                DoraxAccessory(kind: "tag", text: "On-Device", colorHex: tintHex),
                DoraxAccessory(kind: "metric", text: "\(durationMs)ms"),
            ],
            detail: DoraxItemDetail(
                markdown: resultText,
                metadata: [
                    DoraxMetadataEntry(label: "Engine", value: "Apple Intelligence", colorHex: tintHex),
                    DoraxMetadataEntry(label: "Action", value: operation.label),
                    DoraxMetadataEntry(label: "Input Source", value: sourceLabel),
                    DoraxMetadataEntry(label: "Latency", value: "\(durationMs) ms"),
                ]),
            actions: [
                DoraxItemAction(id: "copy-result", title: "Copy Result", icon: "doc.on.doc", shortcut: "↵", kind: "copy", value: resultText),
                DoraxItemAction(id: "paste-result", title: "Stage for Paste", icon: "doc.on.clipboard", shortcut: "⌘↵", kind: "paste", value: resultText),
                DoraxItemAction(id: "copy-original", title: "Copy Original", icon: "text.quote", kind: "copy", value: inputText),
            ]
        )

        return DoraxCommandOutput(
            items: [singleItem],
            detail: singleItem.detail,
            appearance: DoraxPackAppearance(tint: tintHex, glow: .pulse)
        )
    }
}
