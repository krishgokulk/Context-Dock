// MessagesReadQuality.swift
// Context-Dock
//
// Telling a read that failed from a read that found nothing.
//
// The Messages AppleScript dictionary is restricted on modern macOS: it still answers, and
// what it answers with is the literal string "missing value" where the contact name and the
// message body should be. So the read succeeds, returns rows, and carries no information —
// the worst of the three possible outcomes, because empty is obviously broken and garbage
// looks like data.
//
// It reached the user as "the only clear contact was Tokers, the rest came back as missing
// value": AppleScript's null, quoted back at them as though it were a finding.

import Foundation

enum MessagesReadQuality {

    /// True when a snapshot is mostly AppleScript's way of saying it cannot read this.
    ///
    /// Proportional rather than absolute: one unnamed group chat among ten is ordinary, and
    /// ten among ten means the dictionary is restricted and the whole read is worthless.
    static func isDegraded(_ snapshot: String) -> Bool {
        let text = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        let lines = text.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return true }
        let blank = lines.filter { $0.lowercased().contains("missing value") }.count
        return Double(blank) / Double(lines.count) > 0.4
    }
}
