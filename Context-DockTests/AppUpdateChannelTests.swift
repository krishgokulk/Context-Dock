import Foundation
import Testing
@testable import Context_Dock

/// The update channel decides which manifest on `main` the app reads. Every build shipped so far
/// reads `update-manifest.json`, so beta must stay the default and keep that exact file.
@MainActor
struct AppUpdateChannelTests {
    /// A private suite: the test host shares the developer's own UserDefaults domain.
    private func isolatedDefaults() -> UserDefaults {
        let name = "com.krishgokul.ContextDock.tests.update-channel"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func betaIsTheDefault() {
        #expect(AppUpdateService.Channel.current(in: isolatedDefaults()) == .beta)
    }

    @Test func unknownValueFallsBackToBeta() {
        let defaults = isolatedDefaults()
        defaults.set("nightly", forKey: AppUpdateService.Channel.defaultsKey)
        #expect(AppUpdateService.Channel.current(in: defaults) == .beta)
    }

    @Test func stableIsReadFromDefaults() {
        let defaults = isolatedDefaults()
        defaults.set("stable", forKey: AppUpdateService.Channel.defaultsKey)
        #expect(AppUpdateService.Channel.current(in: defaults) == .stable)
    }

    @Test func betaKeepsTheManifestEveryShippedBuildReads() {
        #expect(AppUpdateService.Channel.beta.manifestURL.absoluteString
            == "https://raw.githubusercontent.com/krishgokulk/Context-Dock/main/update-manifest.json")
    }

    @Test func stableReadsItsOwnManifest() {
        #expect(AppUpdateService.Channel.stable.manifestURL.lastPathComponent == "update-manifest-stable.json")
    }
}
