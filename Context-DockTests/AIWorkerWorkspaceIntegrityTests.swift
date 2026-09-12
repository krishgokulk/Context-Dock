// AIWorkerWorkspaceIntegrityTests.swift
// Context-DockTests
//
// Todo 6 of docs/superpowers/plans/2026-09-10-agentic-capability-parity.md — and the
// unfinished half of docs/superpowers/plans/2026-09-06-specialist-worker-layer.md's own
// Task 6 ("status vocabulary done; read-backs pending"). Every worker task built by
// `AIWorkerTask.bounded` promises `allowsWrites: false`. Nothing ever checked that promise
// against the machine — `AIWorkerVerification.assess` was always called with `readings: []`,
// so a worker's report was believed exactly as far as `.executorConfirmed`, whatever it
// actually did to the workspace.
//
// These run against a real git repository created and destroyed per test — an actual
// process invocation, not a mock, because the thing worth proving is that `git` is really
// being asked and its real answer is really being compared.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Worker workspace integrity")
struct AIWorkerWorkspaceIntegrityTests {

    /// A throwaway git repository with one commit, torn down after the test.
    private func repo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWorkerWorkspaceIntegrityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("git", ["init", "-q"], in: dir)
        try run("git", ["config", "user.email", "test@example.com"], in: dir)
        try run("git", ["config", "user.name", "Test"], in: dir)
        try "hello".write(
            to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try run("git", ["add", "."], in: dir)
        try run("git", ["commit", "-q", "-m", "first"], in: dir)
        return dir
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], in directory: URL) throws
        -> String
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Snapshotting a real repository

    @Test("A clean repository snapshots as clean, with a real commit hash")
    func cleanRepositorySnapshotsClean() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = AIWorkerWorkspaceIntegrity.snapshot(of: dir)
        #expect(snapshot.status == "")
        #expect(snapshot.head?.isEmpty == false)
        // A real commit hash, not a placeholder — this is what proves the check actually
        // asked git rather than returning something hardcoded.
        #expect(snapshot.head?.count == 40)
    }

    @Test("A path that is not a git repository snapshots as unavailable, not as tampered with")
    func nonGitPathSnapshotsAsUnavailable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = AIWorkerWorkspaceIntegrity.snapshot(of: dir)
        #expect(snapshot.head == nil)
        #expect(snapshot.status == nil)
    }

    @Test("No path at all is unavailable, never a false alarm")
    func noPathIsUnavailable() {
        let snapshot = AIWorkerWorkspaceIntegrity.snapshot(of: nil)
        #expect(snapshot == .unavailable)
    }

    // MARK: - The verdict a real before/after pair produces

    @Test("Nothing touched the workspace: the verdict holds and says nothing")
    func anUntouchedWorkspaceHolds() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let before = AIWorkerWorkspaceIntegrity.snapshot(of: dir)
        let after = AIWorkerWorkspaceIntegrity.snapshot(of: dir)
        let verdict = AIWorkerWorkspaceIntegrity.Verdict(before: before, after: after)

        #expect(verdict.held)
        #expect(verdict.note == nil)
    }

    @Test("A file the worker was told not to write to appearing dirty breaks the verdict")
    func anUncommittedChangeBreaksTheVerdict() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let before = AIWorkerWorkspaceIntegrity.snapshot(of: dir)
        // Exactly what a worker that ignored allowsWrites:false would leave behind.
        try "a write that should never have happened".write(
            to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let after = AIWorkerWorkspaceIntegrity.snapshot(of: dir)

        let verdict = AIWorkerWorkspaceIntegrity.Verdict(before: before, after: after)
        #expect(!verdict.held)
        #expect(verdict.note?.contains("uncommitted changes") == true)
    }

    @Test("A commit the worker made moves HEAD, and the verdict names both commits")
    func aCommitBreaksTheVerdict() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let before = AIWorkerWorkspaceIntegrity.snapshot(of: dir)
        try "second version".write(
            to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try run("git", ["commit", "-q", "-am", "a write a read-only worker should not make"],
            in: dir)
        let after = AIWorkerWorkspaceIntegrity.snapshot(of: dir)

        let verdict = AIWorkerWorkspaceIntegrity.Verdict(before: before, after: after)
        #expect(!verdict.held)
        #expect(verdict.note?.contains("HEAD moved") == true)
        #expect(verdict.note?.contains(before.head ?? "before-missing") == true)
        #expect(verdict.note?.contains(after.head ?? "after-missing") == true)
    }

    @Test("A workspace that was never a git repository verifies nothing, rather than failing")
    func nonGitWorkspaceNeverFailsTheVerdict() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A worker could still write files here even without git tracking them — this only
        // asserts what the check itself promises: it does not invent a false contradiction
        // out of a path it was never able to read git state from in the first place.
        let before = AIWorkerWorkspaceIntegrity.snapshot(of: dir)
        let after = AIWorkerWorkspaceIntegrity.snapshot(of: dir)
        let verdict = AIWorkerWorkspaceIntegrity.Verdict(before: before, after: after)
        #expect(verdict.held)
    }

    // MARK: - Wired into AIWorkerVerification.assess

    @Test("A broken workspace promise overrides an otherwise unremarkable report")
    func assessOverridesOnABrokenPromise() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let task = try #require(
            AIWorkerTask.bounded(
                goal: "investigate the repository for TODO comments",
                scope: .folder(path: dir.path),
                appName: nil,
                workspace: dir))

        let before = AIWorkerWorkspaceIntegrity.snapshot(of: dir)
        try "an unrequested write".write(
            to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let after = AIWorkerWorkspaceIntegrity.snapshot(of: dir)

        let outcome = AIWorkerVerification.assess(
            report: "Found no TODO comments in the repository.",
            task: task,
            readings: [],
            workspaceIntegrity: .init(before: before, after: after))

        // A report that reads as complete and correct on its own is still overridden — the
        // whole point of checking the machine rather than trusting the words.
        #expect(outcome.status == .unverified)
        #expect(outcome.note.contains("uncommitted changes"))
        #expect(!outcome.receipt.success)
    }

    @Test("A kept promise leaves the ordinary readings-based assessment untouched")
    func assessIsUnaffectedWhenThePromiseHolds() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let task = try #require(
            AIWorkerTask.bounded(
                goal: "investigate the repository for TODO comments",
                scope: .folder(path: dir.path),
                appName: nil,
                workspace: dir))

        let snapshot = AIWorkerWorkspaceIntegrity.snapshot(of: dir)
        let outcome = AIWorkerVerification.assess(
            report: "Found no TODO comments in the repository.",
            task: task,
            readings: [],
            workspaceIntegrity: .init(before: snapshot, after: snapshot))

        // Falls through to the existing, already-tested "nothing was read back" path —
        // this proves the new parameter is additive rather than a second, divergent rule.
        #expect(outcome.status == .executorConfirmed)
    }

    @Test("Omitting the check entirely behaves exactly as it always did")
    func omittingIntegrityChecksIsUnchanged() throws {
        let task = try #require(
            AIWorkerTask.bounded(
                goal: "investigate the repository for TODO comments",
                scope: .general,
                appName: nil,
                workspace: nil))

        let outcome = AIWorkerVerification.assess(
            report: "Found nothing notable.", task: task, readings: [])
        #expect(outcome.status == .executorConfirmed)
    }
}
