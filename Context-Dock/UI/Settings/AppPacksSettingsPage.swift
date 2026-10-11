import SwiftUI

/// Settings ▸ App Packs: every installed pack — one per app adapter, then the System packs
/// that group the Global Commands — each with one switch for the whole pack. No Discover:
/// in 1.0 this lists what is installed.
///
/// The page owns no state of its own worth keeping. Each switch writes the store that already
/// owns it (the adapter file, the Global Commands registry), and the detail page draws the
/// same groups as the Corner's app card.
struct AppPacksSettingsPage: View {
    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @ObservedObject private var commandsObserver = SystemCommandsRegistryObserver.shared
    @ObservedObject private var skillStore = SkillStore.shared
    @ObservedObject private var mcpManager = MCPServerManager.shared

    @State private var openPackID: String?

    var body: some View {
        let packs = AppPacks.all(
            adapters: adapterManager.adapters,
            commands: SystemCommandsRegistry.shared.commands,
            resources: AppPackLiveResources.resources(for:))

        if let pack = packs.first(where: { $0.id == openPackID }) {
            AppPackDetailView(pack: pack, back: { openPackID = nil })
        } else {
            list(packs)
        }
    }

    private func list(_ packs: [AppPack]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                packSection("Apps", packs.filter { !$0.isSystem },
                            empty: "No App Packs yet. Add one from Integrations.")
                packSection("System", packs.filter(\.isSystem),
                            empty: "No Global Commands to group.")
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func packSection(_ title: String, _ packs: [AppPack], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if packs.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(packs.enumerated()), id: \.element.id) { index, pack in
                        if index > 0 { Divider().padding(.leading, 52) }
                        AppPackRow(pack: pack, open: { openPackID = pack.id })
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor)))
            }
        }
    }
}

// MARK: - Live resources and the switch

/// What each app pack links, read from the stores that own it — the same sources the Corner's
/// card lists (`ScopeInventory.app`), counted rather than listed.
enum AppPackLiveResources {
    static func resources(for bundleID: String) -> AppPackResources {
        let adapter = AppAdapterManager.shared.adapters.first { $0.bundleId == bundleID }
        let menuCommands = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: bundleID, appName: adapter?.appName ?? "", query: "", maxResults: 500)
            .filter { $0.isLeaf && !$0.path.isEmpty }
            .count
        let servers = MCPServerManager.shared.servers(forBundleId: bundleID)
        let builtIns = CapabilityRegistry.shared.all.filter { $0.appBundleID == bundleID }.count
        let clis = TerminalPackageManager.shared.packages.filter {
            $0.isEnabled && $0.contextAppBundleIds.contains(bundleID)
        }.count
        return AppPackResources(
            skills: SkillStore.shared.skills(for: bundleID).filter(\.isEnabled).count,
            menuCommands: menuCommands,
            tools: builtIns + servers.count + clis,
            mcpServers: servers)
    }

    /// Turns a pack on or off in the store that owns it, and refreshes what the chat can use.
    static func setEnabled(_ enabled: Bool, pack: AppPack) {
        switch pack.kind {
        case .app(let bundleID):
            AppAdapterManager.shared.setEnabled(enabled, for: bundleID)
        case .system(let group):
            let registry = SystemCommandsRegistry.shared
            let before = registry.commands
            let after = AppPacks.commands(before, settingGroup: group, enabled: enabled)
            for (old, new) in zip(before, after) where old.isEnabled != new.isEnabled {
                registry.update(new)
            }
            SystemCommandsRegistryObserver.shared.reload()
            CapabilityRegistry.shared.refreshGlobalCommands()
        }
    }

    /// Opens the editor that already owns the pack's contents in Integrations.
    static func openEditor(for pack: AppPack) {
        let destination: IntegrationDestination
        switch pack.kind {
        case .app(let bundleID):
            destination = IntegrationDestination(scope: .apps, bundleID: bundleID, tab: .actions)
        case .system:
            destination = IntegrationDestination(scope: .global, tab: .actions, focus: .commands)
        }
        NotificationCenter.default.post(
            name: .openSettingsPage, object: nil,
            userInfo: SettingsRouteResolver.notificationPayload(for: destination))
    }
}

// MARK: - Pieces

struct AppPackIcon: View {
    let pack: AppPack
    var size: CGFloat = 28

