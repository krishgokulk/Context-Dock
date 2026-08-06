// CLIScopePanel.swift
// Context-Dock
//
// A pinned CLI tool scope: the tool gets its own floating window with a transcript and an
// AI composer, so `tailscale` or `mole` becomes a small app of its own.
//
// Shares GlassFloatingPanel with Quick Note and the scoped list panels, so it behaves the
// same way — always on top, on every Space, non-activating, resizable.
//
// The model here is deliberately its own object rather than a view of the dock's chat state.
// A pinned panel outlives the dock: the dock's transcript lives in LauncherView's @State and
// disappears with it, which would empty the panel the moment the launcher closed.

import AppKit
import Combine
import SwiftUI

@MainActor
final class CLIScopePanelManager: ObservableObject {
    static let shared = CLIScopePanelManager()

    /// Commands with an open panel, lowercased.
    @Published private(set) var pinnedCommands: [String] = []

    private var panels: [String: NSPanel] = [:]
    private var models: [String: CLIScopePanelModel] = [:]

    private init() {}

    func isPinned(_ command: String) -> Bool {
        pinnedCommands.contains(command.lowercased())
    }

    func toggle(_ package: TerminalPackage) {
        if isPinned(package.command) {
            unpin(package.command)
        } else {
            pin(package)
        }
    }

    func pin(_ package: TerminalPackage) {
        let key = package.command.lowercased()
        if let existing = panels[key] {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        // The model is kept across close/reopen within a session, so re-pinning a tool does
        // not throw away the conversation the user was having with it.
        let model = models[key] ?? CLIScopePanelModel(command: package.command)
        models[key] = model

        let panel = GlassFloatingPanel.make(
            size: NSSize(width: 560, height: 480),
            minSize: NSSize(width: 380, height: 280)
        )
        panel.title = package.command
        panel.contentView = NSHostingView(rootView: CLIScopePanelContent(model: model))

        // Cascade, so pinning a second tool does not land exactly on the first.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let step = CGFloat(panels.count) * 28
            panel.setFrameTopLeftPoint(
                NSPoint(x: frame.maxX - 620 - step, y: frame.maxY - 90 - step))
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panels[key] = nil
                self?.pinnedCommands.removeAll { $0 == key }
            }
        }

        panels[key] = panel
        if !pinnedCommands.contains(key) { pinnedCommands.append(key) }
        panel.orderFrontRegardless()
    }

    func unpin(_ command: String) {
        let key = command.lowercased()
        panels[key]?.close()
        panels[key] = nil
        pinnedCommands.removeAll { $0 == key }
    }
}

// MARK: - Model

@MainActor
final class CLIScopePanelModel: ObservableObject {
    struct Entry: Identifiable {
        enum Kind { case user, assistant, output }
        let id = UUID()
        let kind: Kind
        let text: String
        var command: String?
        var exitCode: Int32?
    }

    let command: String
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var status: String?
    @Published var draft: String = ""
    /// A command the model proposed. Nothing runs until the user approves it here, exactly as
    /// in the dock — a floating window is not a reason to lower that bar.
    @Published private(set) var pendingCommand: String?

    init(command: String) {
        self.command = command
    }

    private var package: TerminalPackage? {
        TerminalPackageManager.shared.packages.first {
            $0.command.caseInsensitiveCompare(command) == .orderedSame
        }
    }

