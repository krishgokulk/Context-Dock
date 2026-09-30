import Foundation

/// Whether a value the Mac reports after a write says what was asked.
///
/// One function per value type, so each rule is testable on its own. Free text is never
/// compared: with nothing to compare against, the outcome is `.notComparable` and the
/// reading stands as shown.
nonisolated enum ReadBackComparison {
    enum Outcome: Equatable, Sendable {
        case matches
        case differs
        case notComparable
    }

    /// A slider reads back within one step of what was set: the Mac rounds 30 to 31 as
    /// readily as not.
    static let numberTolerance = 1.0

    private static let on: Set<String> = ["on", "true", "yes", "1", "enabled", "dark"]
    private static let off: Set<String> = ["off", "false", "no", "0", "disabled", "light"]

    static func number(
        requested: String, readBack: String, tolerance: Double = numberTolerance
    ) -> Outcome {
        guard let a = Double(clean(requested)), let b = Double(clean(readBack)) else {
            return .notComparable
        }
        return abs(a - b) <= tolerance ? .matches : .differs
    }

    /// On/off in any of the words a setting uses ("dark" and "true" are both on).
    static func toggle(requested: String, readBack: String) -> Outcome {
        let want = clean(requested)
        let got = clean(readBack)
        let wantOn = on.contains(want)
        guard wantOn || off.contains(want), on.contains(got) || off.contains(got) else {
            return .notComparable
        }
        return wantOn == on.contains(got) ? .matches : .differs
    }

    /// One of a known set of values. Anything outside the set is not compared.
    static func enumeration(
        requested: String, readBack: String, allowed: Set<String>
    ) -> Outcome {
        let options = Set(allowed.map(clean))
        let want = clean(requested)
        let got = clean(readBack)
        guard options.contains(want), options.contains(got) else { return .notComparable }
        return want == got ? .matches : .differs
    }

    /// The comparison for a requested value and its reading, by the type they show.
    static func compare(requested: String, readBack: String) -> Outcome {
        if clean(requested) == clean(readBack) { return .matches }
        // 1 and 0 are on and off, not two numbers one step apart.
        let bits: Set<String> = ["0", "1"]
        if bits.contains(clean(requested)), bits.contains(clean(readBack)) {
            return toggle(requested: requested, readBack: readBack)
        }
        let asNumber = number(requested: requested, readBack: readBack)
        if asNumber != .notComparable { return asNumber }
        return toggle(requested: requested, readBack: readBack)
    }

    /// The result of waiting for a reading to settle.
    struct Settled: Equatable, Sendable {
        var outcome: Outcome
        /// The last reading taken.
        var reading: String
    }

    /// Only a settled disagreement is a failure. Bluetooth, Wi-Fi and dark mode apply a
    /// moment after the script exits, so a differing first reading is re-read (up to
    /// `attempts` times, `delay` apart) until it matches, cannot be compared, or the
    /// attempts run out. Cancellation stops the wait and is never a failure.
    static func settle(
        requested: String,
        first: String,
        attempts: Int = 4,
        delay: Duration = .milliseconds(300),
        reread: () async -> String?
    ) async -> Settled {
        var reading = first
        var outcome = compare(requested: requested, readBack: reading)
        var remaining = attempts
        while outcome == .differs, remaining > 0 {
            remaining -= 1
            do { try await Task.sleep(for: delay) } catch {
                return Settled(outcome: .notComparable, reading: reading)
            }
            if Task.isCancelled { return Settled(outcome: .notComparable, reading: reading) }
            guard let next = await reread()?.trimmingCharacters(in: .whitespacesAndNewlines),
                !next.isEmpty
            else { continue }
            reading = next
            outcome = compare(requested: requested, readBack: reading)
        }
        return Settled(outcome: outcome, reading: reading)
    }

    /// What the model and the activity row are told when the reading disagrees.
    static func mismatchMessage(name: String, requested: String, readBack: String) -> String {
        "\(name) did not change as asked: asked for \(requested), the Mac reports "
            + "\(readBack). Do not tell the user it worked."
    }

    private static func clean(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