    var body: some View {
        if let bundleID = pack.bundleID {
            IntegrationAppIcon(bundleID: bundleID, fallbackSymbol: pack.symbol)
                .frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color.gray.gradient)
                Image(systemName: pack.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }
}

struct AppPackSendsDataOutLabel: View {
    var body: some View {
        Label("Sends data out", systemImage: "arrow.up.forward.circle")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.12)))
            .help("Something in this pack can send data off this Mac: an AI prompt, a share or "
                + "send-to, a web link, or a tool that reaches the network.")
    }
}

private struct AppPackRow: View {
    let pack: AppPack
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    AppPackIcon(pack: pack)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(pack.name).font(.system(size: 13, weight: .medium))
                            if pack.sendsDataOut { AppPackSendsDataOutLabel() }
                        }
                        Text(pack.counts.summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(pack.name) App Pack, \(pack.counts.summary)"
                + (pack.sendsDataOut ? ", sends data out" : ""))
            .accessibilityHint("Shows what the pack can do")

            Toggle("", isOn: Binding(
                get: { pack.isEnabled },
                set: { AppPackLiveResources.setEnabled($0, pack: pack) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("\(pack.name) App Pack enabled")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(pack.isEnabled ? 1 : 0.6)
    }
}

// MARK: - Detail

/// One pack: the Corner card's groups — Can do · Knows · Sees now · Allowed — for an app
/// pack, and the commands it runs for a System pack.
private struct AppPackDetailView: View {
    let pack: AppPack
    let back: () -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: back) {
                    Label("All App Packs", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Back to all App Packs")

                header
                Divider()
                switch pack.kind {
                case .app(let bundleID): appGroups(bundleID: bundleID)
                case .system(let group): systemGroups(group)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppPackIcon(pack: pack, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pack.name).font(.system(size: 18, weight: .semibold))
                    if pack.sendsDataOut { AppPackSendsDataOutLabel() }
                }
                Text(pack.counts.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(pack.isSystem ? "Edit commands…" : "Edit actions…") {
                AppPackLiveResources.openEditor(for: pack)
            }
            Toggle("", isOn: Binding(
                get: { pack.isEnabled },
                set: { AppPackLiveResources.setEnabled($0, pack: pack) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("\(pack.name) App Pack enabled")
        }
    }

    @ViewBuilder
    private func appGroups(bundleID: String) -> some View {
        let adapter = AppAdapterManager.shared.adapters.first { $0.bundleId == bundleID }
        let inventory = ScopeInventory.app(bundleId: bundleID, appName: pack.name)
        AppScopeSection("Can do") {
            if inventory.canDoGroups.isEmpty {
                Text("Nothing yet — add actions with Edit actions…")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            AppScopeInventoryGroups(groups: inventory.canDoGroups, expanded: $expanded, limit: 40)
        }
        AppScopeSection("Knows") {
            if inventory.knowsGroups.isEmpty {
                Text("No skills for \(pack.name).").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            AppScopeInventoryGroups(groups: inventory.knowsGroups, expanded: $expanded, limit: 40)
        }
        AppScopeSection("Sees now") {
            AppScopeSeesNowList(lines: seesNowLines(bundleID: bundleID, adapter: adapter))
        }
        AppScopeSection("Allowed") { AppScopeAllowedList(bundleID: bundleID) }
    }

    /// What a question in the app would carry: the open page for a browser, and what the
    /// pack's context readers read. Nothing selected or attached — that belongs to a turn.
    private func seesNowLines(bundleID: String, adapter: AppAdapter?) -> [AppScopeContextLine] {
        let isBrowser = ScopedAppPromptBuilder.isBrowserBundle(bundleID)
        let page = AppScopeContext.lines(
            isBrowser: isBrowser,
            page: isBrowser ? BrowserPageReader.current(bundleId: bundleID) : nil,
            selection: nil, attachments: [])
        let readers = (adapter?.contextReaders ?? []).map {
            AppScopeContextLine(symbol: "eye", title: $0.name, detail: "Read when a question needs it")
        }
        return page + readers
    }

    @ViewBuilder
    private func systemGroups(_ group: SystemConnectorGroup) -> some View {
        let commands = SystemConnectors.connectors(
            from: SystemCommandsRegistry.shared.commands, includingDisabled: true)
            .first { $0.group == group }?.commands ?? []
        AppScopeSection("Can do") {
            AppScopeInventoryGroups(
                groups: [ScopeInventory.Group(
                    title: "Commands", symbol: "command",
                    items: commands.map { $0.isEnabled ? $0.name : "\($0.name) — off" })],
                expanded: $expanded, limit: 40)
        }
        AppScopeSection("Allowed") {
            Text("Chat reads a command's state without asking; changing it always asks first.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
