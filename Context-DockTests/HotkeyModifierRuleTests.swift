import Carbon.HIToolbox
import Testing
@testable import Context_Dock

/// A global hotkey is a chord, not a character. ⇧S recorded as Selection Scope made it
/// impossible to type a capital S anywhere on the Mac.
struct HotkeyModifierRuleTests {
    @Test func shiftAloneIsRejected() {
        #expect(!HotkeyModifierRule.accepts(carbonModifiers: UInt32(shiftKey)))
    }

    @Test func noModifierIsRejected() {
        #expect(!HotkeyModifierRule.accepts(carbonModifiers: 0))
    }

    @Test(arguments: [cmdKey, optionKey, controlKey])
    func eachRealModifierIsAccepted(modifier: Int) {
        #expect(HotkeyModifierRule.accepts(carbonModifiers: UInt32(modifier)))
    }

    @Test func shiftWithARealModifierIsAccepted() {
        #expect(HotkeyModifierRule.accepts(carbonModifiers: UInt32(shiftKey | controlKey)))
        #expect(HotkeyModifierRule.accepts(carbonModifiers: UInt32(shiftKey | cmdKey)))
    }
}
