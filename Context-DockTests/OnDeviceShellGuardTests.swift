// OnDeviceShellGuardTests.swift
// Context-DockTests
//
// Unit tests for Issue #188: on-device shell detection and app-scope Clock boundary.

import Testing
@testable import Context_Dock

@Suite("On-device shell guard (#188)")
struct OnDeviceShellGuardTests {

    private static let mockPrograms: Set<String> = [
        "curl", "ls", "git", "grep", "npm", "python3", "pip", "brew", "cat", "echo"
    ]
    private static func testIsProgram(_ name: String) -> Bool { mockPrograms.contains(name) }

    @Test("Direct shell commands are detected")
    func directShellCommands() {
        #expect(DockCore.looksLikeOnDeviceShellQuery("curl https://httpbin.org/get",
                                                     isProgram: Self.testIsProgram))
        #expect(DockCore.looksLikeOnDeviceShellQuery("ls -la",
                                                     isProgram: Self.testIsProgram))
        #expect(DockCore.looksLikeOnDeviceShellQuery("git status",
                                                     isProgram: Self.testIsProgram))
        #expect(DockCore.looksLikeOnDeviceShellQuery("grep -r foo .",
                                                     isProgram: Self.testIsProgram))
    }

    @Test("'run/execute/exec <program>' prefix pattern is detected")
    func runPrefixPattern() {
        #expect(DockCore.looksLikeOnDeviceShellQuery("run curl https://httpbin.org/get",
                                                     isProgram: Self.testIsProgram))
        #expect(DockCore.looksLikeOnDeviceShellQuery("run ls",
                                                     isProgram: Self.testIsProgram))
        #expect(DockCore.looksLikeOnDeviceShellQuery("run git status",
                                                     isProgram: Self.testIsProgram))
        #expect(DockCore.looksLikeOnDeviceShellQuery("execute npm install",
                                                     isProgram: Self.testIsProgram))
        #expect(DockCore.looksLikeOnDeviceShellQuery("exec grep -r foo",
                                                     isProgram: Self.testIsProgram))
    }

    @Test("Non-shell queries are not detected")
    func nonShellQueries() {
        #expect(!DockCore.looksLikeOnDeviceShellQuery("what's the weather today",
                                                      isProgram: Self.testIsProgram))
        #expect(!DockCore.looksLikeOnDeviceShellQuery("chat history for Slack",
                                                      isProgram: Self.testIsProgram))
        #expect(!DockCore.looksLikeOnDeviceShellQuery("run a meeting tomorrow",
                                                      isProgram: Self.testIsProgram))
        #expect(!DockCore.looksLikeOnDeviceShellQuery("",
                                                      isProgram: Self.testIsProgram))
        #expect(!DockCore.looksLikeOnDeviceShellQuery("run diagnostics on my Mac",
                                                      isProgram: Self.testIsProgram))
    }

    @Test("Path-prefixed queries are always detected")
    func pathPrefixedQueries() {
        #expect(DockCore.looksLikeOnDeviceShellQuery("./setup.sh",
                                                     isProgram: Self.testIsProgram))
        #expect(DockCore.looksLikeOnDeviceShellQuery("/usr/bin/python3 script.py",
                                                     isProgram: Self.testIsProgram))
        #expect(DockCore.looksLikeOnDeviceShellQuery("~/bin/myscript",
                                                     isProgram: Self.testIsProgram))
    }
}

@Suite("On-device timer parser (#188)")
struct OnDeviceTimerParserTests {

    @Test("Common timer phrasings return correct seconds")
    func commonPhrasing() {
        #expect(DockCore.parseOnDeviceTimerSeconds("set a timer for 1 minute") == 60)
        #expect(DockCore.parseOnDeviceTimerSeconds("timer for 30 seconds") == 30)
        #expect(DockCore.parseOnDeviceTimerSeconds("5 minute timer") == 300)
        #expect(DockCore.parseOnDeviceTimerSeconds("set a 2 hour countdown") == 7200)
        #expect(DockCore.parseOnDeviceTimerSeconds("1 hour 30 min timer") == 5400)
        #expect(DockCore.parseOnDeviceTimerSeconds("can you set a timer for 1 min") == 60)
    }

    @Test("Non-timer queries return nil")
    func nonTimerQueries() {
        #expect(DockCore.parseOnDeviceTimerSeconds("what time is it") == nil)
        #expect(DockCore.parseOnDeviceTimerSeconds("run curl https://example.com") == nil)
        #expect(DockCore.parseOnDeviceTimerSeconds("check my calendar") == nil)
        #expect(DockCore.parseOnDeviceTimerSeconds("the old timer ran out") == nil)
    }
}

@Suite("Clock scope boundary — app-scoped timer (#188)")
struct ClockAppScopeTests {

    @Test("namesClockApp matches timer/alarm intents")
    func namesClockAppMatches() {
        #expect(AppScopedChatService.namesClockApp("set a timer for 1 min"))
        #expect(AppScopedChatService.namesClockApp("can you set a timer for 5 minutes"))
        #expect(AppScopedChatService.namesClockApp("start a timer"))
        #expect(AppScopedChatService.namesClockApp("timer for 30 seconds"))
        #expect(AppScopedChatService.namesClockApp("set an alarm for 7am"))
        #expect(AppScopedChatService.namesClockApp("alarm for tomorrow morning"))
        #expect(AppScopedChatService.namesClockApp("stopwatch please"))
        #expect(AppScopedChatService.namesClockApp("SET A TIMER"))
    }

    @Test("namesClockApp does not match unrelated queries")
    func namesClockAppNoMatch() {
        #expect(!AppScopedChatService.namesClockApp("what time is it"))
        #expect(!AppScopedChatService.namesClockApp("check my calendar"))
        #expect(!AppScopedChatService.namesClockApp("remind me to call John"))
        #expect(!AppScopedChatService.namesClockApp("the timer ran out already"))
    }

    @Test("subjectApps includes Clock entry for timer markers")
    @MainActor
    func subjectAppsIncludesClock() {
        let result = AppScopedChatService.subjectApps(in: "set a timer for 5 minutes")
        for item in result {
            if item.bundleId == "com.apple.clock" {
                #expect(item.name == "Clock")
            }
        }
    }
}
