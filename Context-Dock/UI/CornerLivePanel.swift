// CornerLivePanel.swift
// Context-Dock
//
// The Context Dock's live panel (#191, part 2): the right half of an app's chat card while
// a turn runs, the way Claude shows its progress beside the conversation. What DoraX is
// doing in the app — the steps as they run, a command's output, the connectors in play,
// and what it can do there.
//
// Nothing here is a second record. The steps are the conversation's own `liveActivity`
// (the rows the transcript draws), the connectors are `MCPServerManager`'s, and "Can do" is
// `ScopeInventory.app`, the list the app's scope card shows. The card and its parts are the
// result board's (`CornerBoardPreviewPanel`).

import AppKit
import SwiftUI

struct CornerLivePanel: View {
    let appName: String
    let appBundleID: String
    let appIcon: NSImage?
    /// The narration, for the moments before the first step is recorded.
    let liveSteps: [String]

    @ObservedObject private var conversation = AppChatConversation.shared
    @ObservedObject private var servers = MCPServerManager.shared
    /// What the app can do, read once per app: it does not change while a turn runs.
    @State private var canDo: [CanDoLine] = []

    private struct CanDoLine: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        let count: Int
    }

    private typealias L = CornerLivePanelLayout

    var body: some View {
        let steps = conversation.liveActivity
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(
                    icon: appIcon, title: appName.isEmpty ? "Working" : appName,
                    subtitle: subtitle(steps), status: .orange)
                progress(steps)
                if let shell = L.terminalStep(in: steps) {
                    PanelDivider()
                    terminal(shell)
                }
                PanelDivider()
                connectors(steps)
                if !canDo.isEmpty {
                    PanelDivider()
                    PanelSection(title: "Can do here")
                    ForEach(canDo) { line in
                        PanelRow(symbol: line.symbol, value: line.title, trailing: "\(line.count)")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .boardPanelCard()
        .animation(.smooth(duration: 0.18), value: steps.map(\.status))
        .task(id: appBundleID) { loadCanDo() }
    }

    private func subtitle(_ steps: [ActivityStep]) -> String {
        let done = steps.count { $0.status != .running }
        guard !steps.isEmpty else { return "Working…" }
        return "Working… \(done) of \(steps.count) steps done"
    }

    // MARK: Progress

    @ViewBuilder
    private func progress(_ steps: [ActivityStep]) -> some View {
        PanelSection(title: "Progress")
        if steps.isEmpty {
            // Before the first tool runs, the turn's narration is all there is to show.
            let lines = liveSteps.suffix(5)
            if lines.isEmpty {
                stepRow(symbol: nil, title: "Thinking…", detail: "", trailing: nil)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    stepRow(
                        symbol: index == lines.count - 1 ? nil : "checkmark.circle.fill",
                        title: line, detail: "", trailing: nil)
                }
            }
        } else {
            ForEach(steps) { step in
                stepRow(
                    symbol: symbol(for: step.status), title: step.title, detail: step.detail,
                    trailing: step.duration.map(Self.duration), tint: tint(for: step.status))
            }
        }
    }

    /// One step: a spinner while it runs (`symbol` nil), its outcome after.
    private func stepRow(
        symbol: String?, title: String, detail: String, trailing: String?,
        tint: Color = .secondary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
    }

    private func symbol(for status: ActivityStep.Status) -> String? {
        switch status {
        case .running: nil
        case .ok: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .denied: "hand.raised.fill"
        }
    }

    private func tint(for status: ActivityStep.Status) -> Color {
        switch status {
        case .running: .secondary
        case .ok: .green
        case .failed: .red
        case .denied: .orange
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "<1s" : seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m \(Int(seconds) % 60)s"
    }

    // MARK: Terminal

    @ViewBuilder
    private func terminal(_ step: ActivityStep) -> some View {
        PanelSection(title: step.status == .running ? "Terminal — running" : "Terminal")
        let command = step.detail.isEmpty ? step.title : step.detail
        let output = L.outputTail(step.output)
        PanelCode(
            text: "$ " + command
                + (output.isEmpty ? (step.status == .running ? "\n…" : "") : "\n" + output))
    }

    // MARK: Connectors

    @ViewBuilder
    private func connectors(_ steps: [ActivityStep]) -> some View {
        let linked = servers.servers(forBundleId: appBundleID).map(\.name)
        let names = L.connectors(linked: linked, steps: steps)
        PanelSection(title: "Connectors")
        if names.isEmpty {
            Text("None linked to \(appName.isEmpty ? "this app" : appName)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
        } else {
            ForEach(names, id: \.self) { name in
                let inUse = steps.contains {
                    $0.kind == .mcp && L.server(of: $0) == name && $0.status == .running
                }
                PanelRow(
                    symbol: "server.rack", value: name,
                    trailing: inUse ? "in use" : (linked.contains(name) ? "MCP" : "called"))
            }
        }
    }

    // MARK: Can do

    private func loadCanDo() {
        canDo = ScopeInventory.app(bundleId: appBundleID, appName: appName).canDoGroups
            .prefix(6)
            .map { CanDoLine(title: $0.title, symbol: $0.symbol, count: $0.items.count) }
    }
}
