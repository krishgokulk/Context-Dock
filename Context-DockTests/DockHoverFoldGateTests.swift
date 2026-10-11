import Foundation
import Testing

@testable import Context_Dock

/// Typing from the resting bar opens the field, and the bar's icons gather into the field's
/// pill — under a pointer that has not moved. That arriving pill is not the pointer asking
/// for the big bar, and folding on it collapsed the field while the user typed (owner
/// 2026-09-27).
@Suite("Dock hover-fold gate")
struct DockHoverFoldGateTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aSettledIdleFieldFoldsOnHover() {
        #expect(
            DockHoverFoldGate.allows(
                now: now, openedAt: now.addingTimeInterval(-5),
                typedAt: now.addingTimeInterval(-5), textPending: false))
    }

    @Test func notWhileTheFieldIsStillOpening() {
        #expect(
            !DockHoverFoldGate.allows(
                now: now, openedAt: now.addingTimeInterval(-0.3), typedAt: nil,
                textPending: false))
    }

    @Test func notRightAfterAKeystroke() {
        #expect(
            !DockHoverFoldGate.allows(
                now: now, openedAt: nil, typedAt: now.addingTimeInterval(-0.4),
                textPending: false))
    }

    /// A typed letter still on its way into the field: the field looks empty, and is not.
    @Test func notWhileTypedTextIsWaitingForTheField() {
        #expect(
            !DockHoverFoldGate.allows(
                now: now, openedAt: nil, typedAt: nil, textPending: true))
    }
}