    /// What the tool is, in the model's terms. Built from the same material the dock's scope
    /// prompt uses: the parsed subcommand list, invocations known to work here, and the
    /// documentation the tool printed — budgeted, since a help tree can be tens of kilobytes.
    private func toolReference(for query: String) -> String {
        guard let package else { return "" }
        var lines = ["You are scoped to the command-line tool `\(command)`."]

        let subcommands = package.subcommands.filter {
            !LauncherView.helpNoiseTokens.contains($0.lowercased())
        }
        if !subcommands.isEmpty {
            lines.append("Subcommands: " + subcommands.joined(separator: ", "))
        }
        if !package.provenInvocations.isEmpty {
            lines.append(
                "Known-good invocations on this Mac: "
                + package.provenInvocations.prefix(5).joined(separator: " | "))
        }
        let help = package.helpText ?? ""
        let man = package.manText ?? ""
        let reference = man.count > help.count * 2 ? man : help
        if !reference.isEmpty {
            lines.append(AIContextBudget.fitHelpText(reference, query: query, budget: 1_200))
        }
        lines.append(
            "Answer about this tool only. If a command is needed, reply with exactly one line "
            + "`RUN: <command>` and nothing else — it is shown to the user for approval, never "
            + "run automatically. Use only documented subcommands and flags."
        )
        return lines.joined(separator: "\n")
    }

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, status == nil else { return }
        draft = ""
        entries.append(Entry(kind: .user, text: text))
        Task { await ask(text) }
    }

    private func ask(_ question: String) async {
        status = "Thinking…"
        defer { status = nil }
        do {
            let reply = try await AIProviderRouter.shared.send(
                AIRequest(
                    text: question,
                    context: .none,
                    source: .aiChat,
                    additionalContextPrompt: toolReference(for: question)
                ),
                provider: AppSettings.shared.selectedAIProvider
            )
            let proposed = LauncherView.parseLoopCommand(reply)
            let prose = LauncherView.strippingLoopDirective(reply)
            if !prose.isEmpty { entries.append(Entry(kind: .assistant, text: prose)) }
            pendingCommand = proposed
        } catch {
            entries.append(
                Entry(kind: .assistant, text: "Couldn't reach the model: \(error.localizedDescription)"))
        }
    }

    func denyPending() { pendingCommand = nil }

    func runPending() {
        guard let toRun = pendingCommand else { return }
        pendingCommand = nil
        Task { await run(toRun) }
    }

    private func run(_ toRun: String) async {
        status = "Running \(toRun)…"
        let result = await TerminalCommandExecutor.shared.runPreApproved(toRun) { [weak self] line in
            let clean = TerminalPackageManager.strippingANSI(line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            Task { @MainActor in self?.status = String(clean.prefix(80)) }
        }
        status = nil

        let output = TerminalPackageManager.strippingANSI(result.output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        entries.append(
            Entry(
                kind: .output,
                text: output.isEmpty ? "(no output)" : output,
                command: toRun,
                exitCode: result.exitCode))
        if result.success {
            TerminalPackageManager.shared.recordSuccessfulInvocation(toRun)
        }
    }
}

// MARK: - View

struct CLIScopePanelContent: View {
    @ObservedObject var model: CLIScopePanelModel
    @State private var expandedOutputIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            transcript
            if let pending = model.pendingCommand {
                approval(pending)
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
            Text(model.command)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Spacer()
            if let status = model.status {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.entries) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: model.entries.count) { _, _ in
                guard let last = model.entries.last else { return }
                withAnimation(.dockStandard) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ entry: CLIScopePanelModel.Entry) -> some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
            }
        case .assistant:
            Text(entry.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .output:
            outputRow(entry)
        }
    }

    /// Output is collapsed by default: a command's full transcript is detail, not the answer.
    private func outputRow(_ entry: CLIScopePanelModel.Entry) -> some View {
        let isExpanded = expandedOutputIDs.contains(entry.id)
        let failed = (entry.exitCode ?? 0) != 0
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.dockCrisp) {
                    if isExpanded {
                        expandedOutputIDs.remove(entry.id)
                    } else {
                        expandedOutputIDs.insert(entry.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(entry.command ?? "output")
                        .font(.system(size: 11, design: .monospaced))
                    if failed, let code = entry.exitCode {
                        Text("exit \(code)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(entry.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func approval(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run this command?")
                .font(.system(size: 11, weight: .semibold))
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                Button("Deny") { model.denyPending() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Approve & Run") { model.runPending() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask \(model.command)…", text: $model.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { model.submit() }
            Button {
                model.submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }
}
