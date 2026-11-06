// CapabilitiesSkillsBoardCard.swift
// Context-Dock
//
// Capabilities & Skills Browser: browse and inspect available capabilities and learned skills in the surface (Issue #335).
//
// Reads existing capability & skill stores:
// - SystemCommandsRegistry (global macOS commands)
// - CapabilityRegistry (registered AI capabilities & tools)
// - AppAdapterManager (app-scoped actions & adapters)
// - SkillStore (authored adapter & surface skills)
// - SolvedSkillStore (automatically captured & verified learned skills)
//
// Provides a unified two-column board in the Corner Dock surface with search, filter tabs,
// detailed inspection panel, and direct activation into App Pet or General Chat.

import AppKit
import SwiftUI

// MARK: - Metrics

enum CapabilitiesSkillsBoardMetrics {
    static let headerHeight: CGFloat = 38
    static let footerHeight: CGFloat = 36
    static var size: CGSize { ClipboardBoardMetrics.size }
}

// MARK: - Filters

enum CapabilitiesSkillsBoardFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case capabilities = "Capabilities"
    case skills = "Skills"
    case learned = "Learned"

    var id: String { rawValue }
}

// MARK: - Item Kind & Safety

enum CapabilitiesSkillsItemKind: String, Equatable {
    case appAction = "App Action"
    case systemCommand = "System"
    case mcpTool = "Tool"
    case skill = "Skill"
    case solvedSkill = "Learned"
}

enum CapabilitiesSkillsSafety: String, Equatable {
    case read = "Read"
    case write = "Write"
    case guidance = "Guidance"
}

// MARK: - Board Item

struct CapabilitiesSkillsBoardItem: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let summary: String
    let kind: CapabilitiesSkillsItemKind
    let safety: CapabilitiesSkillsSafety
    let appName: String
    let appBundleId: String?
    let iconSymbol: String
    let iconImage: NSImage?
    let keywords: [String]
    let version: String?
    let isPinned: Bool
    let instructions: String?
    let toolCalls: [SolvedSkillToolCall]?
    let runCount: Int?
    let successCount: Int?

    static func == (lhs: CapabilitiesSkillsBoardItem, rhs: CapabilitiesSkillsBoardItem) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.summary == rhs.summary
    }
}

// MARK: - Browser Engine

enum CapabilitiesSkillsBrowser {
    static let provider = "skills"

    @MainActor
    static func items(
        query: String,
        filter: CapabilitiesSkillsBoardFilter
    ) -> [CapabilitiesSkillsBoardItem] {
        var allItems: [CapabilitiesSkillsBoardItem] = []

        // 1. System Commands (built-in system capabilities)
        let commands = SystemCommandsRegistry.shared.commands.filter {
            $0.isEnabled && $0.provider != Self.provider && !$0.hasOwnCornerBoard
        }
        for cmd in commands {
            let cleanKeywords = cmd.keywords.filter { !$0.lowercased().hasPrefix("provider:") }
            let item = CapabilitiesSkillsBoardItem(
                id: "cmd.\(cmd.id.uuidString)",
                name: cmd.name,
                subtitle: "macOS System",
                summary: cmd.description.isEmpty ? cmd.name : cmd.description,
                kind: .systemCommand,
                safety: cmd.interaction == "none" ? .write : .read,
                appName: "System",
                appBundleId: nil,
                iconSymbol: cmd.icon.isEmpty ? "command" : cmd.icon,
                iconImage: nil,
                keywords: cleanKeywords,
                version: nil,
                isPinned: false,
                instructions: cmd.script.isEmpty ? nil : cmd.script,
                toolCalls: nil,
                runCount: nil,
                successCount: nil
            )
            allItems.append(item)
        }

        // 2. App Adapters & Actions
        for adapter in AppAdapterManager.shared.adapters where adapter.isEnabled {
            let appName = adapter.appName
            let bundleId = adapter.bundleId
            let icon: NSImage? = {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    return NSWorkspace.shared.icon(forFile: url.path)
                }
                return nil
            }()

            for action in adapter.actions {
                let safety: CapabilitiesSkillsSafety = (action.type == .aiPrompt) ? .read : .write
                let item = CapabilitiesSkillsBoardItem(
                    id: "action.\(action.id)",
                    name: action.name,
                    subtitle: "\(appName) · \(action.type.displayName)",
                    summary: action.description.isEmpty ? action.name : action.description,
                    kind: .appAction,
                    safety: safety,
                    appName: appName,
                    appBundleId: bundleId,
                    iconSymbol: action.type == .aiPrompt ? "sparkles" : "app.fill",
                    iconImage: icon,
                    keywords: action.triggers,
                    version: nil,
                    isPinned: false,
                    instructions: nil,
                    toolCalls: nil,
                    runCount: nil,
                    successCount: nil
                )
                allItems.append(item)
            }
        }

