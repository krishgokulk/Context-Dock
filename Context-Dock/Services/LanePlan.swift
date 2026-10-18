// LanePlan.swift
// Context-Dock
//
// Plan 00-APP-AGENT-PLUGIN-PLAN.md §2a/§2b. The lane (data vs UI) is decided once, at
// understanding, from the request words (`RequestLane.decide`). `LanePlan` turns that decision
// plus the app's current state into the concrete things the one executor must do around a
// capability: start a closed app hidden (data lane), bring the app forward and return focus
// afterwards (UI lane), and the lines the turn shows for it.
//
// Pure and state-injected so the decision is unit-testable without a live app. The one
// executor (`AIExecutionEngine.execute`) builds the snapshot and acts on the plan.

import AppKit
import Foundation

/// The app facts the lane logic needs, gathered behind a seam.
struct AppStateSnapshot: Equatable {
    var isRunning: Bool
    /// The target app is the one the user is already looking at.
    var isFrontmost: Bool
    /// Bundle id of the app that was frontmost before the turn, to hand focus back to after a
    /// UI-lane step that had to bring the target forward. Nil when the target was already front.
    var previousFrontmostBundleID: String?
}

/// What the executor does to the app around a capability, for a given lane and app state.
struct LanePlan: Equatable {
    var lane: RequestLane
    /// Start the target app hidden, not activated, before running (data lane, app not running).
    var startsHidden: Bool
    /// Bring the target app forward before running (UI lane that needs the window/menu in front).
    var bringsForward: Bool
    /// After a UI-lane step that brought the app forward, return focus to this bundle id.
    var returnsFocusTo: String?

    /// The line the turn always shows for the lane decision: "Lane: data" / "Lane: UI".
    var laneStep: String { "Lane: \(lane == .data ? "data" : "UI")" }

    /// The plan-card line shown before a UI-lane step that moves the app, else nil.
    /// Example: "Bring Mail forward, run the step, then return".
    var planCard: String?

    /// Decide the plan. `needsRunningApp` marks a data-lane Apple-Event capability (the app must
    /// be alive to answer events); `bringsAppForward` marks a UI-lane capability that needs the
    /// window or menu bar in front (a menu command). A request may read as UI by its words yet
    /// run a capability that needs no window, so the capability gates the forward move.
    static func decide(
        request: String,
        appName: String,
        needsRunningApp: Bool,
        bringsAppForward: Bool,
        state: AppStateSnapshot
    ) -> LanePlan {
        let lane = RequestLane.decide(request)

        if lane == .ui, bringsAppForward {
            // Already in front: just press it, nothing moves, no focus to restore.
            if state.isFrontmost {
                return LanePlan(
                    lane: .ui, startsHidden: false, bringsForward: false, returnsFocusTo: nil,
                    planCard: nil)
            }
            // Elsewhere (background or not running): bring it forward, then return focus.
            return LanePlan(
                lane: .ui, startsHidden: false, bringsForward: true,
                returnsFocusTo: state.previousFrontmostBundleID,
                planCard: "Bring \(appName) forward, run the step, then return")
        }

        // Data lane (or a UI request whose capability needs no window): never activates, never
        // moves focus. A closed app that must answer Apple Events is started hidden.
        return LanePlan(
            lane: lane, startsHidden: needsRunningApp && !state.isRunning, bringsForward: false,
            returnsFocusTo: nil, planCard: nil)
    }
}

/// The result of making an app ready for one capability: the turn steps to show, and how to
/// return focus afterwards. Built by `LaneCoordinator`; `restoreFocus` is a no-op unless a
/// UI-lane step brought the target forward from elsewhere.
struct LaneOutcome {
    var steps: [String]
    fileprivate var returnFocusTo: String?

    /// Hand focus back to the app the user was in, after a UI-lane step that moved the target.
    @MainActor
    func restoreFocus() async {
        guard let bundleID = returnFocusTo else { return }
        guard
            let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleID && !$0.isTerminated
            })
        else { return }
        _ = app.activate(options: [.activateIgnoringOtherApps])
    }
}

/// The one executor's lane IO: reads the app's live state, decides with `LanePlan`, then starts
/// a closed app hidden (data lane) or brings the target forward (UI lane). Thin by design — the
/// decision it acts on is the pure, unit-tested `LanePlan.decide`.
@MainActor
enum LaneCoordinator {
    static func prepare(capability: AICapability, userRequest: String) async -> LaneOutcome {
        let lane = RequestLane.decide(userRequest)
        // No app to ready (EventKit, shell, file routes): just name the lane.
        guard let bundleID = capability.appBundleID, !bundleID.isEmpty else {
            return LaneOutcome(steps: ["Lane: \(lane == .data ? "data" : "UI")"], returnFocusTo: nil)
        }

        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications.first {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
        let frontmost = workspace.frontmostApplication
        let appName = running?.localizedName ?? capability.title
        let snapshot = AppStateSnapshot(
            isRunning: running != nil,
            isFrontmost: running != nil && running?.bundleIdentifier == frontmost?.bundleIdentifier,
            previousFrontmostBundleID: frontmost?.bundleIdentifier == bundleID
                ? nil : frontmost?.bundleIdentifier)

        // A write (compose, archive) is medium/high risk and opens its window because the user
        // will finish it; only a low-risk data read is started silently in the background.
        let plan = LanePlan.decide(
            request: userRequest,
            appName: appName,
            needsRunningApp: capability.needsRunningApp && capability.riskLevel == .low,
            bringsAppForward: capability.bringsAppForward,
            state: snapshot)

        var steps = [plan.laneStep]

        if plan.startsHidden {
            await DataLane.prepare(bundleID: bundleID)
            steps.append("\(appName) wasn't running — started it in the background")
        }

        var returnTo: String?
        if plan.bringsForward {
            if let card = plan.planCard { steps.append(card) }
            running?.activate(options: [.activateIgnoringOtherApps])
            returnTo = plan.returnsFocusTo
        }

        return LaneOutcome(steps: steps, returnFocusTo: returnTo)
    }
}
