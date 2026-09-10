// CLIScopeRunnerTests.swift
// Context-DockTests
//
// The safety property is the point: a field that searches the machine must not become a way
// to run anything on it. What the user types becomes arguments to one fixed tool, and nothing
// in it is interpreted.

import Foundation
import Testing

@testable import Context_Dock

@Suite("CLI scope runner")
struct CLIScopeRunnerTests {

    @Test("Words become arguments")
    func splitsOnWhitespace() {
        #expect(CLIScopeRunner.arguments(from: "status --json") == ["status", "--json"])
        #expect(CLIScopeRunner.arguments(from: "  up   --ssh  ") == ["up", "--ssh"])
    }

    @Test("Quotes keep a path with spaces together")
    func respectsQuotes() {
        #expect(
            CLIScopeRunner.arguments(from: #"cp "my file.txt" out"#)
                == ["cp", "my file.txt", "out"])
        #expect(CLIScopeRunner.arguments(from: "echo 'one two'") == ["echo", "one two"])
    }

    @Test("Shell punctuation is an argument, not a second command")
    func nothingIsInterpreted() {
        // The whole safety story: these reach the tool as text. There is no `sh -c`, so a
        // semicolon cannot start a new command and a backtick cannot open a substitution.
        #expect(
            CLIScopeRunner.arguments(from: "status; rm -rf /")
                == ["status;", "rm", "-rf", "/"])
        #expect(
            CLIScopeRunner.arguments(from: "status $(whoami)") == ["status", "$(whoami)"])
        #expect(CLIScopeRunner.arguments(from: "a && b") == ["a", "&&", "b"])
        #expect(CLIScopeRunner.arguments(from: "a | b") == ["a", "|", "b"])
    }

    @Test("An empty line runs the tool with no arguments")
    func emptyLineIsNoArguments() {
        #expect(CLIScopeRunner.arguments(from: "").isEmpty)
        #expect(CLIScopeRunner.arguments(from: "   ").isEmpty)
    }

    @Test("A tool that is not installed is reported, not run")
    func missingToolIsReported() async {
        let output = await CLIScopeRunner.run(
            command: "definitely-not-a-real-tool-9f3a", line: "status")

        #expect(output.failed)
        #expect(output.text.contains("not installed"))
    }

    @Test("A real tool runs and its output comes back")
    func runsAnInstalledTool() async {
        // `echo` exists on every Mac, which is what makes this safe to assert on.
        let output = await CLIScopeRunner.run(command: "echo", line: "hello")

        #expect(output.failed == false)
        #expect(output.text.contains("hello"))
        #expect(output.command == "echo hello")
    }
}