        // 3. Registered AI Capabilities (5-tool engine, headless reads/writes, calendar, mail, etc.)
        for cap in CapabilityRegistry.shared.all {
            let bundleId = cap.appBundleID
            let appName: String = {
                if let bundleId, !bundleId.isEmpty {
                    if let adapter = AppAdapterManager.shared.adapters.first(where: { $0.bundleId == bundleId }) {
                        return adapter.appName
                    }
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                    }
                }
                return "DoraX"
            }()

            let icon: NSImage? = {
                if let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    return NSWorkspace.shared.icon(forFile: url.path)
                }
                return nil
            }()

            let safety: CapabilitiesSkillsSafety = cap.riskLevel == .low ? .read : .write
            let cleanKeywords = cap.id.split { !$0.isLetter && !$0.isNumber }.map(String.init)

            let item = CapabilitiesSkillsBoardItem(
                id: "cap.\(cap.id)",
                name: cap.title.isEmpty ? cap.id : cap.title,
                subtitle: "\(appName) · \(cap.id)",
                summary: "Tool capability `\(cap.id)` available to AI models in App Pet and General Chat.",
                kind: .mcpTool,
                safety: safety,
                appName: appName,
                appBundleId: bundleId,
                iconSymbol: safety == .read ? "eye.fill" : "bolt.fill",
                iconImage: icon,
                keywords: cleanKeywords,
                version: nil,
                isPinned: false,
                instructions: nil,
                toolCalls: nil,
                runCount: nil,
                successCount: nil
            )
            allItems.append(item)
        }

        // 4. Authored Adapter & Surface Skills (SkillStore)
        for skill in SkillStore.shared.skills where skill.isEnabled {
            let appName: String = {
                if !skill.surfaceId.isEmpty {
                    return "DoraX Surface"
                }
                if let adapter = AppAdapterManager.shared.adapters.first(where: { $0.bundleId == skill.adapterBundleId }) {
                    return adapter.appName
                }
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: skill.adapterBundleId) {
                    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                }
                return "General"
            }()

            let icon: NSImage? = {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: skill.adapterBundleId) {
                    return NSWorkspace.shared.icon(forFile: url.path)
                }
                return nil
            }()

            let item = CapabilitiesSkillsBoardItem(
                id: "skill.\(skill.id)",
                name: skill.name,
                subtitle: "\(appName) · v\(skill.version)",
                summary: skill.summary.isEmpty ? "Steering instructions bundle for \(appName)." : skill.summary,
                kind: .skill,
                safety: .guidance,
                appName: appName,
                appBundleId: skill.adapterBundleId.isEmpty ? nil : skill.adapterBundleId,
                iconSymbol: skill.isPinned ? "pin.fill" : "wand.and.stars",
                iconImage: icon,
                keywords: [skill.name, appName, "skill"],
                version: skill.version,
                isPinned: skill.isPinned,
                instructions: skill.instructions,
                toolCalls: nil,
                runCount: nil,
                successCount: nil
            )
            allItems.append(item)
        }

        // 5. Learned & Solved Skills (SolvedSkillStore)
        for solved in SolvedSkillStore.shared.skills {
            let bundleId = solved.bundleId
            let appName: String = {
                if let adapter = AppAdapterManager.shared.adapters.first(where: { $0.bundleId == bundleId }) {
                    return adapter.appName
                }
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                }
                return "App Pet"
            }()

            let icon: NSImage? = {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    return NSWorkspace.shared.icon(forFile: url.path)
                }
                return nil
            }()

            let safety: CapabilitiesSkillsSafety = solved.toolCalls.allSatisfy(\.isReadOnly) ? .read : .write
            let summary = "\(solved.toolCalls.count) tool calls • Run \(solved.runCount)x (\(solved.successCount) verified)"

            let item = CapabilitiesSkillsBoardItem(
                id: "solved.\(solved.id.uuidString)",
                name: solved.queryTemplate,
                subtitle: "\(appName) · Learned Skill",
                summary: summary,
                kind: .solvedSkill,
                safety: safety,
                appName: appName,
                appBundleId: bundleId,
                iconSymbol: "brain.head.profile",
                iconImage: icon,
                keywords: Array(solved.nonSlotWords) + [appName, "learned", "solved"],
                version: nil,
                isPinned: false,
                instructions: nil,
                toolCalls: solved.toolCalls,
                runCount: solved.runCount,
                successCount: solved.successCount
            )
            allItems.append(item)
        }

        // Deduplicate by ID
        var seen = Set<String>()
        let uniqueItems = allItems.filter { seen.insert($0.id).inserted }

        // Filter by tab
        let filteredByTab = uniqueItems.filter { item in
            switch filter {
            case .all:
                return true
            case .capabilities:
                return item.kind == .appAction || item.kind == .systemCommand || item.kind == .mcpTool
            case .skills:
                return item.kind == .skill
            case .learned:
                return item.kind == .solvedSkill
            }
        }

        // Filter by query
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty else {
            return filteredByTab
        }

        return filteredByTab.filter { item in
            let matchesName = item.name.lowercased().contains(trimmedQuery)
            let matchesSubtitle = item.subtitle.lowercased().contains(trimmedQuery)
            let matchesSummary = item.summary.lowercased().contains(trimmedQuery)
            let matchesAppName = item.appName.lowercased().contains(trimmedQuery)
            let matchesKeywords = item.keywords.contains { $0.lowercased().contains(trimmedQuery) }
            let matchesInstructions = item.instructions?.lowercased().contains(trimmedQuery) ?? false
            return matchesName || matchesSubtitle || matchesSummary || matchesAppName || matchesKeywords || matchesInstructions
        }
    }

    static func moved(from current: String?, in ids: [String], down: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(index + (down ? 1 : -1), 0), ids.count - 1)]
    }
}

