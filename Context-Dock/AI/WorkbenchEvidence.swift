// WorkbenchEvidence.swift
// Context-Dock
//
// What the last build and the last capture actually showed, so the coding agent can be
// told instead of asked.
//
// The loop this closes is the one the user runs by hand thirty times a day: build, launch,
// look, screenshot, switch back to the agent, attach the image, retype what is wrong. Every
// step after "look" is transcription. DoraX already ran the build and took the capture — it
// has the failure text and the file path — so handing them over is a matter of not
// throwing them away between capabilities.
//
// The one rule that makes this safe to trust: **evidence expires.** A screenshot from forty
// minutes ago is not what the app looks like now, and presenting it as current would have
// the agent fixing a bug that was fixed two builds back. Anything past the window is
// dropped rather than labelled, because a caveat in a prompt is not a thing a model
// reliably honours.

import AppKit
import Foundation
import OSLog

@MainActor
final class WorkbenchEvidence {
    static let shared = WorkbenchEvidence()

    private init() {}

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "Workbench")

    /// How long a piece of evidence describes the present. Past this it is history, and
    /// history handed over as the current state is worse than nothing.
    private static let freshness: TimeInterval = 10 * 60

    struct BuildFailure {
        let source: String
        let output: String
        let at: Date
    }

    struct Capture {
        let url: URL
        let at: Date
    }

    private var failures: [String: BuildFailure] = [:]
    private var captures: [String: Capture] = [:]
    /// Captures taken with no project in front. A screenshot of the app under test is often
    /// taken while that app — not the editor — is frontmost, so it cannot be filed under a
    /// project at the moment it happens.
    private var looseCapture: Capture?

    // MARK: - Recording

    func recordBuildFailure(projectRoot: String, source: String, output: String) {
        failures[projectRoot] = BuildFailure(source: source, output: output, at: Date())
        Self.log.notice("build failed in \(projectRoot, privacy: .public)")
    }

    /// A build that passes clears the failure it replaces. Leaving it would let a stale
    /// error be handed over as the reason a later, unrelated step went wrong.
    func recordBuildSuccess(projectRoot: String) {
        failures[projectRoot] = nil
    }

    func recordCapture(_ url: URL) {
        let capture = Capture(url: url, at: Date())
        looseCapture = capture
        if let root = ProjectContextResolver.shared.frontmostProjectRoot() {
            captures[root] = capture
        }
    }

    // MARK: - Reading

    private static func fresh<T>(_ value: T?, at: (T) -> Date) -> T? {
        guard let value, Date().timeIntervalSince(at(value)) < freshness else { return nil }
        return value
    }

    func buildFailure(for projectRoot: String) -> BuildFailure? {
        Self.fresh(failures[projectRoot], at: \.at)
    }

    /// The capture that belongs to this project, or the most recent loose one. The fallback
    /// matters: capturing the app under test happens while that app is frontmost, so the
    /// shot the user means is frequently filed under no project at all.
    func capture(for projectRoot: String) -> Capture? {
        Self.fresh(captures[projectRoot], at: \.at) ?? Self.fresh(looseCapture, at: \.at)
    }
}

// MARK: - Handing it over

/// Composes what DoraX observed into a brief for the coding agent, and sends it.
///
/// DoraX does not write code. It carries what it saw to the thing that does — which is the
/// whole division of labour here, and the reason this returns the agent's answer rather
/// than acting on it.
@MainActor
enum AgentHandoff {

    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "Workbench")

    struct Brief {
        let text: String
        let attachments: [URL]
        /// What went in, for the receipt — the user should be able to see what was sent on
        /// their behalf without reading the prompt.
        let included: [String]
    }

    /// Assembles the evidence for `projectRoot` around the user's own observation.
    static func brief(observation: String, projectRoot: String) async -> Brief {
        var sections: [String] = []
        var attachments: [URL] = []
        var included: [String] = []

        sections.append("What I'm seeing:\n\(observation)")

        if let failure = WorkbenchEvidence.shared.buildFailure(for: projectRoot) {
            sections.append(
                "The last build failed (\(failure.source)):\n```\n\(failure.output)\n```")
            included.append("build failure")
        }

        if let capture = WorkbenchEvidence.shared.capture(for: projectRoot),
            FileManager.default.fileExists(atPath: capture.url.path)
        {
            attachments.append(capture.url)
            sections.append("A screenshot of the running app is attached.")
            included.append("screenshot")
        }

        if let changes = await changedFiles(at: projectRoot) {
            sections.append("Uncommitted changes right now:\n```\n\(changes)\n```")
            included.append("working tree")
        }

        return Brief(
            text: sections.joined(separator: "\n\n"),
            attachments: attachments,
            included: included)
    }

    /// Sends the brief to Claude Code and returns what it said.
    static func send(observation: String, scope: GeneralChatScope) async -> ClaudeCodeBridge
        .Result?
    {
        guard let root = ProjectContextResolver.shared.frontmostProjectRoot() else {
            return nil
        }
        let brief = await brief(observation: observation, projectRoot: root)
        log.notice("handing over: \(brief.included.joined(separator: ", "), privacy: .public)")
        return await ClaudeCodeBridge.shared.ask(
            query: brief.text, scope: scope, attachments: brief.attachments)
    }

    /// The working tree as it stands. Names and a diffstat only — the agent reads the files
    /// itself, and pasting whole diffs into the prompt would crowd out the screenshot.
    private static func changedFiles(at root: String) async -> String? {
        let quoted = "'" + root.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let result = await TerminalCommandExecutor.shared.run(
            "cd \(quoted) && git status --short && git diff --stat",
            purpose: "Read the working tree for the coding agent")
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.success, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
