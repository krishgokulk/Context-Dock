//
//  AgentPluginManifest.swift
//  Context-Dock
//
//  The plugin manager's one manifest shape (plan §4), and a read-only projection that
//  builds it from the registries that already exist. It is NOT a seventh registry: it
//  stores nothing and owns nothing. `CapabilityCatalog.allRecords()` is still the single
//  gather point for every registered capability (adapters, adapter skills, global
//  commands, registered capabilities); this groups those records into one manifest per
//  (app, kind) so Settings can show, per app, what each plugin can read and write, its
//  origin and — once there is data — its health.
//
//  Not the same thing as `PluginManifest` (UI/Plugins): that is Global Context's widget
//  extension format. This is the agent/capability manifest of §4. The names are kept
//  distinct on purpose so the two layers never merge.
//
//  Menu commands are deliberately not manifest capabilities here, the same way
//  `allRecords()` leaves them out (hundreds per app would swamp the index). The manager
//  shows them as a per-app count from `AppMenuCapabilityCache` instead — which is exactly
//  what the owner hand check asks for: "the 5 adapter tools and the menu count".
//

import AppKit
import Foundation

/// One plugin: every capability of one kind that one app (or the machine) exposes.
struct AgentPluginManifest: Identifiable, Equatable {

    /// Where a plugin came from, and therefore how far DoraX trusts it. A plugin can never
    /// raise its own trust level (§4.2); this is read off the kind, not self-declared.
    enum Origin: String, Equatable {
        case builtIn = "Built-in"
        case userAdded = "User-added"
        case doraXMade = "Made by DoraX"

        init(kind: CapabilityRecord.Kind) {
            switch kind {
            case .cliTool, .mcpTool: self = .userAdded
            default: self = .builtIn
            }
        }
    }

    /// One thing the plugin can do, carried straight from its `CapabilityRecord` so the
    /// mapping is lossless: the same id, kind, surface and read/write the index ranks on.
    struct Capability: Identifiable, Equatable {
        let id: String
        let title: String
        let kind: CapabilityRecord.Kind
        let surface: CapabilityRecord.Surface
        let isWrite: Bool
    }

    /// Reliability measured on this Mac (§4.2 / §5.5). No store feeds it yet, so it is
    /// `nil` for now and the UI says "no data yet" rather than inventing a number.
    struct Health: Equatable {
        let lastRun: Date?
        let successRate: Double?
    }

    /// `<bundleID-or-"system">/<kind>` — stable, so a manifest keeps its identity across
    /// rebuilds of the projection.
    let id: String
    /// Display name of the app, as the user would name it. "" / "System" for machine-wide.
    let app: String
    let bundleIDs: [String]
    let origin: Origin
    let kind: CapabilityRecord.Kind
    let capabilities: [Capability]
    let health: Health?

    /// Everything the plugin can read (not a write). A read-only plugin shows no gate.
    var reads: [Capability] { capabilities.filter { !$0.isWrite } }
    /// Everything the plugin can change or send. These always go through the gate at run
    /// time; the manager only lists them.
    var writes: [Capability] { capabilities.filter(\.isWrite) }

    var kindLabel: String { AgentPluginManifest.label(for: kind) }

    static func label(for kind: CapabilityRecord.Kind) -> String {
        switch kind {
        case .adapterAction: return "Built-in adapter"
        case .capability: return "Capability"
        case .cliTool: return "CLI"
        case .mcpTool: return "MCP server"
        case .skill: return "Skill"
        case .globalCommand: return "Global command"
        case .menuCommand: return "Menu command"
        }
    }
}

/// Groups the live capability records into manifests. The single front for the plugin
/// manager UI (§4.4): it reads `CapabilityCatalog`, `AppAdapterManager` and
/// `AppMenuCapabilityCache`, and writes to none of them.
enum AgentPluginManifestBuilder {

