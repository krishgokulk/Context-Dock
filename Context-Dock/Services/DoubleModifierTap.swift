import AppKit

/// Recognizes two short, isolated presses. A shortcut chord or hold cancels the gesture.
struct DoubleModifierTap {
    private var downAt: TimeInterval?
    private var releasedAt: TimeInterval?
    private var contaminated = false

    mutating func cancel() {
        contaminated = true
        releasedAt = nil
    }

    /// The longest gap between the two releases: the Mac's own double-click speed (System
    /// Settings › Mouse), held to 0.3–0.6 s. A fixed 0.4 s missed a relaxed double press
    /// (owner 2026-10-18: "sometimes it doesn't work").
    var pairWindow: TimeInterval = min(max(NSEvent.doubleClickInterval, 0.3), 0.6)

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
        guard !contaminated, time - started < 0.45 else {
            releasedAt = nil
            return false
        }
        defer { contaminated = false }
        if let previous = releasedAt, time - previous > 0.04, time - previous < pairWindow {
            releasedAt = nil
            return true
        }
        releasedAt = time
        return false
    }
}
