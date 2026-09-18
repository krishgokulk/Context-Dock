// ActionValue.swift
// Context-Dock
//
// The number in the sentence, in the unit the action wants.
//
// A1 of docs/superpowers/plans/2026-09-18-actions-that-adjust.md. An authored action saved
// as "minimise after 5 min" carried `sleep 300` baked in, so "minimise after 10 min" could
// only sleep 300 or author a second action. The saved action should run with the new value
// and no model in the loop; this is the half that finds the value.
//
// Deliberately small. Seconds, minutes, hours, percent, and a bare count are the units an
// authored action has actually needed. Anything else is passed through as typed — inventing
// a conversion is worse than letting the script see what the user said.

import Foundation

enum ActionValue {

    /// The first quantity in `sentence`, expressed in `label`'s unit, or nil when the
    /// sentence names none. Nil is meaningful: the caller falls back to the action's default
    /// rather than to a number nobody said.
    static func extract(from sentence: String, label: String) -> String? {
        let lowered = sentence.lowercased()
        guard let (amount, unit) = firstQuantity(in: lowered) else { return nil }

        let target = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let converted: Double
        switch (target, unit) {
        case ("seconds", .minutes), ("second", .minutes), ("sec", .minutes), ("s", .minutes):
            converted = amount * 60
        case ("seconds", .hours), ("second", .hours), ("sec", .hours), ("s", .hours):
            converted = amount * 3600
        case ("minutes", .hours), ("minute", .hours), ("min", .hours):
            converted = amount * 60
        case ("minutes", .seconds), ("minute", .seconds), ("min", .seconds):
            converted = amount / 60
        default:
            // Same unit, a bare number, a percent, or a unit this does not know: the
            // number as said.
            converted = amount
        }
        return format(converted)
    }

    /// `{{value}}` filled the way `{{query}}` is: every occurrence, as text. No value is an
    /// empty slot — a literal `{{value}}` must never reach a shell.
    static func fill(_ text: String, with value: String?) -> String {
        text.replacingOccurrences(of: "{{value}}", with: value ?? "")
    }

    /// Whether the sentence names a number at all. `nil` from `extract` is ambiguous —
    /// "no number said" and "an action with no unit to convert to" both produce it — and
    /// the reuse decision needs to tell those apart.
    static func namesAQuantity(in sentence: String) -> Bool {
        firstQuantity(in: sentence.lowercased()) != nil
    }

    /// Whether a word is part of saying a quantity: a number, a word-number, or a unit.
    /// Used to ask what a sentence says *besides* its value.
    static func isValueToken(_ token: String) -> Bool {
        var t = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if t.hasSuffix("%") { t.removeLast() }
        if t.isEmpty { return false }
        if Double(t) != nil { return true }
        if wordNumbers[t] != nil { return true }
        return unitWords.contains { $0.0 == t }
    }

    // MARK: - Reading the sentence

    private enum Unit { case seconds, minutes, hours, percent, none }

    private static let unitWords: [(String, Unit)] = [
        ("hours", .hours), ("hour", .hours), ("hrs", .hours), ("hr", .hours), ("h", .hours),
        ("minutes", .minutes), ("minute", .minutes), ("mins", .minutes), ("min", .minutes),
        ("m", .minutes),
        ("seconds", .seconds), ("second", .seconds), ("secs", .seconds), ("sec", .seconds),
        ("s", .seconds),
        ("percent", .percent), ("%", .percent),
    ]

    private static let wordNumbers: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100,
    ]

    /// The first number — digits or a word — and whatever unit follows it. "50%" is one
    /// token with the unit attached; "10 min" is two.
    private static func firstQuantity(in text: String) -> (Double, Unit)? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)

        for (index, raw) in tokens.enumerated() {
            var token = raw
            var attached: Unit = .none
            if token.hasSuffix("%") {
                token.removeLast()
                attached = .percent
            }
            let amount: Double?
            if let number = Double(token) {
                amount = number
            } else if let word = wordNumbers[token] {
                amount = word
            } else {
                amount = nil
            }
            guard let amount else { continue }

            if attached != .none { return (amount, attached) }
            let next = index + 1 < tokens.count
                ? tokens[index + 1].trimmingCharacters(in: .punctuationCharacters) : ""
            let unit = unitWords.first { $0.0 == next }?.1 ?? .none
            return (amount, unit)
        }
        return nil
    }

    /// Whole where whole, otherwise as short as it can be: 600, not 600.0; 2.5, not 2.50.
    private static func format(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(value).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
    }
}
