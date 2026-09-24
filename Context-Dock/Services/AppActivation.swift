// AppActivation.swift
// Context-Dock
//
// Opening an app, and bringing it to the front — which are not the same thing, and the
// difference is why an app launched from the corner kept arriving behind whatever the user
// was already looking at.
//
// Three things were wrong wherever this was written by hand:
//
// 1. `NSRunningApplication.activate()` with no options is the weak form. From a process
//    that is not itself frontmost, macOS's cooperative activation may ignore it outright,
//    and it never unminimises or raises the app's other windows. `yieldActivation(to:)`
//    first says "the focus is theirs, not mine" — harmless when we are not the active app,
//    and the missing half when we are, because the corner panel can take key.
// 2. A cold launch is not ready to be activated at the moment it exists. `openApplication`
//    activates at launch time; an app that is still opening its first window can land
//    behind. One retry a moment later is what makes it land in front.
// 3. Nothing said it was happening. The surface showed a tick after the fact, or nothing
//    at all.
//
// So: one call does the launch, the raise, the retry and the telling, and every surface
// that opens an app goes through it rather than repeating two of the three.

import AppKit
import Foundation

@MainActor
enum AppActivation {

    /// Open an app — or bring the running one forward — and say so while it happens.
    ///
    /// The result is a *progress* line, not a tick: "Opening Messages…" in the field's own
    /// ghost text, the shell tinted with the app's colour, and both gone once the app is
    /// there. A checkmark for something the user can see happen in front of them is a badge
    /// nobody needed.
    static func bringForward(bundleID: String, name: String) {
        let feedbackID = DockActionFeedback.appOpening(name, bundleID: bundleID)

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated })
        // A running app goes through LaunchServices too, the way the Dock does. The corner
        // panel is non-activating, so a click there leaves us inactive: `yieldActivation`
        // has nothing to yield and cooperative activation can drop `activate()`. And an app
        // whose windows are closed or minimised needs the reopen event `openApplication`
        // sends to an already-running app — activating it alone shows nothing.
        guard let url = running?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            if let running {
                raise(running, restoringWindows: true)
                settle(feedbackID, app: running)
            } else {
                DockActionFeedback.dismiss(feedbackID)
            }
            return
        }
        if let running {
            // The reopen event brings back a closed window; a minimised one still needs
            // taking out of the Dock (CornerAppActivationTests).
            raise(running, restoringWindows: true)
        }
        // Yield before the launch as well as after it. Clicking a strip icon makes the
        // corner panel key, which makes us the active app at the moment of the click; a
        // cold launch that activates into that finds us holding the activation and lands
        // behind. There is no `NSRunningApplication` to yield to yet, so this is the
        // by-bundle-id form.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            Task { @MainActor in
                guard let app else {
                    DockActionFeedback.dismiss(feedbackID)
                    return
                }
                raise(app)
                settle(feedbackID, app: app)
            }
        }
    }

    /// Bring a running app forward, by the path a file or a URL took to get there.
    static func bringForward(_ app: NSRunningApplication, name: String) {
        let feedbackID = DockActionFeedback.appOpening(
            name, bundleID: app.bundleIdentifier)
        raise(app, restoringWindows: true)
        settle(feedbackID, app: app)
    }

    /// What bringing a running app forward takes, in order. Activating is not enough on its
    /// own: `activate` never takes a window out of the Dock, so an app whose only window was
    /// minimised became active with nothing on screen — clicking it in the corner looked
    /// like the click had missed. The Dock's own path (`activateRunningAppFromGlobalContext`)
    /// has always restored minimised windows; this is the same rule, in one place.
    enum RaiseStep: Equatable { case unhide, activate, restoreMinimisedWindows }

    nonisolated static func raiseSteps(isHidden: Bool, restoringWindows: Bool) -> [RaiseStep] {
        (isHidden ? [.unhide] : []) + [.activate]
            + (restoringWindows ? [.restoreMinimisedWindows] : [])
    }

    /// The raise itself. Yield, then activate every window rather than only the front one:
    /// an app whose windows are behind others is not "brought forward" by raising one of
    /// them. `restoringWindows` is for the first raise only — the restore polls for the
    /// genie animation on its own, and the retries in `settle` need not start it again.
    static func raise(_ app: NSRunningApplication, restoringWindows: Bool = false) {
        for step in raiseSteps(isHidden: app.isHidden, restoringWindows: restoringWindows) {
            switch step {
            case .unhide:
                app.unhide()
            case .activate:
                NSApp.yieldActivation(to: app)
                app.activate(options: [.activateAllWindows])
            case .restoreMinimisedWindows:
                // Un-minimises and raises, never moves or resizes — the window comes back
                // where the user left it, as the Dock does.
                WindowManagementService.shared.restoreAfterActivate(app)
            }
        }
    }

    /// Wait for the app to actually be in front, retrying once for the launch that was not
    /// ready the first time, then give the corner back to the dock.
    private static func settle(_ feedbackID: String, app: NSRunningApplication) {
        Task { @MainActor in
            for delay in [0.18, 0.5] where !app.isActive {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !app.isActive, !app.isTerminated else { break }
                raise(app)
            }
            // Long enough for the line to be read, short enough that the dock is not
            // wearing a status. The corner fades back to the strip on its own.
            try? await Task.sleep(nanoseconds: 420_000_000)
            DockActionFeedback.dismiss(feedbackID)
        }
    }
}
