import Foundation
import Testing

@testable import Context_Dock

/// The suite runs inside a copy of the app with `TestHostAppleEventBlocker` installed. If the
/// method swap ever stops taking effect, Apple Events go back to waiting 120 s on CI for an
/// Automation prompt nobody answers — this fails first instead.
@MainActor
struct TestHostAppleEventBlockerTests {
    @Test func theTestHostKnowsItIsOne() {
        #expect(AppDelegate.isHostingTests)
    }

    @Test func appleScriptFailsAsNotPermittedInsteadOfRunning() throws {
        let script = try #require(NSAppleScript(source: "return 42"))
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        #expect(result.int32Value != 42)
        #expect(error?[NSAppleScript.errorNumber] as? Int == -1743)
    }

    @Test func sendingAnAppleEventThrowsNotPermitted() {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: 0x6D697363,  // 'misc'
            eventID: 0x61637476,  // 'actv'
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        #expect(throws: (any Error).self) {
            _ = try event.sendEvent(options: [.waitForReply], timeout: 1)
        }
    }
}
