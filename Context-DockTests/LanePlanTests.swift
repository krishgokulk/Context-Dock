import Foundation
import Testing

@testable import Context_Dock

// Plan §2a/§2b. The lane is decided from the request words at understanding; the plan then says
// what the one executor does to the app — start it hidden (data) or bring it forward and return
// focus (UI) — and the data lane never activates a menu click.

struct LanePlanTests {

    // MARK: - Lane decision for Messages and Terminal (§2b)

    @Test func messagesAndTerminalReadsAreDataLane() {
        for text in [
            "what did Salman text me today", "who do I message most",
            "how much disk space is free", "what's the error in my terminal",
        ] {
            #expect(RequestLane.decide(text) == .data, "\"\(text)\"")
        }
    }

    @Test func showAndNewTabAreUILane() {
        for text in ["show my chat with Salman is in a new tab", "open a new tab", "show sidebar"] {
            #expect(RequestLane.decide(text) == .ui, "\"\(text)\"")
        }
    }

    // MARK: - LanePlan: app-prep per lane and state

    @Test func dataReadStartsAClosedAppHidden() {
        let plan = LanePlan.decide(
            request: "find mail from SBI today", appName: "Mail",
            needsRunningApp: true, bringsAppForward: false,
            state: .init(isRunning: false, isFrontmost: false, previousFrontmostBundleID: "com.apple.Safari"))
        #expect(plan.lane == .data)
        #expect(plan.startsHidden)
        #expect(!plan.bringsForward)
        #expect(plan.returnsFocusTo == nil)
        #expect(plan.planCard == nil)
        #expect(plan.laneStep == "Lane: data")
    }

    @Test func dataReadLeavesARunningAppUntouched() {
        let plan = LanePlan.decide(
            request: "read my latest email", appName: "Mail",
            needsRunningApp: true, bringsAppForward: false,
            state: .init(isRunning: true, isFrontmost: false, previousFrontmostBundleID: "com.apple.Safari"))
        #expect(!plan.startsHidden)
        #expect(!plan.bringsForward)
    }

    @Test func uiMenuInBackgroundBringsForwardWithCardAndReturn() {
        let plan = LanePlan.decide(
            request: "show the mailbox list", appName: "Mail",
            needsRunningApp: false, bringsAppForward: true,
            state: .init(isRunning: true, isFrontmost: false, previousFrontmostBundleID: "com.apple.Safari"))
        #expect(plan.lane == .ui)
        #expect(plan.bringsForward)
        #expect(plan.returnsFocusTo == "com.apple.Safari")
        #expect(plan.planCard?.contains("Bring Mail forward") == true)
        #expect(plan.laneStep == "Lane: UI")
    }

    @Test func uiMenuAlreadyFrontMovesNothing() {
        let plan = LanePlan.decide(
            request: "minimize this window", appName: "Mail",
            needsRunningApp: false, bringsAppForward: true,
            state: .init(isRunning: true, isFrontmost: true, previousFrontmostBundleID: nil))
        #expect(plan.lane == .ui)
        #expect(!plan.bringsForward)
        #expect(plan.returnsFocusTo == nil)
        #expect(plan.planCard == nil)
    }

    @Test func uiWordsButNoWindowCapabilityNeverBringsForward() {
        // A request that reads as UI but whose capability needs no window (bringsAppForward
        // false) must not move the app — the capability gates the forward move.
        let plan = LanePlan.decide(
            request: "zoom in on the photo", appName: "Preview",
            needsRunningApp: true, bringsAppForward: false,
            state: .init(isRunning: false, isFrontmost: false, previousFrontmostBundleID: "com.apple.finder"))
        #expect(!plan.bringsForward)
        #expect(plan.startsHidden)  // data-style prep: hidden start, no focus change
    }

    // MARK: - The data→UI fall (§2a: no data rung fits → visible menu step)

