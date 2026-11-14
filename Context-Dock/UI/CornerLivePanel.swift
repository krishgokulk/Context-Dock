// CornerLivePanel.swift
// Context-Dock
//
// The Context Dock's panel (#191, part 2, #443): beside a conversation, the way Claude keeps
// its Progress and Context panel beside a chat (owner 2026-10-05).
//
// For App Pets: describes the frontmost app's conversation, capabilities, pack and connectors.
// For General Chat and Combined Chat: describes the conversation itself — Dora/provider icon,
// model subtitle, progress with borrowed app badges, context (attachments, selection, memory),
// apps in this chat, connectors grouped by source, skills, and outputs.

import AppKit
import SwiftUI

struct CornerLivePanel: View {
    let subject: PanelSubject
    let messages: [AIChatMessage]
    let isAnswering: Bool
    /// The narration, for the moments before the first step is recorded.
    let liveSteps: [String]
    /// The turn's steps as they run, and the finished steps by message id. Passed in, not read
    /// from `AppChatConversation.shared`, so the panel is one component the window can host too
    /// (#323) rather than being wired to the compact chat's store.
    let liveActivity: [ActivityStep]
    let activityByMessageID: [UUID: [ActivityStep]]
    /// Compact beside the Corner, full in the window. `CornerRailRules` decides which cards a
    /// density draws; compact is exactly today's panel.
    var density: CornerRailDensity = .compact
    /// Detail mode for the live panel: Summary / Normal / Verbose (#331, #443).
    var initialDetailMode: LivePanelDetailMode = .normal
    /// Scope-specific affordances the window appends under the cards (add tools, app docs,
    /// preferred routes). Compact passes nothing, so it is unchanged. Kept here, inside the
    /// one scroll, rather than wrapping the panel in a second one.
    var trailing: AnyView? = nil

    @ObservedObject private var servers = MCPServerManager.shared
    @State var detailMode: LivePanelDetailMode = .normal
    /// What the app can do, read once per app: it does not change while a turn runs.
    @State private var canDo: [CanDoLine] = []
    /// The app's pack in full: the inventory's groups (actions, skills, menus, tools), shown
    /// in detail by the window's rail. The compact "Can do here" card summarises the same
    /// groups as counts.
    @State private var groups: [ScopeInventory.Group] = []
    /// The files the last finished answer made or named, found off the main thread.
    @State private var files: [URL] = []
    /// Sections the user folded, by title — Claude's chevrons.
    @State private var folded: Set<String> = []

    // MARK: - Initializers

    init(
        subject: PanelSubject,
        messages: [AIChatMessage],
        isAnswering: Bool,
        liveSteps: [String],
        liveActivity: [ActivityStep],
        activityByMessageID: [UUID: [ActivityStep]],
        density: CornerRailDensity = .compact,
        initialDetailMode: LivePanelDetailMode = .normal,
        trailing: AnyView? = nil
    ) {
        self.subject = subject
        self.messages = messages
        self.isAnswering = isAnswering
        self.liveSteps = liveSteps
        self.liveActivity = liveActivity
        self.activityByMessageID = activityByMessageID
        self.density = density
        self.initialDetailMode = initialDetailMode
        self.trailing = trailing
    }

    /// Convenience initializer preserving today's app-scoped call sites (#191, #323).
    init(
        appName: String,
        appBundleID: String,
        appIcon: NSImage?,
        messages: [AIChatMessage],
        isAnswering: Bool,
        liveSteps: [String],
        liveActivity: [ActivityStep],
        activityByMessageID: [UUID: [ActivityStep]],
        density: CornerRailDensity = .compact,
        initialDetailMode: LivePanelDetailMode = .normal,
        trailing: AnyView? = nil
    ) {
        self.init(
            subject: .app(name: appName, bundleID: appBundleID, icon: appIcon),
            messages: messages,
            isAnswering: isAnswering,
            liveSteps: liveSteps,
            liveActivity: liveActivity,
            activityByMessageID: activityByMessageID,
            density: density,
            initialDetailMode: initialDetailMode,
            trailing: trailing
        )
    }

    // MARK: - Backward-compatible accessors

