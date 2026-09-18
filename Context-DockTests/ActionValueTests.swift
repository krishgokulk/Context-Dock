import Testing
import Foundation
@testable import Context_Dock

// MARK: - The number in the sentence
//
// A1 of docs/superpowers/plans/2026-09-18-actions-that-adjust.md.
//
// An authored action saved as "minimise after 5 min" carried `sleep 300` baked in. The next
// request, "minimise after 10 min", could only match by triggers and sleep 300, or author a
// second action. Neither is what the owner asked for: the saved action should run with the
// new value and no model in the loop.
//
// This is the pure half: given a sentence and what the action's value means, find the number
// and put it in the action's unit.

struct ActionValueTests {

    // MARK: - The owner's sentences

    @Test func minutesBecomeSecondsForASecondsAction() {
        #expect(ActionValue.extract(from: "minimise after 10 min", label: "seconds") == "600")
        #expect(ActionValue.extract(from: "minimise after 5 minutes", label: "seconds") == "300")
    }

    @Test func hoursBecomeSecondsToo() {
        #expect(ActionValue.extract(from: "lock the screen in 2 hours", label: "seconds") == "7200")
        #expect(ActionValue.extract(from: "in 1 hr", label: "seconds") == "3600")
    }

    /// People say "five minutes" as often as "5 min".
    @Test func wordNumbersCount() {
        #expect(ActionValue.extract(from: "minimise after five minutes", label: "seconds") == "300")
        #expect(ActionValue.extract(from: "set brightness to twenty percent", label: "percent") == "20")
    }

    // MARK: - Other units

    @Test func percentIsPercent() {
        #expect(ActionValue.extract(from: "set volume to 50%", label: "percent") == "50")
        #expect(ActionValue.extract(from: "make it 50 percent", label: "percent") == "50")
    }

    /// A seconds action given seconds needs no conversion.
    @Test func secondsStaySeconds() {
        #expect(ActionValue.extract(from: "wait 45 seconds", label: "seconds") == "45")
        #expect(ActionValue.extract(from: "wait 45 sec", label: "seconds") == "45")
    }

    /// A unit the extractor does not know is not a reason to invent a number: the value is
    /// passed through as typed and the script decides.
    @Test func anUnknownUnitPassesTheNumberThrough() {
        #expect(ActionValue.extract(from: "resize to 1280 px", label: "pixels") == "1280")
    }

    /// A bare number is taken at face value in the action's own unit.
    @Test func aBareNumberIsInTheActionsUnit() {
        #expect(ActionValue.extract(from: "minimise after 90", label: "seconds") == "90")
    }

    // MARK: - Nothing there

    /// "minimise now" names no value. Nil lets the caller fall back to the default rather
    /// than run with an invented one.
    @Test func noNumberMeansNoValue() {
        #expect(ActionValue.extract(from: "minimise now", label: "seconds") == nil)
        #expect(ActionValue.extract(from: "", label: "seconds") == nil)
    }

    /// Decimals survive: "1.5 hours" is 5400 seconds, and the result is a whole number where
    /// the unit is whole.
    @Test func decimalsAreHonoured() {
        #expect(ActionValue.extract(from: "in 1.5 hours", label: "seconds") == "5400")
        #expect(ActionValue.extract(from: "in 2.5 min", label: "seconds") == "150")
    }

    /// The first quantity is the one meant. "minimise after 10 min, check every 30 sec" is
    /// about ten minutes.
    @Test func theFirstQuantityWins() {
        #expect(ActionValue.extract(from: "after 10 min, check every 30 sec", label: "seconds") == "600")
    }

    // MARK: - Filling the script (A3)

    /// `{{value}}` is filled the way `{{query}}` is: every occurrence, as text.
    @Test func theScriptGetsTheValue() {
        #expect(ActionValue.fill("sleep {{value}}; echo {{value}}", with: "600") == "sleep 600; echo 600")
    }

    /// No value means an empty slot, not a literal `{{value}}` reaching the shell. Matches
    /// what `{{query}}` does with an empty query.
    @Test func noValueLeavesTheSlotEmpty() {
        #expect(ActionValue.fill("sleep {{value}}", with: nil) == "sleep ")
    }

    /// A script with no slot is untouched, value or not.
    @Test func aScriptWithoutASlotIsUntouched() {
        #expect(ActionValue.fill("say hi", with: "600") == "say hi")
    }
}
