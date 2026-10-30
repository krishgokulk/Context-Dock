// AppPetIdentity.swift
// Context-Dock
//
// Stable identity for an App Pet (#338). An App Pet is an app-scoped or CLI-scoped assistant
// profile over the shared DoraX engine and conversation stores. Names, icons and mutable
// running-app state do not belong in the identifier.

import Foundation

/// Stable identity for an App Pet in the Dock or a conversation scope.
enum AppPetID: Codable, Hashable, Sendable {
    case app(bundleID: String)
    case cli(command: String)

    static func normalizeCLICommand(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalized: AppPetID {
        switch self {
        case .app(let bundleID):
            return .app(bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines))
        case .cli(let command):
            return .cli(command: Self.normalizeCLICommand(command))
        }
    }

    var bundleID: String? {
        guard case .app(let bundleID) = normalized, !bundleID.isEmpty else { return nil }
        return bundleID
    }

    var cliCommand: String? {
        guard case .cli(let command) = normalized, !command.isEmpty else { return nil }
        return command
    }

    /// The string identifier the Dock uses (`<bundleID>` or `cli://<command>`).
    var dockBundleID: String {
        switch normalized {
        case .app(let bundleID): return bundleID
        case .cli(let command): return "cli://\(command)"
        }
    }

    init?(dockBundleID: String?) {
        guard let raw = dockBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        if raw.hasPrefix("cli://") {
            let command = Self.normalizeCLICommand(String(raw.dropFirst("cli://".count)))
            guard !command.isEmpty else { return nil }
            self = .cli(command: command)
        } else {
            self = .app(bundleID: raw)
        }
    }

    static func == (lhs: AppPetID, rhs: AppPetID) -> Bool {
        switch (lhs, rhs) {
        case (.app(let a), .app(let b)):
            return a.trimmingCharacters(in: .whitespacesAndNewlines)
                == b.trimmingCharacters(in: .whitespacesAndNewlines)
        case (.cli(let a), .cli(let b)):
            return normalizeCLICommand(a) == normalizeCLICommand(b)
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .app(let bundleID):
            hasher.combine(0)
            hasher.combine(bundleID.trimmingCharacters(in: .whitespacesAndNewlines))
        case .cli(let command):
            hasher.combine(1)
            hasher.combine(Self.normalizeCLICommand(command))
        }
    }

    /// Canonical key used for case-insensitive participant deduplication across macOS bundle IDs
    /// and CLI commands.
    var canonicalKey: String {
        switch normalized {
        case .app(let bundleID): return "app:\(bundleID.lowercased())"
        case .cli(let command): return "cli:\(command)"
        }
    }
}

/// One persistent Pet participant in an App Pet or Combined Chat conversation (#339).
struct ConversationParticipant: Codable, Hashable, Sendable, Identifiable {
    let petID: AppPetID
    var displayName: String

    var id: String { petID.canonicalKey }

    init(petID: AppPetID, displayName: String) {
        self.petID = petID.normalized
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = trimmed.isEmpty ? petID.dockBundleID : trimmed
    }

    init?(bundleID: String, displayName: String) {
        guard let petID = AppPetID(dockBundleID: bundleID) else { return nil }
        self.init(petID: petID, displayName: displayName)
    }

    static func == (lhs: ConversationParticipant, rhs: ConversationParticipant) -> Bool {
        lhs.petID.canonicalKey == rhs.petID.canonicalKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(petID.canonicalKey)
    }
}

/// First-class, ordered, deduplicated set of persistent Pet participants for a conversation (#339).
///
/// - `0` participants -> `ConversationKind.general`
/// - `1` participant -> `ConversationKind.appPet`
/// - `2+` participants -> `ConversationKind.combined`
struct ParticipantSet: Codable, Hashable, Sendable, RandomAccessCollection {
    private(set) var participants: [ConversationParticipant]

    static let empty = ParticipantSet([])

    init<S: Sequence>(_ items: S) where S.Element == ConversationParticipant {
        var seen = Set<String>()
        var ordered: [ConversationParticipant] = []
        for item in items {
            let key = item.petID.canonicalKey
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            ordered.append(item)
        }
        self.participants = ordered
    }

    var startIndex: Int { participants.startIndex }
    var endIndex: Int { participants.endIndex }
    subscript(position: Int) -> ConversationParticipant { participants[position] }