    var appName: String {
        switch subject {
        case .app(let name, _, _): return name
        case .general: return "General Chat"
        case .combined(let participants):
            return ParticipantSet.formattedTitle(for: participants.map(\.name))
        }
    }

    var appBundleID: String {
        switch subject {
        case .app(_, let bundleID, _): return bundleID
        case .general, .combined: return ""
        }
    }

    var appIcon: NSImage? {
        switch subject {
        case .app(_, _, let icon): return icon
        case .general:
            return AIProviderIcon.appIcon(for: AppSettings.shared.selectedAIProvider)
        case .combined(let participants):
            return participants.first?.icon
        }
    }

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
        let recorded = activityByMessageID[answer.id] ?? answer.activity
        return ActivityStep.steps(recorded: recorded, receipts: answer.evidenceReceipts)
    }

    /// The Progress panel's one list: the turn's reasoning above the tool steps it ran.
    private var progressRows: [PanelProgressRow] {
        if isAnswering {
            let filtered = L.progressRows(
                reasoning: liveSteps, steps: ActivityStep.collapsingMCPWrappers(liveActivity))
            if !filtered.isEmpty { return filtered }
            return liveSteps.map(PanelProgressRow.reasoning)
        }
        guard let answer = lastTurnAnswer else { return [] }
        let filtered = L.progressRows(reasoning: answer.trace, steps: finishedSteps)
        if !filtered.isEmpty { return filtered }
        let fallbackTrace = answer.trace.isEmpty ? durableStepLines(for: answer) : answer.trace
        if !fallbackTrace.isEmpty || !finishedSteps.isEmpty {
            return fallbackTrace.map(PanelProgressRow.reasoning) + finishedSteps.map(PanelProgressRow.step)
        }
        return []
    }

    private func durableStepLines(for message: AIChatMessage) -> [String] {
        let lines = message.trace + message.mcpToolsRan
        return ActivityNarration.durableTrace(lines)
    }

    var body: some View {
        let steps = L.steps(
            isAnswering: isAnswering, live: liveActivity, finished: finishedSteps)
        let uploads = L.uploads(messages.filter { $0.role == .user }.map(\.attachments))

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                switch subject {
                case .app:
                    // Single App Pet: preserves today's single-app layout (#191, #323).
                    ForEach(CornerRailRules.cards(for: density), id: \.self) { card in
                        self.appCard(card, steps: steps, uploads: uploads)
                    }
                case .general, .combined:
                    // General Chat / Combined Chat: conversation-first side panel (#443).
                    conversationPanelBody(steps: steps, uploads: uploads)
                }

                if let trailing {
                    trailing
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .boardPanelCard()
        .animation(.smooth(duration: 0.18), value: steps.map(\.status))
        .animation(.smooth(duration: 0.18), value: files)
        .task(id: appBundleID) {
            if subject.isApp { loadCanDo() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDictionaryChanged)) { _ in
            if subject.isApp { loadCanDo() }
        }
        .task(id: filesKey) { await loadFiles() }
        .onAppear {
            if initialDetailMode != .normal {
                detailMode = initialDetailMode
            }
        }
    }

    // MARK: - General Chat & Combined Chat Panel (#443)

    @ViewBuilder
    private func conversationPanelBody(steps: [ActivityStep], uploads: [URL]) -> some View {
        // Header
        conversationHeader(steps)

        // 1. Progress (Summary / Normal / Verbose)
        if detailMode == .summary {
            section("Progress") {
                summaryProgress(steps)
            }
        } else {
            section("Progress", count: progressRows.count) {
                conversationProgress(progressRows)
            }
            if let shell = L.terminalStep(in: steps), detailMode == .verbose || shell.status == .running {
                section(shell.status == .running ? "Terminal — running" : "Terminal") {
                    terminal(shell)
                }
            }
        }

        // 2. Context (Normal / Verbose): attachments, selection, memory
        if detailMode != .summary {
            let contextSelection = lastAnswerSelection
            let memoryLines = memoryUsedLines
            let totalContext = uploads.count + contextSelection.count + memoryLines.count
            if totalContext > 0 {
                section("Context", count: totalContext) {
                    ForEach(uploads, id: \.self) { fileRow($0) }
                    ForEach(contextSelection, id: \.self) { url in
                        selectionRow(url)
                    }
                    ForEach(memoryLines, id: \.self) { mem in
                        PanelRow(symbol: "brain.head.profile", value: mem, trailing: "memory")
                    }
                }
            }
        }

        // 3. Apps in this chat (Normal / Verbose): Combined Chat participants, or General Chat borrowed app
        if detailMode != .summary {
            appsInThisChatSection(steps: steps)
        }

        // 4. Connectors (Normal / Verbose): grouped by source
        if detailMode != .summary {
            conversationConnectorsSection(steps: steps)
        }

        // 5. Skills & plugins (Verbose only): skills that fired or steer this chat
        if detailMode == .verbose {
            conversationSkillsSection(steps: steps)
        }

        // 6. Outputs (Summary / Normal / Verbose): files made or named
        if !files.isEmpty {
            section("Outputs", count: files.count) {
                ForEach(files, id: \.self) { fileRow($0) }
            }
        }
    }

    // MARK: - Headers

    @ViewBuilder
    private func conversationHeader(_ steps: [ActivityStep]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                switch subject {
                case .general:
                    AIProviderIcon(provider: AppSettings.shared.selectedAIProvider, size: 24)
                        .frame(width: 30, height: 30)
                case .combined(let participants):
                    stackedIcons(for: participants)
                        .frame(height: 30)
                case .app:
                    EmptyView()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(subject.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isAnswering ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        Text(generalSubtitle(steps))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)

            LivePanelDetailModePicker(mode: $detailMode, compact: true)
                .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func stackedIcons(for participants: [ConnectedPetInfo]) -> some View {
        HStack(spacing: -8) {
            ForEach(participants.prefix(3)) { pet in
                if let icon = pet.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1.5))
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 24, height: 24)
                }
            }
        }
    }

    private func generalSubtitle(_ steps: [ActivityStep]) -> String {
        let usage = ProviderContextUsageStore.shared.snapshot(for: .general)
        let model = usage.compactModel.isEmpty ? AppSettings.shared.selectedAIProvider.shortName : usage.compactModel
        if isAnswering {
            let done = steps.count { $0.status != .running }
            return steps.isEmpty ? "\(model) · Working…" : "\(model) · Working… \(done) of \(steps.count) done"
        }
        if steps.isEmpty {
            return "\(model) · Ready"
        }
        let failed = steps.count { $0.status == .failed || $0.status == .denied }
        let noun = steps.count == 1 ? "step" : "steps"
        return failed == 0 ? "\(model) · \(steps.count) \(noun)" : "\(model) · \(steps.count) \(noun) · \(failed) failed"
    }

    // MARK: - Apps in this chat (#443)

    @ViewBuilder
    private func appsInThisChatSection(steps: [ActivityStep]) -> some View {
        switch subject {
        case .combined(let participants):
            if !participants.isEmpty {
                section("Apps in this chat", count: participants.count) {
                    ForEach(participants) { pet in
                        let petSteps = steps.filter { step in
                            step.detail.contains(pet.bundleID) || step.title.contains(pet.name)
                        }
                        let trailingText = petSteps.isEmpty ? "connected" : "\(petSteps.count) \(petSteps.count == 1 ? "action" : "actions")"
                        PanelRow(icon: pet.icon, value: pet.name, trailing: trailingText)
                    }
                }
            }
        case .general:
            let borrowed = L.borrowedApps(in: steps)
            if !borrowed.isEmpty {
                section("Apps in this chat", count: borrowed.count) {
                    ForEach(borrowed, id: \.name) { app in
                        PanelRow(icon: app.icon, value: app.name, trailing: "used once")
                    }
                }
            }
        case .app:
            EmptyView()
        }
    }

    // MARK: - Conversation Connectors (#443)

    @ViewBuilder
    private func conversationConnectorsSection(steps: [ActivityStep]) -> some View {
        let borrowed = L.borrowedApps(in: steps)
        let linkedMcp = steps.filter { $0.kind == .mcp }.map { L.server(of: $0) }
        let uniqueMcp = Array(Set(linkedMcp.filter { !$0.isEmpty })).sorted()
        let hasShell = steps.contains { $0.kind == .command || $0.kind == .providerShell }
        let totalCount = 1 + (subject.isCombined ? (ifCombinedPetCount) : borrowed.count) + uniqueMcp.count + (hasShell ? 1 : 0)

        section("Connectors", count: totalCount) {
            // Source: DoraX / System
            let hostName = Host.current().localizedName ?? "Local Mac"
            PanelRow(symbol: "desktopcomputer", value: hostName, trailing: "ready")

            // Source: App Plugins & Adapters
            switch subject {
            case .combined(let participants):
                ForEach(participants) { pet in
                    if let adapter = AppAdapterManager.shared.adapter(for: pet.bundleID) {
                        PanelRow(
                            icon: pet.icon,
                            value: "\(adapter.appName) adapter",
                            trailing: adapter.isBuiltIn ? "built-in" : "\(adapter.actions.count) actions")
                    } else {
                        PanelRow(
                            icon: pet.icon,
                            value: "\(pet.name) adapter",
                            trailing: "connected")
                    }
                }
            case .general:
                ForEach(borrowed, id: \.name) { app in
                    PanelRow(
                        icon: app.icon,
                        value: "\(app.name) adapter",
                        trailing: "borrowed")
                }
            case .app:
                EmptyView()
            }

            // Source: Linked MCP Servers
            ForEach(uniqueMcp, id: \.self) { name in
                let inUse = steps.contains {
                    $0.kind == .mcp && L.server(of: $0) == name && $0.status == .running
                }
                let failed = steps.contains {
                    $0.kind == .mcp && L.server(of: $0) == name && ($0.status == .failed || $0.status == .denied)
                }
                let status = inUse ? "in use" : (failed ? "failed" : "called")
                PanelRow(symbol: "server.rack", value: name, trailing: status)
            }

            // Source: CLI shell
            if hasShell {
                let shellRunning = steps.contains {
                    ($0.kind == .command || $0.kind == .providerShell) && $0.status == .running
                }
                PanelRow(symbol: "terminal", value: "CLI shell", trailing: shellRunning ? "in use" : "ready")
            }
        }
    }

    private var ifCombinedPetCount: Int {
        if case .combined(let participants) = subject {
            return participants.count
        }
        return 0
    }

    // MARK: - Conversation Skills (#443)

    @ViewBuilder
    private func conversationSkillsSection(steps: [ActivityStep]) -> some View {
        var skillRows: [(name: String, source: String)] = []
        if let saved = lastTurnAnswer?.savedSkill {
            skillRows.append((saved.jobKey, "saved skill"))
        }
        if let pending = lastTurnAnswer?.pendingWriteSkillOffer {
            skillRows.append((pending.jobKey, "offer"))
        }
        for step in steps where step.kind == .tool && step.title.hasPrefix("Ran skill ") {
            let skillName = String(step.title.dropFirst("Ran skill ".count))
            skillRows.append((skillName, "active"))
        }

        if !skillRows.isEmpty {
            section("Skills & plugins", count: skillRows.count) {
                ForEach(skillRows, id: \.name) { row in
                    PanelRow(symbol: "wand.and.stars", value: row.name, trailing: row.source)
                }
            }
        }
    }

    // MARK: - Context helpers

    private var lastAnswerSelection: [URL] {
        guard let answer = lastTurnAnswer else { return [] }
        return answer.recentFiles.map(\.url)
    }

    private var memoryUsedLines: [String] {
        guard let answer = lastTurnAnswer else { return [] }
        return answer.trace.filter { $0.contains("memory") || $0.contains("Memory") }
    }

    private func selectionRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.and.square.on.square.dashed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("selection")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.8))
        }
        .frame(height: 24)
    }

    // MARK: - App Pet Card Layout (Today's Single-App Layout)

    @ViewBuilder
    private func appCard(_ card: CornerRailCard, steps: [ActivityStep], uploads: [URL]) -> some View {
        switch card {
        case .scope:
            VStack(alignment: .leading, spacing: 6) {
                PanelHeader(
                    icon: appIcon, title: appName.isEmpty ? "This app" : appName,
                    subtitle: subtitle(steps), status: isAnswering ? .orange : .green)
                LivePanelDetailModePicker(mode: $detailMode, compact: true)
                    .padding(.bottom, 6)
            }
        case .progress:
            if detailMode == .summary {
                section("Summary") {
                    summaryProgress(steps)
                }
            } else {
                section("Progress", count: progressRows.count) { progress(progressRows) }
                if let shell = L.terminalStep(in: steps), detailMode == .verbose || shell.status == .running {
                    section(shell.status == .running ? "Terminal — running" : "Terminal") {
                        terminal(shell)
                    }
                }
            }
        case .outputs:
            if detailMode != .summary {
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
            }
        case .connectors:
            if detailMode != .summary {
                section("Connectors") { appConnectors(steps) }
            }
        case .canDoHere:
            if detailMode != .summary, !groups.isEmpty {
                let totalItems = groups.reduce(0) { $0 + $1.items.count }
                section("Capabilities & Skills", count: totalItems) {
                    ForEach(groups) { group in
                        groupRow(group)
                    }
                }
            } else if detailMode != .summary, !canDo.isEmpty {
                section("Can do here", count: canDo.count) {
                    ForEach(canDo) { line in
                        PanelRow(symbol: line.symbol, value: line.title, trailing: "\(line.count)")
                    }
                }
            }
        case .usage:
            if detailMode != .summary {
                section("Usage") {
                    HStack(spacing: 6) {
                        ProviderContextChip(scope: GeneralChatScope.app(bundleId: appBundleID))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }
        case .appPack:
            if detailMode != .summary, !groups.isEmpty {
                section("App Pack", count: groups.count) {
                    ForEach(groups) { group in groupRow(group) }
                }
            }
        case .skills, .mods:
            EmptyView()
        }
    }

    @ViewBuilder
    private func summaryProgress(_ steps: [ActivityStep]) -> some View {
        let verdict = LivePanelDetailMode.verdict(
            evaluation: lastTurnAnswer?.subjectiveEvaluation,
            receipts: lastTurnAnswer?.evidenceReceipts ?? [],
            isError: lastTurnAnswer?.isError ?? false,
            fallback: isAnswering ? "Working…" : "Ready"
        )
        HStack(spacing: 6) {
            Image(systemName: verdict.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(verdict.isSuccess ? Color.green : Color.orange)
            Text(verdict.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 0)
            if !steps.isEmpty {
                Text("\(steps.count) \(steps.count == 1 ? "step" : "steps")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func groupRow(_ group: ScopeInventory.Group) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(group.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Text("\(group.items.count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ForEach(Array(group.items.prefix(8)), id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, design: group.isMonospaced ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 22)
            }
            if group.items.count > 8 {
                Text("+\(group.items.count - 8) more")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ steps: [ActivityStep]) -> String {
        if isAnswering {
            let done = steps.count { $0.status != .running }
            return steps.isEmpty ? "Working…" : "Working… \(done) of \(steps.count) done"
        }
        let totalCap = groups.reduce(0) { $0 + $1.items.count }
        let capSummary = totalCap > 0 ? "\(totalCap) tools & skills · " : ""
        if steps.isEmpty { return "\(capSummary)Ready" }
        let failed = steps.count { $0.status == .failed || $0.status == .denied }
        let noun = steps.count == 1 ? "step" : "steps"
        return failed == 0 ? "\(capSummary)Done · \(steps.count) \(noun)" : "\(capSummary)Done · \(failed) of \(steps.count) failed"
    }

    // MARK: - Sections

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

    // MARK: - Progress

    @ViewBuilder
    private func conversationProgress(_ rows: [PanelProgressRow]) -> some View {
        if rows.isEmpty {
            if isAnswering {
                stepRow(symbol: nil, title: "Thinking…", detail: "", trailing: nil, done: false)
            } else {
                Text("No steps recorded for this answer.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(rows) { row in
                switch row {
                case .reasoning(let line):
                    stepRow(
                        symbol: "checkmark.circle.fill", title: line, detail: "",
                        trailing: nil, tint: .secondary, done: true)
                case .step(let step):
                    let borrowed = L.borrowedApp(for: step)
                    stepRow(
                        symbol: symbol(for: step.status), title: step.title, detail: step.detail,
                        trailing: step.duration.map(Self.duration), tint: tint(for: step.status),
                        done: step.status == .ok, appIcon: borrowed?.icon)
                }
            }
            if isAnswering, !rows.contains(where: {
                if case .step(let step) = $0 { return step.status == .running }
                return false
            }) {
                stepRow(symbol: nil, title: "Working…", detail: "", trailing: nil, done: false)
            }
        }
    }

    @ViewBuilder
    private func progress(_ rows: [PanelProgressRow]) -> some View {
        if rows.isEmpty {
            if isAnswering {
                stepRow(symbol: nil, title: "Thinking…", detail: "", trailing: nil, done: false)
            } else {
                Text("No steps recorded for this answer.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(rows) { row in
                switch row {
                case .reasoning(let line):
                    stepRow(
                        symbol: "checkmark.circle.fill", title: line, detail: "",
                        trailing: nil, tint: .secondary, done: true)
                case .step(let step):
                    stepRow(
                        symbol: symbol(for: step.status), title: step.title, detail: step.detail,
                        trailing: step.duration.map(Self.duration), tint: tint(for: step.status),
                        done: step.status == .ok)
                }
            }
            if isAnswering, !rows.contains(where: {
                if case .step(let step) = $0 { return step.status == .running }
                return false
            }) {
                stepRow(symbol: nil, title: "Working…", detail: "", trailing: nil, done: false)
            }
        }
    }

    private func stepRow(
        symbol: String?, title: String, detail: String, trailing: String?,
        tint: Color = .secondary, done: Bool, appIcon: NSImage? = nil
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

            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

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

    // MARK: - Terminal

    private func terminal(_ step: ActivityStep) -> some View {
        let command = step.detail.isEmpty ? step.title : step.detail
        let output = L.outputTail(step.output)
        return PanelCode(
            text: "$ " + command
                + (output.isEmpty ? (step.status == .running ? "\n…" : "") : "\n" + output))
    }

    // MARK: - Files and outputs

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
        var found = await Task.detached(priority: .utility) {
            TurnFileExtractor.files(answer: text, stepOutputs: outputs)
                .filter { !excluded.contains($0.standardizedFileURL.path) }
        }.value
        for recent in answer.recentFiles {
            let path = recent.url.standardizedFileURL.path
            if !excluded.contains(path) && !found.contains(where: { $0.standardizedFileURL.path == path }) {
                found.append(recent.url)
            }
        }
        guard !Task.isCancelled else { return }
        files = found
    }

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

    // MARK: - App Connectors (Single App Pet)

    @ViewBuilder
    private func appConnectors(_ steps: [ActivityStep]) -> some View {
        let linked = servers.servers(forBundleId: appBundleID).map(\.name)
        let names = L.connectors(linked: linked, steps: steps)
        let adapter = AppAdapterManager.shared.adapter(for: appBundleID)
        if let adapter {
            PanelRow(
                symbol: "app.connected.to.app.below.fill",
                value: "\(adapter.appName) adapter",
                trailing: adapter.isBuiltIn ? "built-in" : "\(adapter.actions.count) actions")
        } else if appBundleID == "com.apple.finder" {
            PanelRow(
                symbol: "app.connected.to.app.below.fill",
                value: "Finder adapter",
                trailing: "built-in")
        }
        ForEach(names, id: \.self) { name in
            let inUse = steps.contains {
                $0.kind == .mcp && L.server(of: $0) == name && $0.status == .running
            }
            PanelRow(
                symbol: "server.rack", value: name,
                trailing: inUse ? "in use" : (linked.contains(name) ? "MCP" : "called"))
        }
        let hostName = Host.current().localizedName ?? "Local Mac"
        PanelRow(
            symbol: "desktopcomputer",
            value: hostName,
            trailing: "ready")

        if adapter == nil && appBundleID != "com.apple.finder" && names.isEmpty {
            Text("Nothing linked to \(appName.isEmpty ? "this app" : appName) yet")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Can do

    private func loadCanDo() {
        guard !appBundleID.isEmpty else { return }
        let inventory = ScopeInventory.app(bundleId: appBundleID, appName: appName)
        groups = inventory.groups
        canDo = inventory.groups
            .prefix(8)
            .map { CanDoLine(title: $0.title, symbol: $0.symbol, count: $0.items.count) }
    }
}
