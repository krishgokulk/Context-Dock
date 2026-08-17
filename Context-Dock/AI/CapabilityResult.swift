// CapabilityResult.swift
// Context-Dock
//
// What a capability produced, as data the app can draw — not only prose for the model
// to relay.
//
// "Find duplicate files" already knew the groups, the copies and the bytes each one
// would reclaim. All of that was flattened into markdown, handed to the model, and read
// back to the user as a wall of paths they then had to act on by hand. The answer was
// right and the surface was a chat log.
//
// A capability now returns rows alongside its text. The model still gets the prose — it
// has to reason about the result — and the surface gets something it can render as
// cards with actions, so the file the user wants to open is one click away rather than
// a path they have to copy.

import AppKit
import Combine
import Foundation

/// One thing a capability found: a duplicate set, a large folder, a match.
struct CapabilityResultRow: Identifiable, Hashable {
    let id: String
    /// What it is — a filename, a folder, a group.
    let title: String
    /// Where it is, or what it consists of.
    let subtitle: String?
    /// The number that matters: a size, a count, a percentage.
    let detail: String?
    /// Files this row stands for. Drives Reveal, preview, and any bulk action.
    let paths: [URL]
    /// Proportion of the whole, when the rows share a total. Draws the bar.
    let fraction: Double?

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        paths: [URL] = [],
        fraction: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.paths = paths
        self.fraction = fraction
    }
}

struct CapabilityResultTable: Identifiable, Hashable {
    let id: UUID
    /// Which capability produced this, so a stale table is never drawn under a new answer.
    let capabilityID: String
    let title: String
    let rows: [CapabilityResultRow]
    /// The bottom line: "11.9 MB reclaimable", "203.7 MB total".
    let summary: String?

    init(
        capabilityID: String,
        title: String,
        rows: [CapabilityResultRow],
        summary: String? = nil
    ) {
        self.id = UUID()
        self.capabilityID = capabilityID
        self.title = title
        self.rows = rows
        self.summary = summary
    }
}

/// Where a capability leaves its rows for whichever surface asked.
///
/// The tool loop returns a string; there is nowhere in that contract to carry a table.
/// Rather than widen every layer between the capability and the view, the capability
/// publishes here and the surface reads what was produced during its own turn — cleared
/// when the turn starts, so an old table never appears under a new answer.
@MainActor
final class CapabilityResultStore: ObservableObject {
    static let shared = CapabilityResultStore()
    private init() {}

    @Published private(set) var tables: [CapabilityResultTable] = []

    func beginTurn() {
        tables = []
    }

    func publish(_ table: CapabilityResultTable) {
        guard !table.rows.isEmpty else { return }
        tables.append(table)
    }
}
