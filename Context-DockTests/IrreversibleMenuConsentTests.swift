import Foundation
import Testing

@testable import Context_Dock

// The menu route's own approval, and the word list it rests on.
//
// A menu click is gated by exactly one thing: `AppMenuConsentStore.isDestructive(path:)`.
// When it returns false, `AppAdapterManager.ensureMenuConsent` returns true without asking
// anybody, and `AppAccessPolicy` permits `.verifiedMenu` even at `.menuOnly` — the lowest
// access level a user can grant an app — on the reasoning that a menu command is public and
// observable.
//
// That reasoning holds for Minimize. It does not hold for Send. Observable is not reversible,
// and the list was written from the vocabulary of deleting things, so every word in it is
// about destroying local state and none is about putting something in front of another
// person. Mail registers no send *capability*, so the registry gate that covers
// reminders.delete never runs here: the only thing between a model and a sent email is this
// list.

@MainActor
struct IrreversibleMenuConsentTests {

    private let store = AppMenuConsentStore.shared

    /// Sending, replying, forwarding and sharing are irreversible in the way that matters:
    /// they involve somebody else, and no undo exists once they land.
    @Test func puttingSomethingInFrontOfAnotherPersonIsGated() {
        let paths: [[String]] = [
            ["Message", "Send"],
            ["Message", "Reply"],
            ["Message", "Reply All"],
            ["Message", "Forward"],
            ["File", "Share"],
        ]
        for path in paths {
            #expect(
                store.isDestructive(path: path),
                "\(path.joined(separator: " ▸ ")) would run with nobody asked")
        }
    }

    /// The list this replaces. Local destruction must stay gated — widening the list for
    /// outbound actions must not drop anything it already caught.
    @Test func destroyingLocalStateIsStillGated() {
        let paths: [[String]] = [
            ["File", "Close"],
            ["Mail", "Quit Mail"],
            ["Edit", "Delete"],
            ["File", "Move to Trash"],
            ["Mailbox", "Erase Deleted Items"],
        ]
        for path in paths {
            #expect(store.isDestructive(path: path), "\(path.joined(separator: " ▸ ")) is not gated")
        }
    }

    /// The counterweight. Gating everything is the same failure as gating nothing: a prompt in
    /// front of Minimize trains people to approve without reading, which is what makes the
    /// prompt in front of Send worthless.
    @Test func ordinaryMenuCommandsStayUngated() {
        let paths: [[String]] = [
            ["Window", "Minimize"],
            ["Window", "Zoom"],
            ["View", "Show Toolbar"],
            ["Mailbox", "Get All New Mail"],
            ["File", "New Message"],
        ]
        for path in paths {
            #expect(
                !store.isDestructive(path: path),
                "\(path.joined(separator: " ▸ ")) is harmless but would prompt")
        }
    }

    /// Destructive words count only as whole words. The list used to be a substring check,
    /// so "Closed" read as "Close": reopening a window prompted like closing one.
    @Test func destructiveWordsMatchWholeWordsOnly() {
        let gated: [[String]] = [
            ["File", "Close Tab"],
            ["File", "Close…"],
            ["Apple", "Log Out Gokula…"],
            ["Account", "Sign Out"],
        ]
        for path in gated {
            #expect(store.isDestructive(path: path), "\(path.joined(separator: " ▸ ")) is not gated")
        }
        let ungated: [[String]] = [
            ["History", "Reopen Last Closed Window"],
            ["History", "Reopen Last Closed Tab"],
            ["History", "Recently Closed", "Apple"],
            ["View", "Show Deleted Items"],
        ]
        for path in ungated {
            #expect(
                !store.isDestructive(path: path),
                "\(path.joined(separator: " ▸ ")) is harmless but would prompt")
        }
    }

    /// A word that is neither an exact destructive word nor its plain past form ("Closed",
    /// "Deleted") is not something the list can call safe, so it stays gated.
    @Test func anUnsureFormOfADestructiveWordStaysGated() {
        let paths: [[String]] = [
            ["File", "Closing Tabs"],
            ["Edit", "Resetting Defaults"],
            ["File", "Deletes Selection"],
        ]
        for path in paths {
            #expect(store.isDestructive(path: path), "\(path.joined(separator: " ▸ ")) is not gated")
        }
    }

    /// "Forward" in a browser's History menu (or Finder's Go menu) moves through pages; it
    /// sends nothing. Anywhere else, or with no menu to say which it is, it stays outbound.
    @Test func historyForwardIsNavigationNotSending() {
        #expect(!store.isDestructive(path: ["History", "Forward"]))
        #expect(!store.isDestructive(path: ["Go", "Forward"]))
        #expect(store.isDestructive(path: ["Message", "Forward"]))
        #expect(store.isDestructive(path: ["Forward"]))
        #expect(store.isDestructive(path: ["History", "Forward", "Page"]))
        #expect(store.isDestructive(path: ["History", "Share"]))
    }

    /// Results drop a menu route that destroys something unless the request asked for that.
    /// "Recently Closed" read as "close", so reopening a closed page never showed up.
    @Test func recentlyClosedPagesShowInResults() {
        let route = ChatRoute(
            id: "menu:safari:recently-closed", kind: .menuCommand, title: "Apple",
            payload: "History > Recently Closed > Apple",
            appName: "Safari", bundleId: "com.apple.Safari", isReadOnly: false)
        #expect(ActionReadiness.isOfferable(route, query: "reopen the apple page"))

        let close = ChatRoute(
            id: "menu:safari:close-tab", kind: .menuCommand, title: "Close Tab",
            payload: "File > Close Tab",
            appName: "Safari", bundleId: "com.apple.Safari", isReadOnly: false)
        #expect(!ActionReadiness.isOfferable(close, query: "show me the apple page"))
    }
}
