// Context-DockTests/PluginScriptRunnerTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginScriptRunnerTests {
    private let runner = PluginScriptRunner()

    @Test func bashPrintsAndTheOutputComesBackTrimmed() async throws {
        let result = await runner.run(
            type: .bash, script: "echo hello", env: [:], timeout: 5, workingDirectory: nil)
        switch result {
        case .failure(let failure): Issue.record("failed: \(failure.message)")
        case .success(let run):
            #expect(run.stdout == "hello")
            #expect(run.exitCode == 0)
        }
    }

    @Test func theEnvironmentReachesTheScript() async throws {
        let result = await runner.run(
            type: .bash, script: "echo \"$CD_QUERY\"", env: ["CD_QUERY": "ports"],
            timeout: 5, workingDirectory: nil)
        #expect(try result.get().stdout == "ports")
    }

    @Test func theProcessEnvironmentSurvivesTheMerge() async throws {
        // A script calls `git`, `jq`, `lsof`. Replacing the environment instead of merging
        // over it empties PATH and every one of those stops resolving.
        let result = await runner.run(
            type: .bash, script: "echo \"$PATH\"", env: ["CD_QUERY": "x"],
            timeout: 5, workingDirectory: nil)
        #expect(try result.get().stdout.isEmpty == false)
    }

    @Test func aNonZeroExitIsAFailureCarryingStderr() async {
        let result = await runner.run(
            type: .bash, script: "echo boom >&2; exit 3", env: [:], timeout: 5,
            workingDirectory: nil)
        switch result {
        case .success: Issue.record("a failing script reported success")
        case .failure(let failure):
            #expect(failure.kind == .exit)
            #expect(failure.message.contains("boom"))
        }
    }

    @Test func aScriptThatHangsIsKilledAtItsTimeout() async {
        let started = Date()
        let result = await runner.run(
            type: .bash, script: "sleep 30", env: [:], timeout: 1, workingDirectory: nil)
        switch result {
        case .success: Issue.record("a hanging script was allowed to finish")
        case .failure(let failure):
            #expect(failure.kind == .timeout)
            // The point of the timeout is that the caller is not held for 30 seconds.
            #expect(Date().timeIntervalSince(started) < 10)
        }
    }

    @Test func anHttpCallToAnUndeclaredHostNeverLeavesTheProcess() async throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(#"{ "id": "x", "name": "X" }"#.utf8))
        let result = await runner.run(
            http: "https://example.com/data.json", manifest: manifest, timeout: 5)
        switch result {
        case .success: Issue.record("an undeclared host was reached")
        case .failure(let failure): #expect(failure.kind == .blocked)
        }
    }
}
