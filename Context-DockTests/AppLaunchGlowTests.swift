import SwiftUI
import Testing

@testable import Context_Dock

/// An app opening or quitting glows the dock — green, red — instead of an icon at its end
/// (owner 2026-10-16).
@MainActor
@Suite("App launch glow")
struct AppLaunchGlowTests {
    private func feedback(
        _ title: String, icon: String, phase: DockInlineFeedback.Phase, app: String? = "Mail"
    ) -> CornerActionFeedback {
        let store = CornerActionFeedback()
        store.show(DockInlineFeedback(
            id: "t", title: title, icon: icon, phase: phase, subject: app,
            bundleID: app == nil ? nil : "com.apple.mail"))
        return store
    }

    @Test func aLaunchGlowsGreenAndAQuitRedWithNoIcon() {
        let launch = feedback("Opening Mail…", icon: DockActionFeedback.launchSymbol, phase: .progress)
        #expect(launch.appGlow == .green)
        #expect(launch.glyph == nil)

        let quit = feedback("Quit Mail", icon: "xmark.circle.fill", phase: .success)
        #expect(quit.appGlow == .red)
        #expect(quit.glyph == nil)

        let failed = feedback("Couldn't quit Mail", icon: "xmark.circle.fill", phase: .failure)
        #expect(failed.appGlow == .red)
    }

    @Test func bringingARunningAppForwardDoesNotGlow() {
        let forward = feedback("Opening Mail…", icon: "macwindow", phase: .progress)
        #expect(forward.appGlow == nil)
    }

    @Test func aResultAboutNoAppKeepsItsIcon() {
        let copied = feedback("Copied", icon: "doc.on.doc", phase: .success, app: nil)
        #expect(copied.appGlow == nil)
        #expect(copied.glyph != nil)
    }

    /// Global's "Opened X" for an app found by its path names no bundle — still a launch.
    @Test func anOpenedResultWithoutItsBundleStillGlows() {
        let opened = feedback("Opened Tailscale", icon: DockActionFeedback.launchSymbol, phase: .success, app: nil)
        #expect(opened.appGlow == .green)
        #expect(opened.glyph == nil)
    }
}

/// ↩ on a closed app's menu command opens the app, then runs it (owner 2026-10-17).
@MainActor
@Suite("Run a closed app's command")
struct LaunchFirstTests {
    @Test func aClosedAppsCommandOpensItFirst() {
        #expect(AppChatPromptModel.launchFirst("com.apple.mail", path: ["Mailbox", "New Mailbox…"]) == "com.apple.mail")
    }

    @Test func aQuitOrAToolOrNothingLaunchesNothing() {
        #expect(AppChatPromptModel.launchFirst("com.apple.mail", path: ["Mail", "Quit Mail"]) == nil)
        #expect(AppChatPromptModel.launchFirst("cli://brew", path: ["update"]) == nil)
        #expect(AppChatPromptModel.launchFirst("", path: ["File", "New"]) == nil)
    }
}
