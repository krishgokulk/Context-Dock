import Foundation

/// Recognizes two short, isolated presses. A shortcut chord or hold cancels the gesture.
struct DoubleModifierTap {
    private var downAt: TimeInterval?
    private var releasedAt: TimeInterval?
    private var contaminated = false

    mutating func cancel() {
        contaminated = true
        releasedAt = nil
    }

    mutating func update(isDown: Bool, hasOtherModifiers: Bool, time: TimeInterval) -> Bool {
        if hasOtherModifiers { cancel() }
        if isDown {
            if downAt == nil {
                downAt = time
                contaminated = hasOtherModifiers
            }
            return false
        }
        guard let started = downAt else { return false }
        downAt = nil
        guard !contaminated, time - started < 0.35 else {
            releasedAt = nil
            return false
        }
        defer { contaminated = false }
        if let previous = releasedAt, time - previous > 0.04, time - previous < 0.40 {
            releasedAt = nil
            return true
        }
        releasedAt = time
        return false
    }
}