    var petIDs: [AppPetID] { participants.map(\.petID) }
    var bundleIDs: [String] { participants.compactMap(\.petID.bundleID) }
    var displayNames: [String] { participants.map(\.displayName) }

    func contains(_ petID: AppPetID) -> Bool {
        let key = petID.canonicalKey
        return participants.contains { $0.petID.canonicalKey == key }
    }

    func contains(bundleID: String) -> Bool {
        guard let petID = AppPetID(dockBundleID: bundleID) else { return false }
        return contains(petID)
    }

    func contains(appNamed name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return participants.contains {
            $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.petID.dockBundleID.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    func adding(_ participant: ConversationParticipant) -> ParticipantSet {
        adding([participant])
    }

    func adding<S: Sequence>(_ additions: S) -> ParticipantSet
    where S.Element == ConversationParticipant {
        ParticipantSet(participants + Array(additions))
    }

    func removing(_ petID: AppPetID) -> ParticipantSet {
        let key = petID.canonicalKey
        return ParticipantSet(participants.filter { $0.petID.canonicalKey != key })
    }

    var conversationKind: ConversationKind {
        switch participants.count {
        case 0:
            return .general
        case 1:
            return .appPet(participants[0].petID)
        default:
            return .combined
        }
    }

    /// Stable Combined Chat thread identifier for this participant set.
    ///
    /// Uses sorted lowercased display names so existing `"combined-finder+messages"` threads stay
    /// 100% compatible across the sidebar, session index, and promotion flow.
    var combinedThreadID: String {
        let tokens = participants.map { participant -> String in
            let name = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name.isEmpty ? participant.petID.dockBundleID : name).lowercased()
        }
        return "combined-" + tokens.sorted().joined(separator: "+")
    }

    var combinedScope: GeneralChatScope {
        .thread(id: combinedThreadID)
    }

    /// Canonical title for a Combined Chat or single-Pet participant set.
    var headerTitle: String {
        Self.formattedTitle(for: displayNames)
    }

    static func formattedTitle(for names: [String]) -> String {
        switch names.count {
        case 0:
            return "General Chat"
        case 1:
            return names[0]
        case 2:
            return "\(names[0]) + \(names[1])"
        default:
            return "\(names[0]) + \(names[1]) +\(names.count - 2)"
        }
    }
}

/// Persistent conversation identity, separate from temporary per-turn execution scope (#339).
///
/// - `.general`: Dora's Mac-wide conversation (`ParticipantSet` is empty). May borrow an app
///   capability for one turn via `TurnScope` without becoming an App Pet thread or loading Pet
///   memory.
/// - `.appPet`: Anchored single-Pet conversation (`ParticipantSet` has 1 Pet).
/// - `.combined`: Persistent multi-Pet workspace (`ParticipantSet` has 2+ connected Pets).
enum ConversationKind: Codable, Hashable, Sendable {
    case general
    case appPet(AppPetID)
    case combined

    /// True only when the conversation may load or update an App Pet's long memory.
    /// General Chat never loads or updates Pet memory, even when borrowing an app route for a turn.
    var loadsAppPetMemory: Bool {
        switch self {
        case .general: return false
        case .appPet, .combined: return true
        }
    }

    /// The app bundle ID whose Pet memory may be read for this conversation, or `nil` for General Chat.
    func memoryBundleID(scope: GeneralChatScope) -> String? {
        guard loadsAppPetMemory else { return nil }
        switch self {
        case .general:
            return nil
        case .appPet(let petID):
            return petID.bundleID
        case .combined:
            if case .app(let bundleId) = scope { return bundleId }
            return nil
        }
    }

