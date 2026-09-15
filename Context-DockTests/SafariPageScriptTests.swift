// SafariPageScriptTests.swift
// Context-DockTests
//
// Every page script Safari ran through AppleScript failed before it ran: the tell block
// said `execute JavaScript`, which is not Safari terminology, so AppleScript refused to
// compile it and returned "Expected end of line but found identifier." The user saw that
// twice over — once as an authored page action's own failure, and once as "Safari has not
// delivered a fresh current-page snapshot", because the read-only page reader falls back to
// this same route and read the compile error as "no links on the page".

import Foundation
import Testing

@testable import Context_Dock

@Suite("Safari page script")
@MainActor
struct SafariPageScriptTests {

    @Test("The script uses Safari's own verb")
    func usesDoJavaScript() {
        let script = SafariTabManager.pageScript(
            jsPath: "/tmp/cdock_js_abc.js", target: "current tab of front window")

        #expect(script.contains("do JavaScript jsCode in current tab of front window"))
        // `execute JavaScript` compiles into nothing at all.
        #expect(!script.contains("execute JavaScript"))
    }

    @Test("A specific tab is addressed the same way")
    func addressesAChosenTab() {
        let script = SafariTabManager.pageScript(
            jsPath: "/tmp/cdock_js_abc.js", target: "tab 2 of window 1")

        #expect(script.contains("do JavaScript jsCode in tab 2 of window 1"))
        #expect(!script.contains("execute JavaScript"))
    }

    @Test("The script is read from disk rather than quoted into the source")
    func readsTheScriptFromDisk() {
        // The JS itself never passes through AppleScript quoting — newlines, backslashes,
        // regexes and quotes in an authored script would not survive it.
        let script = SafariTabManager.pageScript(
            jsPath: "/tmp/cdock_js_abc.js", target: "current tab of front window")

        #expect(script.contains("do shell script"))
        #expect(script.contains("quoted form of \"/tmp/cdock_js_abc.js\""))
    }
}
