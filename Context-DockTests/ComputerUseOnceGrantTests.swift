import Foundation
import Testing

@testable import Context_Dock

/// "Allow once" is a different decision from "allow always".
///
/// The store could only express the second: `grantFromChat` persists `askEachStep`, which is a
/// standing grant with a prompt attached. Being asked each time does not make a grant
/// temporary, and somebody who wanted one button pressed should not find out later that the
/// app is permanently operable.
@MainActor
@Suite(.serialized)
struct ComputerUseOnceGrantTests {
    private let bundleID = "com.example.oncegrant"

    private func store() -> ComputerUseConsentStore {
        let store = ComputerUseConsentStore.shared
        store.setMode(.off, for: bundleID)
        _ = store.consumeOneShotGrant(for: bundleID)  // clear any leftover
        return store
    }

    @Test func aSinglePressIsSpentWhenItIsUsed() {
        let store = store()
        store.grantOnce(for: bundleID)

        #expect(store.consumeOneShotGrant(for: bundleID))
        #expect(store.consumeOneShotGrant(for: bundleID) == false)
    }

    /// The part that makes it "once" rather than "always": it leaves no standing grant behind.
    @Test func itGrantsNothingStanding() {
        let store = store()
        store.grantOnce(for: bundleID)

        #expect(store.mode(for: bundleID) == .off)
        #expect(store.grantedBundleIDs().contains(bundleID) == false)
    }

    /// And it is not a decision about every app, so the master switch is untouched.
    @Test func itDoesNotTouchTheMasterSwitch() {
        let store = store()
        let before = store.isMasterEnabled
        store.grantOnce(for: bundleID)

        #expect(store.isMasterEnabled == before)
        _ = store.consumeOneShotGrant(for: bundleID)
    }

    /// Reading state must not spend it — a settings row that draws the badge would otherwise
    /// consume the press the user was about to get.
    @Test func lookingAtItDoesNotSpendIt() {
        let store = store()
        store.grantOnce(for: bundleID)

        #expect(store.hasOneShotGrant(for: bundleID))
        #expect(store.hasOneShotGrant(for: bundleID))
        #expect(store.consumeOneShotGrant(for: bundleID))
    }

    @Test func withoutOneThereIsNothingToSpend() {
        #expect(store().consumeOneShotGrant(for: bundleID) == false)
    }
}