    /// One manifest per (app, kind), each manifest's capabilities sorted by title. Every
    /// record from `CapabilityCatalog.allRecords()` lands in exactly one manifest.
    @MainActor
    static func manifests() -> [AgentPluginManifest] {
        let records = CapabilityCatalog.allRecords()
        var bundleIDForApp = bundleIDMap()

        // A capability names its app with a bundle id, but `allRecords()` only fills in a
        // display name when an *enabled App Pack adapter* has that bundle id. Apple apps
        // (Mail, Notes, Calendar…) ship their capabilities without an adapter, so without
        // this they would all pile under "System". Resolve the app here, in the manager's
        // own layer, from the capability's bundle id — the capability index is untouched.
        var appOverrides: [String: String] = [:]
        var nameCache: [String: String?] = [:]
        for record in records where record.kind == .capability && record.app.isEmpty {
            let capID = String(record.id.dropFirst("capability.".count))
            guard let bundleID = CapabilityRegistry.shared.capability(id: capID)?.appBundleID,
                !bundleID.isEmpty
            else { continue }
            let name = nameCache[bundleID] ?? {
                let resolved = appDisplayName(forBundleID: bundleID)
                nameCache[bundleID] = resolved
                return resolved
            }()
            guard let name else { continue }
            appOverrides[record.id] = name
            if bundleIDForApp[name]?.contains(bundleID) != true {
                bundleIDForApp[name, default: []].append(bundleID)
            }
        }

        // Origin follows the adapter's own source flag, not the capability kind: an
        // imported adapter's actions must not wear the built-in badge. Skills carry no
        // source flag today, so they keep the kind default (noted as a follow-up).
        var originOverrides: [String: AgentPluginManifest.Origin] = [:]
        for adapter in AppAdapterManager.shared.adapters {
            let origin: AgentPluginManifest.Origin = adapter.isBuiltIn ? .builtIn : .userAdded
            for action in adapter.actions {
                originOverrides["adapter.\(action.id)"] = origin
            }
        }

        return manifests(
            from: records, bundleIDForApp: bundleIDForApp,
            appOverrides: appOverrides, originOverrides: originOverrides)
    }

    /// Pure core, so the mapping can be tested without a running app. `bundleIDForApp`
    /// resolves an app's display name to its bundle ids (an app can have more than one);
    /// `appOverrides` re-homes a record under a resolved app name when `allRecords()` left
    /// its `app` blank (keyed by record id).
    static func manifests(
        from records: [CapabilityRecord],
        bundleIDForApp: [String: [String]],
        appOverrides: [String: String] = [:],
        originOverrides: [String: AgentPluginManifest.Origin] = [:]
    ) -> [AgentPluginManifest] {
        func app(of record: CapabilityRecord) -> String {
            appOverrides[record.id] ?? record.app
        }
        func origin(of record: CapabilityRecord) -> AgentPluginManifest.Origin {
            originOverrides[record.id] ?? AgentPluginManifest.Origin(kind: record.kind)
        }

        // Group by (app, kind). A dictionary would lose order, so collect keys in first-
        // seen order and bucket alongside.
        var order: [GroupKey] = []
        var buckets: [GroupKey: [CapabilityRecord]] = [:]
        for record in records {
            let key = GroupKey(app: app(of: record), kind: record.kind)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(record)
        }

        return order.map { key in
            let group = buckets[key] ?? []
            let capabilities = group
                .map { record in
                    AgentPluginManifest.Capability(
                        id: record.id, title: record.title, kind: record.kind,
                        surface: record.surface, isWrite: record.isWrite)
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let bundleIDs = key.app.isEmpty ? [] : (bundleIDForApp[key.app] ?? [])
            let slug = bundleIDs.first ?? (key.app.isEmpty ? "system" : key.app)
            // A plugin can only lower its trust, never raise it (§4.2): if any member of a
            // group is user-added, the whole group is shown as user-added rather than
            // lending it the built-in badge.
            let origins = group.map(origin(of:))
            let origin: AgentPluginManifest.Origin = origins.contains(.userAdded)
                ? .userAdded
                : (origins.first ?? AgentPluginManifest.Origin(kind: key.kind))
            return AgentPluginManifest(
                id: "\(slug)/\(key.kind.rawValue)",
                app: key.app,
                bundleIDs: bundleIDs,
                origin: origin,
                kind: key.kind,
                capabilities: capabilities,
                health: nil)
        }
    }

    /// An app's user-facing name from its bundle id, for apps without an App Pack adapter.
    /// `FileManager.displayName` localizes and drops ".app" ("com.apple.mail" → "Mail").
    @MainActor
    private static func appDisplayName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// Menu commands DoraX has learned for an app. Shown as a count, not as manifest
    /// capabilities, to match `allRecords()` leaving menus out.
    @MainActor
    static func menuCommandCount(bundleID: String) -> Int {
        AppMenuCapabilityCache.shared.summary(bundleIdentifier: bundleID)?.recordCount ?? 0
    }

    @MainActor
    private static func bundleIDMap() -> [String: [String]] {
        var map: [String: [String]] = [:]
        for adapter in AppAdapterManager.shared.adapters where !adapter.appName.isEmpty {
            map[adapter.appName, default: []].append(adapter.bundleId)
        }
        return map
    }

    private struct GroupKey: Hashable {
        let app: String
        let kind: CapabilityRecord.Kind
    }
}