    /// Canonical header title for the conversation.
    ///
    /// Enforces the identity invariant from `2026-10-27-app-pets-combined-chat-design.md` §2 & §3:
    /// a hybrid header such as `"Mail General Chat"` is never produced.
    func headerTitle(participants: ParticipantSet, fallbackAppName: String? = nil) -> String {
        switch self {
        case .general:
            return "General Chat"
        case .appPet(let petID):
            if let first = participants.first?.displayName, !first.isEmpty {
                return first
            }
            if let fallback = fallbackAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
                !fallback.isEmpty
            {
                return fallback
            }
            return petID.dockBundleID
        case .combined:
            let names = participants.displayNames
            guard !names.isEmpty else { return "Combined Chat" }
            return ParticipantSet.formattedTitle(for: names)
        }
    }
}

/// Pure presentation model for a conversation header (#339).
///
/// Guarantees that General Chat, single-Pet App Chat, and Combined Chat never mix identities into
/// a hybrid `"<App> General Chat"` header.
struct ConversationHeaderIdentity: Equatable, Sendable {
    let kind: ConversationKind
    let primaryTitle: String
    let subtitle: String?
    let participantNames: [String]
    let previewChips: [String]

    var title: String {
        primaryTitle
    }

    var showsProviderIcon: Bool {
        kind == .general
    }

    var combinedHeaderText: String {
        if let subtitle, !subtitle.isEmpty {
            return "\(primaryTitle) \(subtitle)"
        }
        return primaryTitle
    }

    static func make(
        kind: ConversationKind,
        participants: ParticipantSet,
        fallbackAppName: String? = nil,
        providerShortName: String? = nil,
        previewChips: [String] = []
    ) -> ConversationHeaderIdentity {
        switch kind {
        case .general:
            let trimmedProvider = providerShortName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedProvider, !trimmedProvider.isEmpty,
                trimmedProvider.caseInsensitiveCompare("General Chat") != .orderedSame
            {
                return ConversationHeaderIdentity(
                    kind: .general,
                    primaryTitle: trimmedProvider,
                    subtitle: "General Chat",
                    participantNames: [],
                    previewChips: previewChips)
            }
            return ConversationHeaderIdentity(
                kind: .general,
                primaryTitle: "General Chat",
                subtitle: nil,
                participantNames: [],
                previewChips: previewChips)

        case .appPet:
            let appTitle = kind.headerTitle(
                participants: participants, fallbackAppName: fallbackAppName)
            return ConversationHeaderIdentity(
                kind: kind,
                primaryTitle: appTitle,
                subtitle: "App Pet",
                participantNames: [appTitle],
                previewChips: previewChips)

        case .combined:
            let names = participants.displayNames
            let title = kind.headerTitle(
                participants: participants, fallbackAppName: fallbackAppName)
            return ConversationHeaderIdentity(
                kind: .combined,
                primaryTitle: title,
                subtitle: "Combined Chat",
                participantNames: names,
                previewChips: previewChips)
        }
    }
}

/// Temporary per-turn execution scope resolved for a single user request (#339).
///
/// Allows General Chat (`ConversationKind.general`) to borrow bounded app routes for one turn
/// without mutating `ConversationKind` or `ParticipantSet`, and expires as soon as the turn ends.
struct TurnScope: Equatable, Sendable {
    let borrowedParticipants: [ConversationParticipant]
    let ambiguousAppNames: [String]

    static let empty = TurnScope(borrowedParticipants: [], ambiguousAppNames: [])

    init(
        borrowedParticipants: [ConversationParticipant] = [],
        ambiguousAppNames: [String] = []
    ) {
        self.borrowedParticipants = ParticipantSet(borrowedParticipants).participants
        self.ambiguousAppNames = ambiguousAppNames
    }

    var isEmpty: Bool {
        borrowedParticipants.isEmpty && ambiguousAppNames.isEmpty
    }

    var isAmbiguous: Bool {
        !ambiguousAppNames.isEmpty
    }

    var petIDs: [AppPetID] {
        borrowedParticipants.map(\.petID)
    }

    var bundleIDs: [String] {
        borrowedParticipants.compactMap(\.petID.bundleID)
    }

    var displayNames: [String] {
        borrowedParticipants.map(\.displayName)
    }

    /// Closed clarification question when a request matches multiple competing apps for an
    /// ambiguous capability word.
    var clarificationQuestion: String? {
        guard !ambiguousAppNames.isEmpty else { return nil }
        guard ambiguousAppNames.count > 1 else {
            return "Which app should I use for this turn: \(ambiguousAppNames[0])?"
        }
        let sentence =
            ambiguousAppNames.dropLast().joined(separator: ", ")
            + " or " + (ambiguousAppNames.last ?? "")
        return "That could use \(sentence). Which app should I use for this turn?"
    }
}
