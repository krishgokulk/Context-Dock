//
//  CapabilityCatalog.swift
//  Context-Dock
//
//  Everything DoraX can do, gathered into one list of records for `CapabilityIndex`.
//
//  Step 1 of docs/architecture/FRONTMOST_AGENT.md. The capability is all there — adapter
//  actions, skills, Global Commands, registered capabilities — spread across four stores
//  that six different matchers each read in their own way. This gathers them once, in one
//  shape, so a single ranking can answer "what are the best things I can do about this
//  sentence?"
//
//  The conversions are static and take their source object, so they can be tested without
//  a running app. Only `allRecords()` touches the live stores.
//

import Foundation

enum CapabilityCatalog {

    // MARK: - Conversions

    static func record(for action: AdapterAction, appName: String) -> CapabilityRecord {
        CapabilityRecord(
            id: "adapter.\(action.id)",
            app: appName,
            kind: .adapterAction,
            title: action.name,
            description: action.description,
            // The triggers are the words the user chose for this action; they belong in
            // the index for the same reason they exist.
            keywords: action.triggers,
            // An AI prompt asks the model something; everything else drives the app.
            isWrite: action.type != .aiPrompt)
    }

    static func record(for skill: AdapterSkill, appName: String) -> CapabilityRecord {
        CapabilityRecord(
            id: "skill.\(skill.id)",
            app: appName,
            kind: .skill,
            title: skill.name,
            description: skill.summary,
            keywords: [],
            // "Skills are instructions only — they never execute anything themselves."
            isWrite: false)
    }

    static func record(for command: SystemCommand) -> CapabilityRecord {
        CapabilityRecord(
            id: "globalcmd.\(command.id.uuidString)",
            app: "",
            kind: .globalCommand,
            title: command.name,
            description: command.description,
            // "provider:bluetooth" and friends are plumbing, not words anybody types.
            keywords: command.keywords.filter { !$0.lowercased().hasPrefix("provider:") },
            isWrite: true)
    }

    static func record(for capability: AICapability, appName: String) -> CapabilityRecord {
        CapabilityRecord(
            id: "capability.\(capability.id)",
            app: appName,
            kind: .capability,
            title: capability.title,
            description: "",
            // "reminders.create" carries two useful words that the title may not repeat.
            keywords: capability.id
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init),
            // AICapability has no read/write flag. Risk is the closest proxy the type
            // offers — reads are filed low, writes are not — and it is a proxy, not a
            // fact. If this proves wrong for a capability, the fix is a flag on the
            // capability rather than a special case here.
            isWrite: capability.riskLevel != .low)
    }

    // MARK: - The live catalogue

    /// Every capability currently available, machine-wide.
    ///
    /// Menu commands are deliberately absent for now: a warm cache holds hundreds per app,
    /// they would outnumber everything else, and idf would then be measuring menus rather
    /// than capability. They belong here once the ranking has been measured against real
    /// use — see the migration note in FRONTMOST_AGENT.md.
    @MainActor
    static func allRecords() -> [CapabilityRecord] {
        var records: [CapabilityRecord] = []

        for adapter in AppAdapterManager.shared.adapters where adapter.isEnabled {
            let name = adapter.appName
            records.append(contentsOf: adapter.actions.map { record(for: $0, appName: name) })
            records.append(
                contentsOf: SkillStore.shared.skills(for: adapter.bundleId)
                    .filter(\.isEnabled)
                    .map { record(for: $0, appName: name) })
        }

        for command in SystemCommandsRegistry.shared.commands where command.isEnabled {
            records.append(record(for: command))
        }

        for capability in CapabilityRegistry.shared.all {
            let appName = capability.appBundleID
                .flatMap { id in
                    AppAdapterManager.shared.adapters.first { $0.bundleId == id }?.appName
                } ?? ""
            records.append(record(for: capability, appName: appName))
        }

        // Two stores can describe the same thing — a Global Command mirrored from an
        // adapter, for one. Ranking the same capability twice would make it look like two
        // agreeing answers when it is one answer counted twice.
        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }
    }
}
