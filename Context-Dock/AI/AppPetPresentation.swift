// AppPetPresentation.swift
// Context-Dock
//
// Stage 5 (#342) detached Pet presentation models and 3-tier progressive disclosure lifecycle:
// - Tier 1: Floating Desktop Pet companion with pixel mascot, pinned bubbles, and micro-bar.
// - Tier 2: Compact Launcher / Dock view.
// - Tier 3: Expanded dual-pane window with conversation transcript and inspector rail.
//
// Follows docs/superpowers/specs/2026-10-27-app-pets-combined-chat-design.md §4 &
// docs/superpowers/specs/2026-10-28-pet-presentation-and-expansion-lifecycle.md.

import AppKit
import Foundation

/// The three presentation tiers for an App Pet (#342).
enum AppPetPresentationTier: String, Codable, Hashable, Sendable {
    /// Tier 1: Lightweight, non-activating floating desktop mascot panel with pinned bubbles.
    case tier1Mascot
    /// Tier 2: Compact launcher / Dock resting row with scoped input and running apps strip.
    case tier2Launcher
    /// Tier 3: Full expanded dual-pane window with message transcript and diagnostic rail.
    case tier3Expanded
}

/// Reactive states for the pixel mascot sprite in Tier 1.
enum AppPetMascotState: String, Codable, Hashable, Sendable {
    /// Calm resting eyes, periodic blinking animation.
    case idle
    /// Wide awake, animated shimmer / pulse during active LLM turn or tool execution.
    case thinking
    /// Closed happy eyes (^_^) with cute blush cheeks upon successful turn receipt.
    case completed
}

/// Status and kind of an action bubble displayed above the floating mascot.
enum AppPetActionBubbleKind: Codable, Hashable, Sendable {
    /// Translucent thinking bubble during LLM reasoning.
    case thinking(detail: String)
    /// Success receipt bubble with checkmark (e.g., "✓ Launch Safari: Safari is open.").
    case receipt(title: String, detail: String?)
    /// Tool execution bubble (e.g., "Save PDF to Downloads: Called js").
    case toolExecution(name: String, detail: String)
}

/// A pinned action bubble anchored above the floating mascot.
/// Pinned bubbles stay on screen permanently until the user explicitly dismisses them with `✕`.
struct AppPetActionBubble: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: AppPetActionBubbleKind
    var isPinned: Bool
    var createdAt: Date

    init(id: UUID = UUID(), kind: AppPetActionBubbleKind, isPinned: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.isPinned = isPinned
        self.createdAt = createdAt
    }

    var displayTitle: String {
        switch kind {
        case .thinking(let detail):
            return detail.isEmpty ? "Thinking…" : detail
        case .receipt(let title, _):
            return title
        case .toolExecution(let name, _):
            return name
        }
    }

    var displayDetail: String? {
        switch kind {
        case .thinking:
            return nil
        case .receipt(_, let detail):
            return detail
        case .toolExecution(_, let detail):
            return detail
        }
    }

    var isThinking: Bool {
        if case .thinking = kind { return true }
        return false
    }

    var isReceipt: Bool {
        if case .receipt = kind { return true }
        return false
    }
}

/// State of the micro-bar anchored under the mascot.
enum AppPetMicroBarState: String, Codable, Hashable, Sendable {
    /// Compact resting pill: `[✏️ Edit] [ılı Voice] [^ Launcher]`.
    case micro
    /// Expanded minimal inline input field: `[+] [Start new chat] [↑]`.
    case inlineInput
}

/// Persistent record for a detached Pet companion on the desktop.
struct DetachedPetRecord: Identifiable, Codable, Hashable, Sendable {
    let petID: AppPetID
    var appName: String
    var bundleID: String
    var positionX: Double
    var positionY: Double
    var mascotState: AppPetMascotState
    var microBarState: AppPetMicroBarState
    var pinnedBubbles: [AppPetActionBubble]
    var activeTier: AppPetPresentationTier
    var updatedAt: Date

    var id: String { petID.canonicalKey }

    init(
        petID: AppPetID,
        appName: String,
        bundleID: String,
        position: CGPoint,
        mascotState: AppPetMascotState = .idle,
        microBarState: AppPetMicroBarState = .micro,
        pinnedBubbles: [AppPetActionBubble] = [],
        activeTier: AppPetPresentationTier = .tier1Mascot,
        updatedAt: Date = Date()
    ) {
        self.petID = petID.normalized
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appName = trimmed.isEmpty ? petID.dockBundleID : trimmed
        self.bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.positionX = Double(position.x)
        self.positionY = Double(position.y)
        self.mascotState = mascotState
        self.microBarState = microBarState
        self.pinnedBubbles = pinnedBubbles
        self.activeTier = activeTier
        self.updatedAt = updatedAt
    }

    var position: CGPoint {
        get { CGPoint(x: positionX, y: positionY) }
        set {
            positionX = Double(newValue.x)
            positionY = Double(newValue.y)
        }
    }
}

/// Pure store managing detached Pet companion records in UserDefaults (#342).
/// Reattaching or closing a detached Pet never deletes the underlying conversation or verified memory.
enum DetachedPetStore {
    static let storageKey = "dorax.apppet.detached_records.v1"

    static func loadRecords(defaults: UserDefaults = .standard) -> [DetachedPetRecord] {
        guard let data = defaults.data(forKey: storageKey),
            let records = try? JSONDecoder().decode([DetachedPetRecord].self, from: data)
        else {
            return []
        }
        return records
    }

    static func saveRecords(_ records: [DetachedPetRecord], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func record(for petID: AppPetID, defaults: UserDefaults = .standard) -> DetachedPetRecord? {
        let key = petID.canonicalKey
        return loadRecords(defaults: defaults).first { $0.petID.canonicalKey == key }
    }

    @discardableResult
    static func upsertRecord(_ record: DetachedPetRecord, defaults: UserDefaults = .standard) -> [DetachedPetRecord] {
        var records = loadRecords(defaults: defaults)
        let key = record.petID.canonicalKey
        if let idx = records.firstIndex(where: { $0.petID.canonicalKey == key }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        saveRecords(records, defaults: defaults)
        return records
    }

    @discardableResult
    static func removeRecord(for petID: AppPetID, defaults: UserDefaults = .standard) -> [DetachedPetRecord] {
        var records = loadRecords(defaults: defaults)
        let key = petID.canonicalKey
        records.removeAll { $0.petID.canonicalKey == key }
        saveRecords(records, defaults: defaults)
        return records
    }

    /// Pure transition helper: Mascot click/double-click jumps straight to Tier 3 (Expanded Window).
    static func transitionOnMascotClick(from current: AppPetPresentationTier) -> AppPetPresentationTier {
        .tier3Expanded
    }

    /// Pure transition helper: '^' chevron opens Tier 2 (Compact Launcher).
    static func transitionOnLauncherChevron(from current: AppPetPresentationTier) -> AppPetPresentationTier {
        .tier2Launcher
    }

    /// Pure transition helper: micro-bar ✏️ expands into inline input.
    static func transitionOnMicroBarEdit(from current: AppPetMicroBarState) -> AppPetMicroBarState {
        switch current {
        case .micro: return .inlineInput
        case .inlineInput: return .micro
        }
    }
}
