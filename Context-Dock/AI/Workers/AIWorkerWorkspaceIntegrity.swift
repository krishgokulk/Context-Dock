// AIWorkerWorkspaceIntegrity.swift
// Context-Dock
//
// Whether a worker authorized read-only actually left the workspace alone.
//
// Every task `AIWorkerTask.bounded` builds sets `allowsWrites: false` — a delegation to
// investigate must not come back having changed anything, which is the whole point of an
// authority envelope rather than a polite request in the prompt. A worker's own report is
// not proof of that any more than it is proof of anything else it claims, so this checks the
// one thing that matters independently of the report's wording: did the workspace's git
// state move while the worker was running. Read-only, unattended, and not a capability — this
// is DoraX checking its own promise, not something the user asked to run.

import Foundation

enum AIWorkerWorkspaceIntegrity {

    struct Snapshot: Equatable {
        /// The repository's current commit, or nil when `path` is not (or is no longer) a
        /// git repository — nothing to compare, not evidence either way.
        let head: String?
        /// `git status --porcelain`; empty string means a clean tree. Nil alongside `head`.
        let status: String?

        static let unavailable = Snapshot(head: nil, status: nil)
    }

    struct Verdict: Equatable {
        let before: Snapshot
        let after: Snapshot

        /// True when nothing detectably moved, or when there was nothing to check at all —
        /// a workspace that was never a git repository makes no promise this can verify.
        var held: Bool {
            before.head == after.head && before.status == after.status
        }

        /// One line for the user, present only when something actually moved.
        var note: String? {
            guard !held else { return nil }
            if before.head != after.head {
                return "The workspace's git HEAD moved while a read-only specialist was "
                    + "working on it (\(before.head ?? "unknown") → \(after.head ?? "unknown"))."
            }
            return "The workspace picked up uncommitted changes while a read-only "
                + "specialist was working on it."
        }
    }

    /// A snapshot of `path`'s git state, taken synchronously and unattended.
    static func snapshot(of path: URL?) -> Snapshot {
        guard let path else { return .unavailable }
        return Snapshot(
            head: runGit(["rev-parse", "HEAD"], in: path),
            status: runGit(["status", "--porcelain"], in: path))
    }

    /// `nil` on any failure — not installed, not a repository, denied — which this treats the
    /// same as "nothing to compare" rather than as a change. A missing reading must never be
    /// read as a contradiction; that would flag every non-git workspace as tampered with.
    private static func runGit(_ arguments: [String], in directory: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
