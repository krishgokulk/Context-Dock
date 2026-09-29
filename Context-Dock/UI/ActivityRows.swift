// ActivityRows.swift
// Context-Dock
//
// What a turn ran, drawn the way Claude Code and Codex draw it: one collapsed line
// ("Ran 1 command, read 1 source"), opening to one row per step with its status, and each
// row opening to the input it was given and the output it returned.
//
// One view for every chat surface — General Chat, the Dock and the Corner all draw answers
// through `AIChatMessageView`, which draws this. A second copy per surface is how the
// three drifted apart before.

import SwiftUI

/// The finished record under an answer.
struct ActivityRows: View {
    let steps: [ActivityStep]
    /// Narration to list when nothing was recorded as a step — a path that ran no tool
    /// through the registry still says what it did. Filler is already removed.
    var fallbackLines: [String] = []

    @State private var isExpanded = false

    private var header: String {
        steps.isEmpty
            ? AIChatMessageView.traceSummary(fallbackLines)
            : ActivitySummary.header(for: steps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.dockSoft) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 9, weight: .semibold))
                    Text(header)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(header)
            .accessibilityHint(isExpanded ? "Hide the steps" : "Show the steps")

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if steps.isEmpty {
                        ForEach(Array(fallbackLines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(Color.secondary.opacity(0.45))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 5)
                                Text(line)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        ForEach(steps) { step in
                            ActivityStepRow(step: step)
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// One step: status, title, one-line input, duration and a chevron; tapped, its input and
/// output.
struct ActivityStepRow: View {
    let step: ActivityStep
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.dockSoft) { isOpen.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusIcon
                        .frame(width: 12)
                    Text(step.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !step.detail.isEmpty, step.detail != titleSubject {
                        Text("· \(step.detail)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if let duration = step.duration {
                        Text(Self.durationText(duration))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(step.title), \(statusWord)")
            .accessibilityHint(isOpen ? "Hide input and output" : "Show input and output")

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    if !step.detail.isEmpty {
                        section("Input", step.detail)
                    }
                    if let readBack = step.readBack, !readBack.isEmpty {
                        section("Read back", readBack)
                    }
                    section(
                        "Output",
                        step.output.isEmpty
                            ? (step.status == .running ? "Running…" : "(no output)")
                            : step.output)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// A command row's title already is its input; saying it twice is noise.
    private var titleSubject: String {
        step.title.hasPrefix("Ran ") ? String(step.title.dropFirst(4)) : step.title
    }

    private func section(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.8))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        case .denied:
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        }
    }

    private var statusWord: String {
        switch step.status {
        case .running: return "running"
        case .ok: return "done"
        case .failed: return "failed"
        case .denied: return "not approved"
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }
}
