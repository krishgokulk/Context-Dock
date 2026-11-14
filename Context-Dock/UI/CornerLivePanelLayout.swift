// CornerLivePanelLayout.swift
// Context-Dock
//
// Layout, sizing, and data extraction rules for the live side panel (#191, #323, #443).
// Governs both compact Corner live panel and full window scope rail.

import AppKit
import Foundation

/// One participant Pet connected to a conversation (#443).
struct ConnectedPetInfo: Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
    let icon: NSImage?

    init(name: String, bundleID: String, icon: NSImage? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.icon = icon
    }

    static func == (lhs: ConnectedPetInfo, rhs: ConnectedPetInfo) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
        hasher.combine(name)
    }
}

/// The subject of a conversation side panel (#443).
/// Separates Mac-wide General Chat and Combined Chat from single-app Pet conversations.
enum PanelSubject: Hashable, Sendable {
    case app(name: String, bundleID: String, icon: NSImage?)
    case general
    case combined(participants: [ConnectedPetInfo])

    var isGeneral: Bool {
        if case .general = self { return true }
        return false
    }

    var isCombined: Bool {
        if case .combined = self { return true }
        return false
    }

    var isApp: Bool {
        if case .app = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .app(let name, _, _):
            return name.isEmpty ? "This app" : name
        case .general:
            return "General Chat"
        case .combined(let participants):
            return ParticipantSet.formattedTitle(for: participants.map(\.name))
        }
    }

    var bundleID: String? {
        switch self {
        case .app(_, let bundleID, _): return bundleID
        case .general, .combined: return nil
        }
    }

    static func == (lhs: PanelSubject, rhs: PanelSubject) -> Bool {
        switch (lhs, rhs) {
        case (.general, .general):
            return true
        case let (.app(n1, b1, _), .app(n2, b2, _)):
            return n1 == n2 && b1 == b2
        case let (.combined(p1), .combined(p2)):
            return p1 == p2
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .general:
            hasher.combine(0)
        case let .app(name, bundleID, _):
            hasher.combine(1)
            hasher.combine(name)
            hasher.combine(bundleID)
        case let .combined(participants):
            hasher.combine(2)
            hasher.combine(participants)
        }
    }
}

enum CornerLivePanelLayout {
    /// The panel's share of the chat card. The conversation keeps the larger part, as in
    /// Claude.
    static let panelFraction: CGFloat = 0.42

    /// The panel's width in a chat card this wide.
    static func panelWidth(card: CGFloat) -> CGFloat {
        (card * panelFraction).rounded()
    }

    /// Whether the chat card shows the panel. Only an app's Context Dock (Global's results
    /// have their own preview, General is its own surface), only in its conversation, only
    /// while the user has it open, and only once there is a turn to show.
    static func shows(
        isAppScope: Bool, phase: AppChatPromptPhase, isOpen: Bool, hasConversation: Bool
    ) -> Bool {
        isAppScope && phase == .chat && isOpen && hasConversation
    }

    /// The steps the panel lists: the turn running now, or the last one that finished.
    static func steps(
        isAnswering: Bool, live: [ActivityStep], finished: [ActivityStep]
    ) -> [ActivityStep] {
        isAnswering ? ActivityStep.collapsingMCPWrappers(live) : finished
    }

    /// The Progress panel's one list (#199, plan §3): the reasoning a turn recorded — why it
    /// acted (Understood / Lane / Chose / Shortcut / Gate) — above the tool steps that ran —
    /// what it did. Built from the turn's trace, not generated prose, so the panel shows the
    /// same reasoning the chat does rather than "No steps recorded". A reasoning line a step
    /// already states is dropped so nothing reads twice.
    static func progressRows(reasoning: [String], steps: [ActivityStep]) -> [PanelProgressRow] {
        let stepKeys = Set(steps.map { normalizeTrace($0.title) })
        let rows = ProgressTraceRules.reasoning(reasoning)
            .filter { !stepKeys.contains(normalizeTrace($0)) }
            .map(PanelProgressRow.reasoning)
        return rows + steps.map(PanelProgressRow.step)
    }

