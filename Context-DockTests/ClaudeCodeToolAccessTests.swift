import Foundation
import Testing

@testable import Context_Dock

// What DoraX hands the Claude CLI, and what it withholds.
//
// The flags are asserted rather than trusted because they were wrong once already: every
// invocation passed `--allowed-tools ""`, which is a permission rule, where `--tools ""` is
// the documented way to select the built-in set. A wrong flag here fails silently — the CLI
// answers perfectly well with no tools, so nothing looks broken until someone asks it to read
// a file and it explains that it cannot.
//
// Verified against claude 2.1.220 before these were written: `--tools "Read,Bash"` with
// `--permission-mode acceptEdits` runs both headless under `-p`.

@MainActor
struct ClaudeCodeToolAccessTests {

    private func arguments(
        _ access: ClaudeCodeCLIService.ToolAccess, directory: URL? = URL(fileURLWithPath: "/tmp/x")
    ) -> [String] {
        ClaudeCodeCLIService.arguments(
            prompt: "hello", systemPrompt: "ctx", model: "opus",
            access: access, workingDirectory: directory)
    }

    /// The value pair the CLI needs to run anything non-interactively. `-p` cannot answer a
    /// permission prompt, so a tool without acceptEdits stalls the turn rather than failing.
    @Test func runningToolsRequiresBothTheSetAndThePermissionMode() {
        for access in [ClaudeCodeCLIService.ToolAccess.research, .full] {
            let args = arguments(access)
            #expect(args.contains("--tools"), "\(access.rawValue) must select a tool set")
            #expect(
                args.contains("--permission-mode") && args.contains("acceptEdits"),
                "\(access.rawValue) would stall waiting for a permission nobody can grant")
        }
    }

    /// Answer-only is the one level that must hand over nothing at all.
    @Test func answerOnlyPassesAnEmptyToolSetAndNoPermissions() {
        let args = arguments(.answerOnly)
        let toolsValue = args.firstIndex(of: "--tools").map { args[args.index(after: $0)] }
        #expect(toolsValue == "", "answer-only must disable every tool")
        #expect(!args.contains("--permission-mode"), "nothing needs permission to answer")
        #expect(!args.contains("--add-dir"), "answering needs no folder")
    }

    /// The escalation is one-way and additive: research reads, full also writes and runs.
    /// Nothing that changes the disk may appear below full.
    @Test func onlyFullCanChangeAnything() {
        let research = ClaudeCodeCLIService.ToolAccess.research.toolList
        for writing in ["Edit", "Write", "Bash"] {
            #expect(!research.contains(writing), "research must not include \(writing)")
        }
        let full = ClaudeCodeCLIService.ToolAccess.full.toolList
        for writing in ["Edit", "Write", "Bash"] {
            #expect(full.contains(writing), "full must include \(writing)")
        }
        #expect(ClaudeCodeCLIService.ToolAccess.research.runsTools)
        #expect(!ClaudeCodeCLIService.ToolAccess.answerOnly.runsTools)
    }

    /// A tool that can write needs somewhere to write. The folder is passed explicitly so the
    /// CLI is not left resolving it from wherever DoraX happened to be launched.
    @Test func anythingWithToolsIsGivenItsFolder() {
        let args = arguments(.full, directory: URL(fileURLWithPath: "/tmp/project"))
        #expect(args.contains("--add-dir"))
        #expect(args.contains("/tmp/project"))
    }

    /// An unknown value — written by a newer build, or edited by hand — must read as the
    /// safest level, never as the most powerful one.
    @Test func anUnrecognisedSettingFallsBackToAnsweringOnly() {
        #expect(ClaudeCodeCLIService.ToolAccess(rawValue: "somethingElse") == nil)
        let settings = AppSettings.shared
        let saved = settings.claudeCodeToolAccessRaw
        defer { settings.claudeCodeToolAccessRaw = saved }

        settings.claudeCodeToolAccessRaw = "somethingElse"
        #expect(settings.claudeCodeToolAccess == .answerOnly)
    }

    /// The prompt and the context still reach the CLI whatever the level — the earlier bug
    /// was a flag change that quietly dropped what was being asked.
    @Test func theQuestionAndItsContextAlwaysGetThrough() {
        for access in ClaudeCodeCLIService.ToolAccess.allCases {
            let args = arguments(access)
            #expect(args.contains("hello"), "\(access.rawValue) dropped the prompt")
            #expect(args.contains("--append-system-prompt") && args.contains("ctx"))
            #expect(args.contains("--model") && args.contains("opus"))
            #expect(args.contains("--output-format") && args.contains("json"))
        }
    }
}
