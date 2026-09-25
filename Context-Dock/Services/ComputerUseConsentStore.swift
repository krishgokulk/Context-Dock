// ComputerUseConsentStore.swift
// Context-Dock
//
// Whether DoraX may operate an app's screen, and how closely the user wants to watch.
//
// Every other route DoraX has is a thing the app itself offers: a capability, an MCP tool, a
// linked CLI, a menu command it publishes. Computer Use is different in kind — it takes the
// pointer and the keyboard, in an app the user is looking at, and it works precisely because
// nothing in the app agreed to it. That is worth a permission model of its own rather than a
// line in an existing one.
//
// Two layers, settled in decision `fe47daa8`: a master switch for the machine, a tri-state per
// app beneath it. One alone fails in a known way. A master switch alone means enabling Code to
// check for updates also allows Mail to be driven. Per-app alone means that when a click goes
// somewhere unintended, the user's first instinct — stop all of this, now — sends them hunting
// for the row that granted it.

import Combine
import Foundation

/// How closely the user wants to supervise DoraX operating one app.
enum ComputerUseMode: String, Codable, CaseIterable, Sendable {
    /// DoraX never operates this app. The default, for every app, forever until changed.
    case off
    /// Each click or keystroke is shown — what it will press, and the frame it read it from —
    /// and waits for the user.
    case askEachStep
    /// The task is approved once; the steps inside it run without further prompts.
    case autoInTask

    var canOperate: Bool { self != .off }

    /// A task is always approved before anything is operated. `autoInTask` buys freedom from
    /// the per-step prompt, never from the per-task one — a user approving "update this app"
    /// is not approving whatever the model does next in the same window.
    var requiresApprovalPerTask: Bool { canOperate }

    var requiresApprovalPerStep: Bool { self == .askEachStep }

    var title: String {
        switch self {
        case .off: return "Off"
        case .askEachStep: return "Ask each step"
        case .autoInTask: return "Auto in task"
        }
    }

    var explanation: String {
        switch self {
        case .off: return "DoraX never operates this app"
        case .askEachStep: return "Each click is shown, and waits for you"
        case .autoInTask: return "Approve the task once; its steps then run"
        }
    }
}

@MainActor
final class ComputerUseConsentStore: ObservableObject {
    static let shared = ComputerUseConsentStore()

    private let masterKey = "dorax.computerUse.enabled.v1"
    private let modesKey = "dorax.computerUse.appModes.v1"
    private let defaults: UserDefaults

    /// The kill switch. Off by default, and while it is off no app is operated whatever its
    /// own setting says — so revoking everything is one click in one place, which is the state
    /// a user reaches for after watching something go wrong.
    @Published var isMasterEnabled: Bool {
        didSet { defaults.set(isMasterEnabled, forKey: masterKey) }
    }

    /// Per app, keyed by lowercased bundle id: ids arrive from the running app, the installed
    /// catalogue and stored config, and those three do not always agree on case.
    @Published private var modes: [String: ComputerUseMode] {
        didSet {
            guard let data = try? JSONEncoder().encode(modes) else { return }
            defaults.set(data, forKey: modesKey)
        }
    }

    /// - Parameter defaults: injected so tests get their own suite. The suite is shared with a
    ///   developer's running app otherwise, and a preference set by hand then decides what the
    ///   suite believes — see memory `test-host-shares-the-developers-userdefaults`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isMasterEnabled = defaults.bool(forKey: masterKey)
        if let data = defaults.data(forKey: modesKey),
            let decoded = try? JSONDecoder().decode([String: ComputerUseMode].self, from: data)
        {
            modes = decoded
        } else {
            modes = [:]
        }
    }

    /// What the user chose for this app, ignoring the master switch.
    func mode(for bundleID: String) -> ComputerUseMode {
        modes[key(bundleID)] ?? .off
    }

    /// What actually applies right now. Always read this before operating anything; `mode(for:)`
    /// is for drawing the settings row, where the user's choice should still be visible while
    /// the master switch is off.
    func effectiveMode(for bundleID: String) -> ComputerUseMode {
        isMasterEnabled ? mode(for: bundleID) : .off
    }

    func setMode(_ mode: ComputerUseMode, for bundleID: String) {
        modes[key(bundleID)] = mode
    }

    /// The one-tap grant a chat offers when a request has no other route.
    ///
    /// Grants the cautious tier only. A tap taken mid-task to get unblocked is not the same
    /// decision as sitting in Settings and choosing to stop being asked, and conflating them is
    /// how a user ends up with an app being operated unwatched because they once wanted a menu
    /// item clicked. It turns the master switch on with it, or the grant would appear to do
    /// nothing and the next turn would refuse for a reason they thought they had just answered.
    func grantFromChat(for bundleID: String) {
        isMasterEnabled = true
        setMode(.askEachStep, for: bundleID)
    }

    /// One press, granted in the moment and not remembered.
    ///
    /// "Allow once" and "allow always" are different decisions and the store could only
    /// express the second: `grantFromChat` persists `askEachStep`, which is a standing grant
    /// with a prompt attached. Someone who wanted a single button pressed should not find out
    /// later that the app is permanently operable — the fact that they were asked each time
    /// does not make the grant temporary.
    ///
    /// Deliberately in memory only. A grant that survives a relaunch is not "once", and
    /// writing it to disk is how it would quietly become one. It also does not touch the
    /// master switch: a single press is not a decision about every app.
    func grantOnce(for bundleID: String) {
        oneShot.insert(key(bundleID))
    }

    /// Takes the one-shot grant if there is one. Consuming is the point — calling it twice
    /// for two presses is exactly the thing "once" refuses.
    func consumeOneShotGrant(for bundleID: String) -> Bool {
        oneShot.remove(key(bundleID)) != nil
    }

    /// True while a one-shot grant is outstanding, without spending it. For drawing state,
    /// never for deciding whether to press.
    func hasOneShotGrant(for bundleID: String) -> Bool {
        oneShot.contains(key(bundleID))
    }

    /// Takes an app's standing grant away — Settings' Remove. The next action that needs it
    /// asks again. A pending one-shot press goes with it.
    func revoke(for bundleID: String) {
        setMode(.off, for: bundleID)
        oneShot.remove(key(bundleID))
    }

    /// Apps the user has granted, for the Settings summary — a permission nobody can review is
    /// not a permission model.
    func grantedBundleIDs() -> [String] {
        modes.filter { $0.value.canOperate }.keys.sorted()
    }

    /// Apps with an unspent single press. Not persisted, by design — see `grantOnce`.
    private var oneShot: Set<String> = []

    private func key(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