    /// A trace line and a step title compared without their trailing "…"/punctuation or case.
    static func normalizeTrace(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " ….")).lowercased()
    }

    /// Everything the user attached in this conversation, oldest first, each once.
    static func uploads(_ attachments: [[URL]]) -> [URL] {
        var seen: Set<String> = []
        return attachments.flatMap { $0 }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// How many of the output's last lines the panel quotes.
    static let outputLines = 14

    /// A command's output as the panel quotes it: its last `lines` non-empty-trailing lines,
    /// because the end is what a running command just said.
    static func outputTail(_ output: String, lines: Int = outputLines) -> String {
        var all = output.components(separatedBy: .newlines)
        while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            all.removeLast()
        }
        guard all.count > lines else { return all.joined(separator: "\n") }
        return "…\n" + all.suffix(lines).joined(separator: "\n")
    }

    /// The step whose output the panel shows: the latest shell command — the one running
    /// now, or the last one that said something.
    static func terminalStep(in steps: [ActivityStep]) -> ActivityStep? {
        let shells = steps.filter { $0.kind == .command || $0.kind == .providerShell }
        return shells.last { $0.status == .running } ?? shells.last { !$0.output.isEmpty }
            ?? shells.last
    }

    /// The connectors in play: the MCP servers linked to this app, then any other server
    /// this turn called, each named once.
    static func connectors(linked: [String], steps: [ActivityStep]) -> [String] {
        var names: [String] = []
        for name in linked + steps.filter({ $0.kind == .mcp }).map(server(of:))
        where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        return names
    }

    /// The server an MCP step called: "Ran search via github" → "github"; a step that does
    /// not name its server is named by its tool.
    static func server(of step: ActivityStep) -> String {
        if let via = step.title.range(of: " via ", options: .backwards) {
            return String(step.title[via.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        let title = step.title.hasPrefix("Ran ") ? String(step.title.dropFirst(4)) : step.title
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// Detects if an activity step borrowed or executed an app action (#443).
    /// Returns the app's display name and its icon if found.
    static func borrowedApp(for step: ActivityStep) -> (name: String, icon: NSImage?)? {
        let title = step.title
        for prefix in ["Ran ", "Read ", "Searched ", "Fetched "] {
            if title.hasPrefix(prefix) {
                let rest = title.dropFirst(prefix.count)
                if let colonIdx = rest.firstIndex(of: ":") {
                    let candidate = String(rest[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    if !candidate.isEmpty, let icon = AppContextPicker.icon(forAppNamed: candidate) {
                        return (candidate, icon)
                    }
                }
                let firstWord = String(rest.split(separator: " ").first ?? "")
                if !firstWord.isEmpty, let icon = AppContextPicker.icon(forAppNamed: firstWord) {
                    return (firstWord, icon)
                }
            }
        }

        let detail = step.detail
        let knownApps = [
            ("Finder", "com.apple.finder"),
            ("Safari", "com.apple.Safari"),
            ("Notes", "com.apple.Notes"),
            ("Messages", "com.apple.MobileSMS"),
            ("Mail", "com.apple.mail"),
            ("Calendar", "com.apple.iCal"),
            ("Reminders", "com.apple.reminders"),
            ("Music", "com.apple.Music"),
            ("Terminal", "com.apple.Terminal"),
            ("Xcode", "com.apple.dt.Xcode")
        ]
        for (name, bundleID) in knownApps {
            if detail.contains(bundleID) || detail.contains(bundleID.lowercased()) {
                return (name, AppContextPicker.icon(forAppNamed: name))
            }
        }

        if let appRange = detail.range(of: "app: ") {
            let candidate = String(detail[appRange.upperBound...]).components(separatedBy: " · ").first ?? ""
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, let icon = AppContextPicker.icon(forAppNamed: trimmed) {
                return (trimmed, icon)
            }
        }
        return nil
    }

    /// Returns deduplicated apps borrowed across the provided steps (#443).
    static func borrowedApps(in steps: [ActivityStep]) -> [(name: String, icon: NSImage?)] {
        var seen = Set<String>()
        var apps: [(name: String, icon: NSImage?)] = []
        for step in steps {
            if let borrowed = borrowedApp(for: step) {
                if seen.insert(borrowed.name.lowercased()).inserted {
                    apps.append(borrowed)
                }
            }
        }
        return apps
    }

    /// Resolves the canonical PanelSubject from conversation kind and participants (#443).
    static func subject(
        kind: ConversationKind,
        participants: ParticipantSet,
        fallbackAppName: String?
    ) -> PanelSubject {
        switch kind {
        case .general:
            return .general
        case .combined:
            let pets = participants.map { p in
                let icon = AppContextPicker.icon(forAppNamed: p.displayName)
                    ?? GeneralChatWindowModel.appIcon(for: p.petID.dockBundleID)
                return ConnectedPetInfo(name: p.displayName, bundleID: p.petID.dockBundleID, icon: icon)
            }
            return .combined(participants: pets)
        case .appPet(let petID):
            let name = participants.first?.displayName ?? fallbackAppName ?? "App"
            let bundleID = petID.dockBundleID
            let icon = AppContextPicker.icon(forAppNamed: name)
                ?? GeneralChatWindowModel.appIcon(for: bundleID)
            return .app(name: name, bundleID: bundleID, icon: icon)
        }
    }
}