    @Test func dataWordsOnAMenuRouteFallToAVisibleMenuStep() {
        // "Archive the newest email" reads data by its words, but the only route is the
        // Message ▸ Archive menu command. §2a names this exact case: the fall to the UI
        // lane is a VISIBLE step with a plan card — never a silent attempt to press menus
        // the user cannot see, and never a refusal because the app is closed.
        let plan = LanePlan.decide(
            request: "archive the newest email", appName: "Mail",
            needsRunningApp: false, bringsAppForward: true,
            state: .init(isRunning: true, isFrontmost: false, previousFrontmostBundleID: "com.apple.Safari"))
        #expect(plan.lane == .data, "the lane stays what the words decided; the card shows the fall")
        #expect(plan.bringsForward)
        #expect(plan.returnsFocusTo == "com.apple.Safari")
        #expect(plan.planCard?.contains("Bring Mail forward") == true)
    }

    @Test func dataMenuFallOnAClosedAppSaysItStarts() {
        // Mail not running, CLI unlinked: the plan's U1 row — "the app must start; the
        // plan card says it opens" — so the closed case names the START, not a shrug.
        let plan = LanePlan.decide(
            request: "archive the newest email", appName: "Mail",
            needsRunningApp: false, bringsAppForward: true,
            state: .init(isRunning: false, isFrontmost: false, previousFrontmostBundleID: "com.apple.Safari"))
        #expect(plan.bringsForward)
        #expect(!plan.startsHidden, "a menu fall starts visibly; hidden is the data rung's prep alone")
        #expect(plan.returnsFocusTo == "com.apple.Safari")
        #expect(plan.planCard?.contains("Start Mail") == true)
    }

    @Test func dataMenuFallLeavesAFrontmostAppAlone() {
        let plan = LanePlan.decide(
            request: "archive the newest email", appName: "Mail",
            needsRunningApp: false, bringsAppForward: true,
            state: .init(isRunning: true, isFrontmost: true, previousFrontmostBundleID: nil))
        #expect(!plan.bringsForward, "already in front — nothing moves, no card")
        #expect(plan.planCard == nil)
        #expect(plan.returnsFocusTo == nil)
    }

    @Test func dataReadWithoutAMenuRouteNeverBringsForward() {
        // The fall needs the menu signal (bringsAppForward). A plain data read of a
        // background app must STILL touch nothing — unchanged from before. Mail is not
        // running: a read whose only routes need the app events starts it hidden (the
        // needsRunningApp gate now reads the capability alone, writes included).
        let plan = LanePlan.decide(
            request: "what did Salman text me today", appName: "Messages",
            needsRunningApp: false, bringsAppForward: false,
            state: .init(isRunning: false, isFrontmost: false, previousFrontmostBundleID: "com.apple.Safari"))
        #expect(!plan.bringsForward)
        #expect(plan.planCard == nil)
    }

    // MARK: - Menu-click activation gate (§2a rule 1)

    @Test func onlyTheUILaneActivatesForAMenuClick() {
        #expect(RequestLane.ui.activatesAppForMenuClick)
        #expect(!RequestLane.data.activatesAppForMenuClick)
    }

    // MARK: - §2b invariants: Messages is never launched to read; Terminal is headless

    @MainActor
    @Test func messagesReadsNeverStartTheApp() {
        for id in ["messages.search", "messages.recent", "messages.topContacts"] {
            guard let cap = CapabilityRegistry.shared.capability(id: id) else {
                Issue.record("missing capability \(id)"); continue
            }
            #expect(!cap.needsRunningApp, "\(id) must not start Messages — reads come from chat.db")
        }
    }

    @MainActor
    @Test func terminalRunCommandIsHeadless() {
        guard let cap = CapabilityRegistry.shared.capability(id: "terminal.runCommand") else {
            Issue.record("missing terminal.runCommand"); return
        }
        #expect(cap.appBundleID == nil)
        #expect(!cap.needsRunningApp)
    }
}
