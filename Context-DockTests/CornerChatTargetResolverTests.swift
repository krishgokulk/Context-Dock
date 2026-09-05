import AppKit
import Testing

@testable import Context_Dock

@MainActor
struct CornerChatTargetResolverTests {
    @Test func ownFrontmostAppFallsBackToRememberedExternalApp() throws {
        let own = NSRunningApplication.current
        let external = try #require(
            NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == ChatAppDirectory.finderBundleID
            })

        let resolved = AppDelegate.appChatTargetApplication(
            menuBarOwner: nil,
            remembered: external,
            rawFrontmost: own,
            ownBundleID: own.bundleIdentifier ?? "")

        #expect(resolved?.bundleIdentifier == ChatAppDirectory.finderBundleID)
    }
}
