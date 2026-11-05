// LivePanelDetailMode.swift
// Context-Dock
//
// Per-answer density / detail mode in the live panel and chat answer views (#331).
// Pure display concern: changes how much of a turn's answer and evidence is shown, not what ran.
// Modes:
// - Summary: Headline + core verdict.
// - Normal: Current standard view.
// - Verbose: Expanded user-facing steps, receipts, and verified evidence (never leaks raw model/tool output, per #316).

import SwiftUI

enum LivePanelDetailMode: String, CaseIterable, Identifiable, Sendable {
    case summary = "Summary"
    case normal = "Normal"
    case verbose = "Verbose"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .summary: return "text.alignleft"
        case .normal: return "text.justify.left"
        case .verbose: return "list.bullet.rectangle.portrait"
        }
    }

    var helpDescription: String {
        switch self {
        case .summary:
            return "Headline and core verdict only"
        case .normal:
            return "Standard view with collapsed steps and evidence"
        case .verbose:
            return "Expanded user-facing steps, receipts, and verified evidence"
        }
    }

    // MARK: - Extraction Helpers (Pure, Layer-Safe)

    /// Extracts a concise headline from an answer's markdown content.
    /// Strips leaked tool calls (per #316), code blocks, and markdown chrome.
    static func headline(from content: String) -> String {
        let cleaned = stripLeakedOutput(content)
        let lines = cleaned.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty && !line.hasPrefix("```")
            }

        guard let first = lines.first else {
            return "Response completed"
        }

        // Clean common markdown prefix decorators (#, ##, **, -, *, >)
        var line = first
        while line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("-") || line.hasPrefix("*") {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        line = line.replacingOccurrences(of: "**", with: "")
        line = line.replacingOccurrences(of: "__", with: "")

        // Truncate at sentence boundary, skipping numbered list prefixes like "1." or "2."
        var searchStart = line.startIndex
        while let periodIndex = line[searchStart...].firstIndex(of: ".") {
            let prefix = line[..<periodIndex]
            let isNumberedList = prefix.allSatisfy(\.isNumber) || prefix.count < 8
            if !isNumberedList {
                let nextIndex = line.index(after: periodIndex)
                if nextIndex == line.endIndex || line[nextIndex] == " " {
                    line = String(line[...periodIndex])
                    break
                }
            }
            searchStart = line.index(after: periodIndex)
            if searchStart == line.endIndex { break }
        }

        if line.count > 120 {
            let truncated = line.prefix(117)
            if let lastSpace = truncated.lastIndex(of: " ") {
                line = String(truncated[..<lastSpace]) + "…"
            } else {
                line = String(truncated) + "…"
            }
        }

        return line.isEmpty ? "Response completed" : line
    }

    /// Evaluates the core verdict of a turn: status, evidence receipts, or subjective evaluation.
    static func verdict(
        evaluation: SubjectiveEvaluation?,
        receipts: [DoraXActionReceipt],
        isError: Bool,
        fallback: String = "Complete"
    ) -> (text: String, isSuccess: Bool, symbol: String) {
        if isError {
            return ("Failed", false, "xmark.circle.fill")
        }

        if let evaluation {
            switch evaluation.verdict {
            case .pass:
                return ("Review: Passed", true, "checkmark.shield.fill")
            case .needsRevision:
                return ("Review: Needs revision", false, "exclamationmark.shield.fill")
            }
        }

        if !receipts.isEmpty {
            let successCount = receipts.filter(\.success).count
            if successCount == receipts.count {
                let countText = receipts.count == 1 ? "1 receipt" : "\(receipts.count) receipts"
                return ("Verified (\(countText))", true, "checkmark.seal.fill")
            } else {
                let failedCount = receipts.count - successCount
                return ("\(failedCount) of \(receipts.count) failed", false, "xmark.circle.fill")
            }
        }

        return (fallback, true, "checkmark.circle.fill")
    }

    /// Strips leaked model-facing directives or tool json (per #316).
    static func stripLeakedOutput(_ text: String) -> String {
        DockCore.stripLeakedToolCalls(text)
    }
}

typealias AnswerDetailMode = LivePanelDetailMode

// MARK: - Picker View

struct LivePanelDetailModePicker: View {
    @Binding var mode: LivePanelDetailMode
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LivePanelDetailMode.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        mode = item
                    }
                } label: {
                    HStack(spacing: compact ? 3 : 4) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: compact ? 8.5 : 9.5, weight: mode == item ? .bold : .regular))
                        Text(item.rawValue)
                            .font(.system(size: compact ? 9.5 : 10.5, weight: mode == item ? .semibold : .medium))
                    }
                    .padding(.horizontal, compact ? 6 : 8)
                    .padding(.vertical, compact ? 2.5 : 3.5)
                    .foregroundStyle(mode == item ? Color.primary : Color.secondary)
                    .background(
                        mode == item
                            ? Color.primary.opacity(0.12)
                            : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .help("\(item.rawValue): \(item.helpDescription)")
                .accessibilityLabel("\(item.rawValue) detail mode")
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.045), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

// MARK: - Summary Answer Card (Headline + Verdict)

struct LivePanelSummaryCard: View {
    let headline: String
    let verdictText: String
    let isSuccess: Bool
    let verdictSymbol: String
    let evaluationNote: String?
    let receiptCount: Int
    @Binding var detailMode: LivePanelDetailMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: verdictSymbol)
                                .font(.system(size: 10, weight: .bold))
                            Text(verdictText)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(isSuccess ? Color.green : Color.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            (isSuccess ? Color.green : Color.orange).opacity(0.12),
                            in: Capsule()
                        )

                        if let evaluationNote, !evaluationNote.isEmpty {
                            Text(evaluationNote)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }

                Spacer(minLength: 8)

                LivePanelDetailModePicker(mode: $detailMode, compact: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