// MARK: - Board View

struct CapabilitiesSkillsBoardCard: View {
    @ObservedObject var prompt: AppChatPromptModel
    @State private var focusedID: String?
    @State private var activeFilter: CapabilitiesSkillsBoardFilter = .all
    @State private var copiedNotice: String?

    private var size: CGSize { CapabilitiesSkillsBoardMetrics.size }

    private var items: [CapabilitiesSkillsBoardItem] {
        CapabilitiesSkillsBrowser.items(
            query: prompt.query,
            filter: activeFilter
        )
    }

    private var focusedItem: CapabilitiesSkillsBoardItem? {
        let currentItems = items
        return currentItems.first { $0.id == focusedID } ?? currentItems.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            HStack(alignment: .top, spacing: 0) {
                list
                    .frame(width: CornerBoardLayout.listWidth(
                        board: size.width, preview: .file(URL(fileURLWithPath: "/"))))
                Color.clear.frame(width: CornerBoardLayout.dividerWidth)
                preview
                    .frame(width: CornerBoardLayout.panelWidth(board: size.width))
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(BoardGlass())
        .onHover { _ in prompt.touch() }
        .onAppear {
            registerKeys()
        }
        .onDisappear {
            ScopedListKeyBridge.shared.move = nil
            ScopedListKeyBridge.shared.run = nil
        }
    }

    // MARK: - Keyboard Handling

    private func registerKeys() {
        let bridge = ScopedListKeyBridge.shared
        bridge.move = { down in
            let ids = items.map(\.id)
            guard !ids.isEmpty else { return false }
            focusedID = CapabilitiesSkillsBrowser.moved(from: focusedItem?.id, in: ids, down: down)
            prompt.touch()
            return true
        }
        bridge.run = {
            if let target = focusedItem {
                activate(target)
            }
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.purple.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))

            Text("Capabilities & Skills")
                .font(.system(size: 12, weight: .semibold))

            Text("\(items.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            // Filter pills
            HStack(spacing: 4) {
                ForEach(CapabilitiesSkillsBoardFilter.allCases) { filter in
                    Button {
                        activeFilter = filter
                        prompt.touch()
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 10.5, weight: activeFilter == filter ? .semibold : .regular))
                            .foregroundStyle(activeFilter == filter ? Color.primary : Color.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                activeFilter == filter
                                    ? Color.primary.opacity(0.12)
                                    : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .padding(.horizontal, 16)
        .frame(height: CapabilitiesSkillsBoardMetrics.headerHeight)
    }

    // MARK: - Left Column (List)

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if items.isEmpty {
                        VStack(spacing: 6) {
                            Text(prompt.query.isEmpty ? "No capabilities or skills found" : "No matches for \"\(prompt.query)\"")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                            Text("Try searching by app name, action name, or trigger keywords.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(items) { item in
                            row(item)
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: focusedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ item: CapabilitiesSkillsBoardItem) -> some View {
        let isSelected = item.id == (focusedItem?.id ?? items.first?.id)
        return HStack(spacing: 8) {
            if let icon = item.iconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5))
            } else {
                Image(systemName: item.iconSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint(for: item))
                    .frame(width: 20, height: 20)
                    .background(tint(for: item).opacity(0.12), in: RoundedRectangle(cornerRadius: 4.5))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // Safety / Kind badge
                    safetyBadge(for: item.safety)
                }

                HStack(spacing: 5) {
                    Text(item.appName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06), in: Capsule())

                    Text(item.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            focusedID = item.id
            prompt.touch()
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                activate(item)
            }
        )
    }

    // MARK: - Right Column (Inspection Preview)

    private var preview: some View {
        Group {
            if let item = focusedItem {
                VStack(alignment: .leading, spacing: 8) {
                    // Header Bar
                    HStack(spacing: 8) {
                        if let icon = item.iconImage {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: item.iconSymbol)
                                .font(.system(size: 14))
                                .foregroundStyle(tint(for: item))
                                .frame(width: 26, height: 26)
                                .background(tint(for: item).opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text("\(item.appName) · \(item.kind.rawValue)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            activate(item)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .bold))
                                Text(item.kind == .skill ? "Use Skill" : "Ask in Pet")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                    Divider().opacity(0.14)

                    // Scrollable Inspector Details
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            // Summary / Description
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Description")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                Text(item.summary)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))

                            // Keywords / Triggers
                            if !item.keywords.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Triggers & Keywords")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)

                                    FlowLayout(spacing: 4) {
                                        ForEach(item.keywords, id: \.self) { kw in
                                            Text(kw)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                                        }
                                    }
                                }
                            }

                            // Instructions for Skills
                            if let instructions = item.instructions, !instructions.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Steering Instructions")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .textCase(.uppercase)

                                        Spacer()

                                        if item.isPinned {
                                            Label("Pinned", systemImage: "pin.fill")
                                                .font(.system(size: 9.5, weight: .medium))
                                                .foregroundStyle(.blue)
                                        }

                                        if let v = item.version {
                                            Text("v\(v)")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    ScrollView(.vertical) {
                                        Text(instructions)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(8)
                                    }
                                    .frame(maxHeight: 180)
                                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }

                            // Tool calls for Learned Skills
                            if let toolCalls = item.toolCalls, !toolCalls.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Learned Execution Sequence")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .textCase(.uppercase)

                                        Spacer()

                                        if let runs = item.runCount, let successes = item.successCount {
                                            Text("\(runs) runs · \(successes) verified")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(Array(toolCalls.enumerated()), id: \.offset) { idx, call in
                                            HStack(spacing: 6) {
                                                Text("\(idx + 1).")
                                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                    .foregroundStyle(.secondary)

                                                Text(call.capability)
                                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(.primary)

                                                Spacer()

                                                Text(call.isReadOnly ? "Read" : "Write")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(call.isReadOnly ? Color.green : Color.orange)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(
                                                        (call.isReadOnly ? Color.green : Color.orange).opacity(0.12),
                                                        in: RoundedRectangle(cornerRadius: 3)
                                                    )
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                                        }
                                    }
                                }
                            }

                            // Metadata info
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Technical Specification")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                HStack(spacing: 12) {
                                    metaField(title: "ID", value: item.id)
                                    if let bundleId = item.appBundleId {
                                        metaField(title: "Bundle", value: bundleId)
                                    }
                                    metaField(title: "Safety", value: item.safety.rawValue)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Select a capability or skill to inspect")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func metaField(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("↑↓")
                    .font(.system(size: 10, weight: .bold))
                Text("Navigate")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("↩")
                    .font(.system(size: 10, weight: .bold))
                Text("Open in Pet")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)

            Spacer()

            if let item = focusedItem {
                Button {
                    copyItemDetails(item)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copiedNotice ?? "Copy Name")
                            .font(.system(size: 10.5))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy capability details to clipboard")
            }

            Button {
                prompt.leaveScopeForGlobal()
            } label: {
                Text("Esc Back")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: CapabilitiesSkillsBoardMetrics.footerHeight)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Helpers & Styling

    private func tint(for item: CapabilitiesSkillsBoardItem) -> Color {
        switch item.kind {
        case .skill: return .purple
        case .solvedSkill: return .indigo
        case .appAction: return .blue
        case .systemCommand: return .orange
        case .mcpTool: return .teal
        }
    }

    private func safetyBadge(for safety: CapabilitiesSkillsSafety) -> some View {
        let (color, text): (Color, String) = {
            switch safety {
            case .read: return (.green, "Read")
            case .write: return (.orange, "Write")
            case .guidance: return (.purple, "Guidance")
            }
        }()

        return Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func activate(_ item: CapabilitiesSkillsBoardItem) {
        prompt.leaveScopeForGlobal()
        if let bundleId = item.appBundleId, !bundleId.isEmpty {
            AppChatPromptModel.changeScope(app: item.appName, bundleID: bundleId)
            CornerChatPresentation.shared.showPet(
                target: CornerChatTarget(name: item.appName, bundleID: bundleId))
            prompt.query = item.name
            prompt.expectAnswer()
        } else {
            CornerChatPresentation.shared.show(.general)
            prompt.query = item.name
        }
    }

    private func copyItemDetails(_ item: CapabilitiesSkillsBoardItem) {
        let textToCopy: String
        if let instructions = item.instructions, !instructions.isEmpty {
            textToCopy = instructions
        } else {
            textToCopy = "\(item.name) (\(item.id)) - \(item.summary)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)

        copiedNotice = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedNotice = nil
        }
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width, currentX > 0 {
                currentX = 0
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            currentX += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
            height = max(height, currentY + maxHeightInRow)
        }

        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
    }
}
