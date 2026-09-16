import Testing
import Foundation
@testable import Context_Dock

// MARK: - An instruction answered with a reading
//
// The audit line that started this:
//
//   generalAI.execute.globalcmd.appearance | ok=true | "Appearance current value: true"
//
// A Global Command that exists to change something reported the switch's position
// instead of moving it. The rule that produced it is unconditional:
//
//   // An omitted value on an interactive command means "read it", not "run a
//   // mutation with an empty argument".
//   if normalized.isEmpty, command.interactionType != .none { …return current value… }
//
// True of a question. False of an instruction — and the executor could not tell them
// apart, because AICapabilityExecutionRequest carries inputs and context and never
// intent. Same blindness as §9c, one layer down.
//
// Reading stays the default: it is the safe answer, and a reading never breaks anything.
// What must not happen is an explicit "turn on dark mode" coming back as "current
// value: true".

@MainActor
struct InteractiveCommandIntentTests {

    // MARK: - Reading is still the default

    /// A question gets the value. This is the behaviour worth keeping.
    @Test func aQuestionIsAnsweredWithTheValue() {
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "is dark mode on?", isToggle: true, current: "true")
            == .readCurrentValue)
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "what's my volume", isToggle: false, current: "40")
            == .readCurrentValue)
    }

    /// An empty request means an older caller that never passed one. Read — never guess a
    /// mutation from an absence.
    @Test func noStatedIntentReadsRatherThanActs() {
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "", isToggle: true, current: "true")
            == .readCurrentValue)
    }

    /// Nothing to read means nothing to report; let the command run as it always did.
    @Test func withNoReadableValueTheCommandJustRuns() {
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "toggle dark mode", isToggle: true, current: nil)
            == .runAsIs)
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "toggle dark mode", isToggle: true, current: "  ")
            == .runAsIs)
    }

    // MARK: - An instruction is carried out

    /// The one from the audit log. "Turn on" names the state it wants; DoraX must set it,
    /// not report it — and must not flip an already-on switch off in the process.
    @Test func turnOnSetsOnEvenWhenAlreadyOn() {
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "turn on dark mode", isToggle: true, current: "true")
            == .set("on"))
    }

    @Test func turnOffSetsOff() {
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "turn off bluetooth", isToggle: true, current: "on")
            == .set("off"))
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "disable dark mode", isToggle: true, current: "true")
            == .set("off"))
    }

    @Test func enableIsOn() {
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "enable night shift", isToggle: true, current: "false")
            == .set("on"))
    }

    /// "Toggle" and "switch" name no state, so the only sensible reading is the opposite
    /// of where it is now.
    @Test func toggleWithoutAStateFlipsIt() {
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "toggle dark mode", isToggle: true, current: "true")
            == .set("off"))
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "switch dark mode", isToggle: true, current: "false")
            == .set("on"))
    }

    /// A non-toggle asked to change with no value has nothing to flip — run it, and let
    /// the command's own value guard complain if it needed one.
    @Test func nonTogglesRunRatherThanFlip() {
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "turn up the volume", isToggle: false, current: "40")
            == .runAsIs)
    }

    /// "change" is deliberately not a change verb in the shared vocabulary, and this is
    /// the reason: "what changed in this file?" is a question, and treating it as an
    /// instruction would hand the write-intent guard a licence it must not have. A
    /// request DoraX cannot read as an instruction gets the safe answer — the value.
    @Test func anAmbiguousVerbFallsBackToReading() {
        #expect(InteractiveCommandIntent.fallback(
            userRequest: "change my volume", isToggle: false, current: "40")
            == .readCurrentValue)
    }

    // MARK: - Reading the current state

    /// System commands report their state in whatever vocabulary their script uses.
    @Test func everyShapeOfOnIsUnderstood() {
        for on in ["true", "1", "on", "yes", "TRUE", " On "] {
            #expect(InteractiveCommandIntent.isOn(on), "expected \(on) to read as on")
        }
        for off in ["false", "0", "off", "no", "FALSE", " Off "] {
            #expect(!InteractiveCommandIntent.isOn(off), "expected \(off) to read as off")
        }
    }
}
