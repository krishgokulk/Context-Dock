import Foundation
import Testing
@testable import Context_Dock

/// Regression tests for Issue #65: test host must not bind a live TCP listener on port 8213.
///
/// When the test host runs alongside a dev app, two processes racing to bind the same
/// loopback port throw `NWError error 48 — Address already in use` and silently truncate
/// the suite.  `DoraXMCPServer.start()` now checks `AppDelegate.isHostingTests` and
/// returns without touching the network.
struct DoraXMCPServerTests {

    @Test func startIsNoOpWhileHostingTests() async throws {
        // isHostingTests must be true in this process — otherwise the guard we are
        // testing is not reachable and the assertion below is vacuous.
        #expect(AppDelegate.isHostingTests, "test host did not set isHostingTests — guard cannot be verified")

        // Calling start() must leave the server stopped.
        await MainActor.run { DoraXMCPServer.shared.start() }

        let running = await MainActor.run { DoraXMCPServer.shared.isRunning }
        #expect(!running, "DoraXMCPServer bound a live listener while isHostingTests is true")
    }

    @Test func startIfEnabledIsNoOpWhileHostingTests() async throws {
        // Simulate the user having turned on the server in UserDefaults.
        UserDefaults.standard.set(true, forKey: DoraXMCPServer.enabledKey)
        defer { UserDefaults.standard.removeObject(forKey: DoraXMCPServer.enabledKey) }

        await MainActor.run { DoraXMCPServer.shared.startIfEnabled() }

        let running = await MainActor.run { DoraXMCPServer.shared.isRunning }
        #expect(!running, "DoraXMCPServer bound a live listener via startIfEnabled while isHostingTests is true")
    }
}
