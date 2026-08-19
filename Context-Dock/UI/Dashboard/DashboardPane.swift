//
//  DashboardPane.swift
//  Context-Dock
//
//  The General Chat window's third mode. It is a reading surface, not a second
//  launcher: nothing here starts a conversation, and the only action it offers is
//  jumping to a conversation you already had. That keeps it inside the unified dock
//  surface rule — one shell, one job per mode.
//

import SwiftUI

struct DashboardPane: View {
    @ObservedObject private var metrics = DashboardMetrics.shared
    @ObservedObject private var model = GeneralChatWindowModel.shared
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }
    private var snapshot: DashboardSnapshot { metrics.snapshot }

    /// Connector groups start collapsed — the card is a status summary first, a directory
    /// second.
    @State private var expandedKinds: Set<ConnectorRow.Kind> = []
    @State private var showsAllAdapters = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if snapshot.isEmpty {
                    emptyState
                } else {
                    tiles
                    connectorsCard
                    adaptersCard
                    graphCard
                    HStack(alignment: .top, spacing: 16) {
                        workflowCard
                        routesCard
                    }
                    activityCard
                    if !snapshot.providers.isEmpty { providerCard }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { metrics.refreshIfStale() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dashboard")
                    .font(.system(size: 20, weight: .semibold))
                Text("Read from your local threads, task runs and learned routes — nothing is sent anywhere to build this.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                metrics.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Rebuild from disk")
            Text(Self.stamp(snapshot.generatedAt))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 60)
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing to chart yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Hold a conversation, attach an app or a folder, and this fills in with your own work — no sample data.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Tiles

    private var tiles: some View {
        // Single headline numbers, so they are tiles rather than a bar chart of unrelated
        // quantities — different units on one axis is not a chart.
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
            spacing: 10
        ) {
            StatTile(title: "Conversations", value: "\(snapshot.threads)",
                     detail: "\(snapshot.messages) messages", symbol: "bubble.left.and.bubble.right")
            StatTile(title: "Apps connected", value: "\(snapshot.connectedApps)",
                     detail: snapshot.combinedChats == 1
                        ? "1 combined chat" : "\(snapshot.combinedChats) combined chats",
                     symbol: "square.grid.2x2")
            StatTile(
                title: "Written down",
                value: "\(snapshot.notes)",
                detail: snapshot.memoryFacts == 0
                    ? "notes in memory"
                    : "notes · \(snapshot.memoryFacts) saved facts",
                symbol: "note.text")
            StatTile(
                title: "Capabilities",
                value: "\(snapshot.reachableActions)",
                detail: snapshot.totalActions == snapshot.reachableActions
                    ? "actions ready to run"
                    : "of \(snapshot.totalActions) — rest not reachable",
                symbol: "bolt")
            StatTile(
                title: "Task success",
                value: snapshot.taskSuccessRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                detail: snapshot.taskRuns == 0 ? "no runs yet" : "\(snapshot.taskRuns) runs",
                symbol: "checkmark.seal")
        }
    }

    // MARK: Cards

    // MARK: Connectors

    private var connectorsCard: some View {
        DashboardCard(
            title: "Connectors",
            subtitle: "What DoraX can reach, and the state each one is actually in"
        ) {
            if snapshot.connectors.isEmpty {
                DashboardEmptyNote(
                    symbol: "cable.connector",
                    text: "No adapters, MCP servers, API connections or CLI tools configured yet.")
            } else {
                VStack(spacing: 6) {
                    ForEach(ConnectorRow.Kind.allCases, id: \.self) { kind in
                        let rows = snapshot.connectors.filter { $0.kind == kind }
                        if !rows.isEmpty {
                            connectorGroup(kind, rows: rows)
                        }
                    }
                }
            }
        }
    }

    /// Each kind collapses to one summary line. Sixty adapters listed in full pushed every
    /// other card off the screen — the count and the state breakdown is what the summary is
    /// for, and the names are one click away.
    private func connectorGroup(_ kind: ConnectorRow.Kind, rows: [ConnectorRow]) -> some View {
        let expanded = expandedKinds.contains(kind)
        let notReady = rows.filter { $0.state != .ready && $0.state != .configured }
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    if expanded { expandedKinds.remove(kind) } else { expandedKinds.insert(kind) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: kind.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(kind.title)
                        .font(.system(size: 11, weight: .medium))
                    Text("\(rows.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if notReady.isEmpty {
                        StatusPill(state: rows.first?.state ?? .ready)
                    } else {
                        // Say what is wrong in the collapsed line, so collapsing never hides
                        // the one thing worth acting on.
                        Text("\(notReady.count) need attention")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        StatusPill(state: notReady[0].state)
                    }
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 8) {
                            Text(row.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Text(row.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            StatusPill(state: row.state)
                        }
                        .padding(.vertical, 3)
                        .padding(.leading, 21)
                    }
                }
                .padding(.bottom, 4)
            }
            Divider().opacity(0.25)
        }
    }

    // MARK: Adapters

    private var adaptersCard: some View {
        DashboardCard(
            title: "Adapters & capabilities",
            subtitle: "Every action per app, split by whether it runs straight away or asks first"
        ) {
            if snapshot.adapters.isEmpty {
                DashboardEmptyNote(
                    symbol: "square.grid.2x2",
                    text: "No app adapters yet.")
            } else {
                let shown = showsAllAdapters
                    ? snapshot.adapters
                    : Array(snapshot.adapters.prefix(8))
                VStack(spacing: 8) {
                    // Two columns: the list is long and each row is short, so a single
                    // column wasted half the card and doubled its height.
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)],
                        spacing: 8
                    ) {
                        ForEach(shown) { adapter in
                            adapterRow(adapter)
                        }
                    }

                    if snapshot.adapters.count > 8 {
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) { showsAllAdapters.toggle() }
                        } label: {
                            Text(showsAllAdapters
                                 ? "Show top 8"
                                 : "Show all \(snapshot.adapters.count) adapters")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Three states, three reserved status colours, each spelled out — the
                    // bars above never carry meaning by colour alone.
                    HStack(spacing: 14) {
                        riskLegend("Runs directly", DashboardPalette.good(dark))
                        riskLegend("Asks first", DashboardPalette.warning(dark))
                        riskLegend("Destructive", DashboardPalette.critical(dark))
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func adapterRow(_ adapter: AdapterRow) -> some View {
        let peak = max(1, snapshot.adapters.map(\.actionCount).max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: adapter.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(adapter.isReachable ? .secondary : .tertiary)
                    .frame(width: 14)
                Text(adapter.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(adapter.isReachable ? .primary : .secondary)
                    .lineLimit(1)
                if !adapter.isBuiltIn {
                    Text("yours")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(DashboardPalette.grid(dark)))
                }
                Spacer(minLength: 8)
                Text(adapter.statusLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("\(adapter.actionCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }

            // Split by what running the action costs the user: fires directly, asks first,
            // or is marked destructive. Status colours, each named in the legend below.
            GeometryReader { proxy in
                let scale = proxy.size.width / CGFloat(peak)
                HStack(spacing: 2) {  // 2px surface gap between segments
                    if adapter.directCount > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DashboardPalette.good(dark).opacity(adapter.isReachable ? 1 : 0.35))
                            .frame(width: max(3, CGFloat(adapter.directCount) * scale))
                    }
                    if adapter.approvalCount > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DashboardPalette.warning(dark).opacity(adapter.isReachable ? 1 : 0.35))
                            .frame(width: max(3, CGFloat(adapter.approvalCount) * scale))
                    }
                    if adapter.destructiveCount > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DashboardPalette.critical(dark).opacity(adapter.isReachable ? 1 : 0.35))
                            .frame(width: max(3, CGFloat(adapter.destructiveCount) * scale))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
        }
        .help("""
            \(adapter.name) — \(adapter.statusLabel)
            \(adapter.directCount) run directly, \(adapter.approvalCount) ask first, \
            \(adapter.destructiveCount) destructive
            """)
    }

    private var graphCard: some View {
        DashboardCard(
            title: "Knowledge graph",
            subtitle: "What you said and what you wrote, against the apps, folders and tools they reached"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if snapshot.knowledge.isEmpty {
                    DashboardEmptyNote(
                        symbol: "point.3.connected.trianglepath.dotted",
                        text: snapshot.unlinkedNodes > 0
                            ? "\(snapshot.unlinkedNodes) conversations and notes, none of them linked to anything yet. Scope a chat to an app or a folder, or name an app in a note, and the graph builds itself."
                            : "No scoped conversations yet — attach an app or a folder to a chat and the links show up here.")
                } else {
                    KnowledgeGraphView(graph: snapshot.knowledge) { nodeID in
                        openThread(nodeID)
                    }
                    .frame(height: 380)

                    HStack(spacing: 16) {
                        ForEach(KnowledgeNode.Kind.allCases, id: \.self) { kind in
                            legendEntry(kind)
                        }
                        Spacer(minLength: 0)
                        if snapshot.unlinkedNodes > 0 {
                            Text("\(snapshot.unlinkedNodes) unlinked")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .help("Conversations and notes that connect to nothing yet — scope a chat to an app or folder, or name one in a note, and it joins the graph.")
                        }
                        Text("Click a conversation to open it")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// The legend is always present — colour is never the only carrier of identity, and
    /// each entry repeats the node's shape as well as its hue.
    private func riskLegend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func legendEntry(_ kind: KnowledgeNode.Kind) -> some View {
        HStack(spacing: 5) {
            Image(systemName: kind.symbol)
                .font(.system(size: 9))
                .foregroundStyle(DashboardPalette.color(for: kind, dark: dark))
            Text(kind.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var workflowCard: some View {
        DashboardCard(
            title: "Chat workflows",
            subtitle: "What a request turns into once it starts work"
        ) {
            WorkflowFlowView(snapshot: snapshot)
        }
    }

    private var routesCard: some View {
        DashboardCard(
            title: "Learned routes",
            subtitle: "Where the resolver has an opinion, and how it earned it"
        ) {
            if snapshot.routes.isEmpty {
                DashboardEmptyNote(
                    symbol: "arrow.triangle.turn.up.right.diamond",
                    text: "No route outcomes recorded yet.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.routes) { route in
                        routeRow(route)
                    }
                }
            }
        }
    }

    private func routeRow(_ route: RouteRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(route.intent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(route.app)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(route.successes)/\(route.attempts)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    if route.successes > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DashboardPalette.good(dark))
                            .frame(width: proxy.size.width * CGFloat(route.successes) / CGFloat(route.attempts))
                    }
                    if route.failures > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DashboardPalette.critical(dark))
                    }
                }
            }
            .frame(height: 6)
        }
        .help("\(route.route) — \(route.successes) succeeded, \(route.failures) failed")
    }

    private var activityCard: some View {
        DashboardCard(
            title: "Activity",
            subtitle: "Messages per day, last 14 days"
        ) {
            ActivityChartView(days: snapshot.activity)
        }
    }

    private var providerCard: some View {
        DashboardCard(
            title: "Provider budget",
            subtitle: "Last rate-limit headers each provider returned"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.providers) { usage in
                    HStack(spacing: 8) {
                        Text(usage.providerName)
                            .font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 6)
                        if let remaining = usage.remainingRequests, let limit = usage.limitRequests {
                            Text("\(remaining)/\(limit) requests")
                                .font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if let reset = usage.resetText {
                            Text("resets \(reset)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    /// A node id is `thread:` plus the scope's storage key. Match it back to a real session
    /// rather than reconstructing a scope from the string — the index is the authority.
    private func openThread(_ nodeID: String) {
        let key = String(nodeID.dropFirst("thread:".count))
        guard let session = model.sessions.first(where: { $0.scope.storageKey == key }) else { return }
        GeneralChatWindowChromeState.shared.mode = .chat
        model.openSession(session.scope, title: session.title)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "built \(formatter.string(from: date))"
    }
}

// MARK: - Pieces

/// A connector's state, as a word plus a colour — never a colour on its own, and never a
/// word the store cannot back up.
private struct StatusPill: View {
    let state: ConnectorRow.State

    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    private var tint: Color {
        switch state {
        case .ready: return DashboardPalette.good(dark)
        case .configured: return DashboardPalette.app(dark)
        case .disabled: return DashboardPalette.warning(dark)
        case .unavailable: return DashboardPalette.critical(dark)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(state.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(DashboardPalette.grid(dark)))
        .fixedSize()
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DashboardPalette.surface(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(DashboardPalette.cardStroke(dark), lineWidth: 1)))
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DashboardPalette.surface(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DashboardPalette.cardStroke(dark), lineWidth: 1)))
    }
}
