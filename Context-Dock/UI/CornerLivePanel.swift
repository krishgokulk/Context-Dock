// CornerLivePanel.swift
// Context-Dock
//
// The Context Dock's panel (#191, part 2): beside an app's conversation, the way Claude keeps
// its Progress and Context panel beside a chat (owner 2026-10-05). What DoraX is doing in
// the app — the steps as they run, a command's output — and what the turn left behind: the
// files it made or named, the uploads it was given, the connectors and the adapter it can
// reach, and what it can do there.
//
// Nothing here is a second record. The steps are the conversation's own (`liveActivity`
// while a turn runs, the finished message's activity after), the files are
// `TurnFileExtractor`'s — the same list the answer's Files card draws — the connectors are
// `MCPServerManager`'s, the adapter is `AppAdapterManager`'s, and "Can do here" is
// `ScopeInventory.app`, the list the app's scope card shows. The card and its parts are
// the result board's (`CornerBoardPreviewPanel`).

import AppKit
import SwiftUI

struct CornerLivePanel: View {
    let appName: String
    let appBundleID: String
    let appIcon: NSImage?
    let messages: [AIChatMessage]
    let isAnswering: Bool
    /// The narration, for the moments before the first step is recorded.
    let liveSteps: [String]

    @ObservedObject private var conversation = AppChatConversation.shared
    @ObservedObject private var servers = MCPServerManager.shared
    /// What the app can do, read once per app: it does not change while a turn runs.
    @State private var canDo: [CanDoLine] = []
    /// The files the last finished answer made or named, found off the main thread.
    @State private var files: [URL] = []
    /// Sections the user folded, by title — Claude's chevrons.
    @State private var folded: Set<String> = []

