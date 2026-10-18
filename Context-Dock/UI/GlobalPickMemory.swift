// GlobalPickMemory.swift
// Context-Dock
//
// S5 of the smarter-search plan (owner 2026-10-18): what was typed and which row was taken,
// so the same words — or the start of them — lead with that row next time, as Raycast and
// Spotlight learn. Kept on this Mac only, in Application Support, and bounded.

import Foundation

@MainActor
final class GlobalPickMemory {
    static let shared = GlobalPickMemory(
        file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock/global-picks.json"))

    struct Pick: Codable, Equatable {
        var count: Int
        var last: Date
    }

    /// Typed words → row → how often and when it was taken.
    private(set) var picks: [String: [String: Pick]] = [:]
    private let file: URL?
    /// The most typed queries kept; the oldest go first.
    static let capacity = 400
    /// A pick counts half as much after this long untouched.
    static let halfLife: TimeInterval = 14 * 86_400

    /// `file` nil keeps it in memory, for tests.
    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
            let saved = try? JSONDecoder().decode([String: [String: Pick]].self, from: data) {
            picks = saved
        }
    }

    /// The keys a query is remembered under: the whole of it and each start of it from three
    /// letters, so "saf" learns what "safari history" took.
    static func queryKeys(_ query: String) -> [String] {
        let whole = GlobalQuery.words(query).joined(separator: " ")
        guard whole.count >= 2 else { return [] }
        let starts = (3..<max(3, whole.count)).map { String(whole.prefix($0)) }
            .filter { !$0.hasSuffix(" ") }
        return [whole] + starts
    }

    /// A row as it is remembered: its app and its own id, so Safari's and Chrome's "New
    /// Window" are not one row.
    static func rowKey(_ row: AppChatRow) -> String {
        "\(GlobalResultSection.appName(of: row))|\(row.id)"
    }

    /// Rows that are controls, not answers — Show more, the fallbacks, a day of history
    /// that fills the field — are never learned.
    static func isLearnable(_ row: AppChatRow) -> Bool {
        guard case .dock(let pill) = row else { return true }
        return ![
            GlobalResultSection.showMoreKind, GlobalFallbacks.askKind, GlobalFallbacks.webKind,
            GlobalFallbacks.terminalKind, GlobalQuery.historyDayKind,
        ].contains(pill.rankingKind)
    }

    func record(query: String, row: AppChatRow, now: Date = Date()) {
        guard Self.isLearnable(row) else { return }
        let key = Self.rowKey(row)
        for queryKey in Self.queryKeys(query) {
            var pick = picks[queryKey]?[key] ?? Pick(count: 0, last: now)
            pick.count += 1
            pick.last = now
            picks[queryKey, default: [:]][key] = pick
        }
        if picks.count > Self.capacity {
            let newest = picks.sorted {
                ($0.value.values.map(\.last).max() ?? .distantPast)
                    > ($1.value.values.map(\.last).max() ?? .distantPast)
            }
            picks = Dictionary(uniqueKeysWithValues: newest.prefix(Self.capacity).map { ($0.key, $0.value) })
        }
        save()
    }

    /// The row these words were answered with before, among the rows offered now — the most
    /// taken, recent picks counting more. Never a destructive row whose verb was not typed.
    func favourite(in rows: [AppChatRow], query: String, now: Date = Date()) -> AppChatRow? {
        guard let whole = Self.queryKeys(query).first, let taken = picks[whole] else { return nil }
        let typed = Set(GlobalQuery.words(query))
        func score(_ pick: Pick) -> Double {
            Double(pick.count) * pow(0.5, now.timeIntervalSince(pick.last) / Self.halfLife)
        }
        return rows
            .compactMap { row -> (AppChatRow, Double)? in
                guard let pick = taken[Self.rowKey(row)] else { return nil }
                if let verb = GlobalQuery.destructiveVerb(of: row), !typed.contains(verb) { return nil }
                return (row, score(pick))
            }
            .max { $0.1 < $1.1 }?.0
    }

    private func save() {
        guard let file else { return }
        let snapshot = picks
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
