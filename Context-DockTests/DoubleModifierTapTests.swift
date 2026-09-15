import Testing
@testable import Context_Dock

struct DoubleModifierTapTests {
    private func tap(_ detector: inout DoubleModifierTap, at time: Double, duration: Double = 0.08) -> Bool {
        let pressed = detector.update(isDown: true, hasOtherModifiers: false, time: time)
        #expect(!pressed)
        return detector.update(isDown: false, hasOtherModifiers: false, time: time + duration)
    }

    @Test func twoShortPressesFireOnce() {
        var detector = DoubleModifierTap()
        #expect(!tap(&detector, at: 1))
        #expect(tap(&detector, at: 1.2))
        #expect(!tap(&detector, at: 1.4))
    }

    @Test func slowPressesAndHoldsDoNotLaunch() {
        var detector = DoubleModifierTap()
        #expect(!tap(&detector, at: 1))
        #expect(!tap(&detector, at: 2))
        #expect(!tap(&detector, at: 2.2, duration: 0.5))
        #expect(!tap(&detector, at: 2.8))
    }

    @Test func copyAndCommandTabCancelThePair() {
        var detector = DoubleModifierTap()
        #expect(!tap(&detector, at: 1))
        let pressed = detector.update(isDown: true, hasOtherModifiers: false, time: 1.2)
        #expect(!pressed)
        detector.cancel() // keyDown for C, Tab, V, etc.
        let released = detector.update(isDown: false, hasOtherModifiers: false, time: 1.3)
        #expect(!released)
        #expect(!tap(&detector, at: 1.4))
    }

    @Test func mixedModifiersCancelEvenWhenReleasedFirst() {
        var detector = DoubleModifierTap()
        #expect(!tap(&detector, at: 1))
        let pressed = detector.update(isDown: true, hasOtherModifiers: false, time: 1.2)
        let chord = detector.update(isDown: true, hasOtherModifiers: true, time: 1.22)
        let chordReleased = detector.update(isDown: true, hasOtherModifiers: false, time: 1.24)
        let released = detector.update(isDown: false, hasOtherModifiers: false, time: 1.28)
        #expect(!pressed && !chord && !chordReleased && !released)
        #expect(!tap(&detector, at: 1.4))
    }
}