    private struct CanDoLine: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        let count: Int
    }

    private typealias L = CornerLivePanelLayout

    private var lastAnswer: AIChatMessage? {
        messages.last { $0.role == .assistant && !$0.isError }
    }

    /// The last turn's answer, failed or not. A step that failed is still a step that ran:
    /// skipping error answers showed an older turn's steps, or none at all.
    private var lastTurnAnswer: AIChatMessage? {
        messages.last { $0.role == .assistant }
    }

    private var finishedSteps: [ActivityStep] {
        guard let answer = lastTurnAnswer else { return [] }
        let recorded = conversation.activityByMessageID[answer.id] ?? answer.activity
        return ActivityStep.steps(recorded: recorded, receipts: answer.evidenceReceipts)
    }

    var body: some View {
        let steps = L.steps(
            isAnswering: isAnswering, live: conversation.liveActivity, finished: finishedSteps)
        let uploads = L.uploads(messages.filter { $0.role == .user }.map(\.attachments))
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(
                    icon: appIcon, title: appName.isEmpty ? "This app" : appName,
                    subtitle: subtitle(steps), status: isAnswering ? .orange : .green)
                section("Progress", count: steps.count) { progress(steps) }
                if let shell = L.terminalStep(in: steps) {
                    section(shell.status == .running ? "Terminal — running" : "Terminal") {
                        terminal(shell)
                    }
                }
                if !files.isEmpty {
                    section("Files", count: files.count) {
                        ForEach(files, id: \.self) { fileRow($0) }
                    }
                }
                if !uploads.isEmpty {
                    section("Uploads", count: uploads.count) {
                        ForEach(uploads, id: \.self) { fileRow($0) }
                    }
                }
                section("Connectors") { connectors(steps) }
                if !canDo.isEmpty {
                    section("Can do here", count: canDo.count) {
                        ForEach(canDo) { line in
                            PanelRow(symbol: line.symbol, value: line.title, trailing: "\(line.count)")
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .boardPanelCard()
        .animation(.smooth(duration: 0.18), value: steps.map(\.status))
        .animation(.smooth(duration: 0.18), value: files)
        .task(id: appBundleID) { loadCanDo() }
        .task(id: filesKey) { await loadFiles() }
    }

    private func subtitle(_ steps: [ActivityStep]) -> String {
        if isAnswering {
            let done = steps.count { $0.status != .running }
            return steps.isEmpty ? "Working…" : "Working… \(done) of \(steps.count) done"
        }
        if steps.isEmpty { return "Ready" }
        let failed = steps.count { $0.status == .failed || $0.status == .denied }
        let noun = steps.count == 1 ? "step" : "steps"
        return failed == 0 ? "Done · \(steps.count) \(noun)" : "Done · \(failed) of \(steps.count) failed"
    }

    // MARK: Sections

    /// A titled section that folds, as Claude's panel does, with a hairline above it.
    @ViewBuilder
    private func section<Content: View>(
        _ title: String, count: Int? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        let isFolded = folded.contains(title)
        PanelDivider()
        Button {
            withAnimation(.smooth(duration: 0.18)) {
                if isFolded { folded.remove(title) } else { folded.insert(title) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isFolded ? -90 : 0))
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, isFolded ? 0 : 6)
        .accessibilityLabel(isFolded ? "Show \(title)" : "Hide \(title)")
        if !isFolded {
            content()
        }
    }

    // MARK: Progress

    @ViewBuilder
    private func progress(_ steps: [ActivityStep]) -> some View {
        if steps.isEmpty {
            if isAnswering {
                // Before the first tool runs, the turn's narration is all there is to show.
                let lines = Array(liveSteps.suffix(5))
                if lines.isEmpty {
                    stepRow(symbol: nil, title: "Thinking…", detail: "", trailing: nil, done: false)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        let last = index == lines.count - 1
                        stepRow(
                            symbol: last ? nil : "checkmark.circle.fill", title: line, detail: "",
                            trailing: nil, tint: .accentColor, done: !last)
                    }
                }
            } else {
                // Only what was recorded can be vouched for. "Answered without running
                // anything" was said of turns a pre-model shortcut had run (issue #195).
                Text("No steps recorded for this answer.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(steps) { step in
                stepRow(
                    symbol: symbol(for: step.status), title: step.title, detail: step.detail,
                    trailing: step.duration.map(Self.duration), tint: tint(for: step.status),
                    done: step.status == .ok)
            }
        }
    }

    /// One step: a spinner while it runs (`symbol` nil), its outcome after. A finished step
    /// dims, the way Claude crosses off what is done.
    private func stepRow(
        symbol: String?, title: String, detail: String, trailing: String?,
        tint: Color = .secondary, done: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(done ? .secondary : .primary)
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
        case .ok: .accentColor
        case .failed: .red
        case .denied: .orange
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "<1s" : seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m \(Int(seconds) % 60)s"
    }

    // MARK: Terminal

    private func terminal(_ step: ActivityStep) -> some View {
        let command = step.detail.isEmpty ? step.title : step.detail
        let output = L.outputTail(step.output)
        return PanelCode(
            text: "$ " + command
                + (output.isEmpty ? (step.status == .running ? "\n…" : "") : "\n" + output))
    }

    // MARK: Files and uploads

    /// What the last finished answer made or named — the answer's own Files card's list.
    /// Waits for the turn to end: paths mid-stream are half-written.
    private var filesKey: String {
        guard !isAnswering, let answer = lastAnswer else { return "none" }
        return answer.id.uuidString + "\(answer.content.count)"
    }

    private func loadFiles() async {
        guard !isAnswering, let answer = lastAnswer else {
            files = []
            return
        }
        let text = answer.content
        let outputs = finishedSteps.map(\.output) + [answer.runOutput].compactMap { $0 }
        let excluded = Set(answer.attachments.map { $0.standardizedFileURL.path })
        let found = await Task.detached(priority: .utility) {
            TurnFileExtractor.files(answer: text, stepOutputs: outputs)
                .filter { !excluded.contains($0.standardizedFileURL.path) }
        }.value
        guard !Task.isCancelled else { return }
        files = found
    }

    /// A file: its icon, its name and kind; click opens it, the folder button shows it in
    /// Finder.
    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.kind(of: url))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url.path)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            .accessibilityLabel("Show \(url.lastPathComponent) in Finder")
        }
        .frame(height: 26)
    }

    private static func kind(of url: URL) -> String {
        if url.hasDirectoryPath { return "Folder" }
        let ext = url.pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    // MARK: Connectors

    @ViewBuilder
    private func connectors(_ steps: [ActivityStep]) -> some View {
        let linked = servers.servers(forBundleId: appBundleID).map(\.name)
        let names = L.connectors(linked: linked, steps: steps)
        let adapter = AppAdapterManager.shared.adapter(for: appBundleID)
        if let adapter {
            PanelRow(
                symbol: "app.connected.to.app.below.fill",
                value: "\(adapter.appName) adapter",
                trailing: adapter.isBuiltIn ? "built-in" : "\(adapter.actions.count) actions")
        }
        ForEach(names, id: \.self) { name in
            let inUse = steps.contains {
                $0.kind == .mcp && L.server(of: $0) == name && $0.status == .running
            }
            PanelRow(
                symbol: "server.rack", value: name,
                trailing: inUse ? "in use" : (linked.contains(name) ? "MCP" : "called"))
        }
        if adapter == nil && names.isEmpty {
            Text("Nothing linked to \(appName.isEmpty ? "this app" : appName) yet")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Can do

    private func loadCanDo() {
        canDo = ScopeInventory.app(bundleId: appBundleID, appName: appName).canDoGroups
            .prefix(6)
            .map { CanDoLine(title: $0.title, symbol: $0.symbol, count: $0.items.count) }
    }
}
