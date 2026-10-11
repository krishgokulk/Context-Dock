// Context-DockTests/PluginRefreshPolicyTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginRefreshPolicyTests {
    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private let sonos = #"""
    { "id": "s", "name": "S",
      "data": { "type": "bash", "script": "data.sh",
                "refresh": { "icon": 30, "widget": 5, "panel": 0, "window": 1 } } }
    """#

    @Test func eachHostGetsItsOwnInterval() throws {
        let m = try manifest(sonos)
        #expect(PluginRefreshPolicy.interval(for: m, host: .icon, budget: .full) == 30)
        #expect(PluginRefreshPolicy.interval(for: m, host: .widget, budget: .full) == 5)
        #expect(PluginRefreshPolicy.interval(for: m, host: .window, budget: .full) == 1)
    }

    @Test func zeroMeansNeverRatherThanEveryZeroSeconds() throws {
        // A refresh of 0 read as an interval is an infinite loop that runs a shell script.
        #expect(PluginRefreshPolicy.interval(for: try manifest(sonos), host: .panel, budget: .full) == nil)
    }

    @Test func aHostWithNoBudgetNeverTicks() throws {
        let m = try manifest(sonos)
        #expect(PluginRefreshPolicy.interval(for: m, host: .widget, budget: .none) == nil)
    }

    @Test func aLowBudgetSlowsDownRatherThanStopping() throws {
        let m = try manifest(sonos)
        let full = try #require(PluginRefreshPolicy.interval(for: m, host: .widget, budget: .full))
        let low = try #require(PluginRefreshPolicy.interval(for: m, host: .widget, budget: .low))
        #expect(low > full)
    }

    @Test func aManifestWithNoDataSourceNeverTicks() throws {
        let m = try manifest(#"{ "id": "x", "name": "X" }"#)
        #expect(PluginRefreshPolicy.interval(for: m, host: .panel, budget: .full) == nil)
    }

    @Test func noMoreThanFourPluginsTickAtOnce() {
        // Spec §5. The fifth live widget is what turns a dock into a battery complaint.
        #expect(PluginRefreshPolicy.admits(runningLiveCount: 3))
        #expect(PluginRefreshPolicy.admits(runningLiveCount: 4) == false)
    }

    @Test func anIntervalIsNeverFasterThanTheFloor() throws {
        // A manifest asking for 0.1s would run a process ten times a second.
        let greedy = try manifest(#"{ "id": "x", "name": "X", "data": { "type": "bash", "script": "s", "refresh": { "panel": 1 } } }"#)
        let interval = try #require(PluginRefreshPolicy.interval(for: greedy, host: .panel, budget: .full))
        #expect(interval >= 1)
    }
}
