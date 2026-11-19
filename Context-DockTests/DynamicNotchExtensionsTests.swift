// Context-Dock
//
// Tests for U7c Notch pinning and U7d container sandbox parsing.

import Foundation
import Testing
@testable import Context_Dock

@MainActor
struct NotchPinStoreTests {

    // Each test gets a fresh store with an isolated UD suite so tests don't bleed.
    private func makeStore() -> NotchPinStore {
        let suite = UUID().uuidString
        return NotchPinStore(userDefaultsSuite: suite)
    }

    @Test func togglePinsCapability() async throws {
        let store = makeStore()
        store.toggle("cap.a", for: "com.example.App")
        #expect(store.isPinned("cap.a", for: "com.example.App"))
    }

    @Test func toggleUnpinsCapability() async throws {
        let store = makeStore()
        store.toggle("cap.a", for: "com.example.App")
        store.toggle("cap.a", for: "com.example.App")
        #expect(!store.isPinned("cap.a", for: "com.example.App"))
    }

    @Test func maxPinsEnforced() async throws {
        let store = makeStore()
        let bundleID = "com.example.App"
        for i in 0..<NotchPinStore.maxPinsPerApp {
            store.toggle("cap.\(i)", for: bundleID)
        }
        // A 5th toggle should be silently dropped
        store.toggle("cap.overflow", for: bundleID)
        #expect(!store.isPinned("cap.overflow", for: bundleID))
        #expect(store.pinnedIDs(for: bundleID).count == NotchPinStore.maxPinsPerApp)
    }

    @Test func unpinRemovesEntry() async throws {
        let store = makeStore()
        store.toggle("cap.a", for: "com.example.App")
        store.unpin("cap.a", for: "com.example.App")
        #expect(!store.isPinned("cap.a", for: "com.example.App"))
    }

    @Test func pinnedIDsPreservesOrder() async throws {
        let store = makeStore()
        let bundleID = "com.example.App"
        store.toggle("cap.z", for: bundleID)
        store.toggle("cap.a", for: bundleID)
        store.toggle("cap.m", for: bundleID)
        #expect(store.pinnedIDs(for: bundleID) == ["cap.z", "cap.a", "cap.m"])
    }

    @Test func unpinNonexistentIsSafe() async throws {
        let store = makeStore()
        store.unpin("cap.never", for: "com.example.App") // must not crash
        #expect(store.pinnedIDs(for: "com.example.App").isEmpty)
    }
}

struct NotchIconHelperTests {
    @Test func summarizeKeyword() {
        #expect(notchIcon(for: "Summarize page") == "text.alignleft")
    }

    @Test func sendKeyword() {
        #expect(notchIcon(for: "Send via Mail") == "paperplane")
    }

    @Test func fallback() {
        #expect(notchIcon(for: "Frobulate widget") == "bolt.fill")
    }
}

struct NotchAuthoringIntentTests {
    private func isNotchIntent(_ query: String) -> Bool {
        let lower = query.lowercased()
        return lower.contains("notch")
            && (lower.hasPrefix("add ") || lower.hasPrefix("create ")
                || lower.hasPrefix("make ") || lower.hasPrefix("pin "))
    }

    @Test func detectAddNotchIntent() {
        #expect(isNotchIntent("add a notch button to Safari"))
    }

    @Test func detectCreateNotchIntent() {
        #expect(isNotchIntent("create a notch action for Xcode"))
    }

    @Test func detectMakeNotchIntent() {
        #expect(isNotchIntent("make notch thing"))
    }

    @Test func detectPinNotchIntent() {
        #expect(isNotchIntent("pin to notch"))
    }

    @Test func regularQueryNotDetected() {
        #expect(!isNotchIntent("summarize this page"))
    }

    @Test func notchWithoutLeadingVerbNotDetected() {
        #expect(!isNotchIntent("the notch is cool"))
    }
}

struct PluginActionSandboxTests {
    private func decode(_ json: String) throws -> PluginAction {
        try JSONDecoder().decode(PluginAction.self, from: Data(json.utf8))
    }

    @Test func sandboxFieldParsed() throws {
        let action = try decode("""
        {"type":"bash","script":"echo hi","sandbox":"container"}
        """)
        #expect(action.sandbox == "container")
    }

    @Test func missingSandboxIsNil() throws {
        let action = try decode("""
        {"type":"bash","script":"echo hi"}
        """)
        #expect(action.sandbox == nil)
    }

    @Test func unknownSandboxValuePreserved() throws {
        let action = try decode("""
        {"type":"bash","script":"echo hi","sandbox":"docker"}
        """)
        // Unknown values pass through; PluginScriptRunner will fall back gracefully.
        #expect(action.sandbox == "docker")
    }

    @Test func roundTripEncoding() throws {
        var action = PluginAction(type: "bash", script: "echo hi", sandbox: "container")
        let data = try JSONEncoder().encode(action)
        let roundTripped = try JSONDecoder().decode(PluginAction.self, from: data)
        #expect(roundTripped.sandbox == "container")
    }
}
