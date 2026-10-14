import AppKit
import Testing

@testable import Context_Dock

/// Global search's index builder, moved out of the old launcher (issue #247, 4b).
@MainActor
struct GlobalSearchIndexBuilderTests {
    @Test func newsIsNeverAnAppToSearch() {
        #expect(GlobalSearchIndexBuilder.shouldIgnoreApplicationFromAppSearch(
            appName: "News", bundleIdentifier: nil, path: nil))
        #expect(GlobalSearchIndexBuilder.shouldIgnoreApplicationFromAppSearch(
            appName: "Anything", bundleIdentifier: "com.apple.news", path: nil))
        #expect(!GlobalSearchIndexBuilder.shouldIgnoreApplicationFromAppSearch(
            appName: "Notes", bundleIdentifier: "com.apple.Notes",
            path: "/System/Applications/Notes.app"))
    }

    @Test func runningAppsAreListedOnceAndNeverIncludeDoraX() {
        let apps = GlobalSearchIndexBuilder.currentRegularRunningApps()
        let ids = apps.compactMap(\.bundleIdentifier)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(Bundle.main.bundleIdentifier ?? "-"))
        #expect(apps.allSatisfy { $0.activationPolicy == .regular })
    }
}
