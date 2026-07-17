//
//  AdapterSkillSeeder.swift
//  Context-Dock
//
//  Seeds a starter Skill into every app adapter so scoped chat behaves like a
//  trained assistant for that app, and so users see by example how Skills work
//  (Settings → App Adapters → Tools → Skills). Skills are instructions only —
//  they never execute anything themselves.
//
//  Seeds once per bundle id (UserDefaults set); deleting a seeded skill does
//  not bring it back. Users can edit any seeded skill freely.
//

import Foundation

@MainActor
enum AdapterSkillSeeder {

    private static let seededKey = "adapterSkillsSeededBundles.v2"
    private static var didRunThisLaunch = false

    static func seedIfNeeded() {
        guard !didRunThisLaunch else { return }
        didRunThisLaunch = true

        var seeded = Set(UserDefaults.standard.stringArray(forKey: seededKey) ?? [])
        var changed = false

        for adapter in AppAdapterManager.shared.adapters {
            let bundleId = adapter.bundleId
            guard !bundleId.isEmpty,
                !bundleId.hasPrefix("scope://"),
                !seeded.contains(bundleId)
            else { continue }

            let existingIDs = Set(SkillStore.shared.skills(for: bundleId).map(\.id))
            for skill in starterSkills(for: adapter) where !existingIDs.contains(skill.id) {
                SkillStore.shared.upsert(skill)
            }
            seeded.insert(bundleId)
            changed = true
        }

        if changed {
            UserDefaults.standard.set(Array(seeded).sorted(), forKey: seededKey)
        }

        migrateSeededBasicsSkills()
    }

    /// v1.0 → v1.1: seeded "Assistant Basics" skills gain the app-awareness rule
    /// (never claim you can't see which app is open). Only touches untouched
    /// seeded skills — user-edited versions keep their edits.
    private static func migrateSeededBasicsSkills() {
        for skill in SkillStore.shared.skills
        where skill.id.hasPrefix("seed.") && skill.id.hasSuffix(".basics") && skill.version == "1.0" {
            guard let adapter = AppAdapterManager.shared.adapters.first(where: {
                $0.bundleId == skill.adapterBundleId
            }) else { continue }
            var updated = skill
            updated.version = "1.1"
            updated.instructions = basicsInstructions(appName: adapter.appName)
            SkillStore.shared.upsert(updated)
        }
    }

    static func basicsInstructions(appName: String) -> String {
        """
        You are assisting inside \(appName) — you always know this is the app in use; \
        never say you cannot see which app is open. Ground every answer in the live \
        app context (window title, selection, current document/page) before answering. \
        Prefer this adapter's linked CLI tools, MCP tools and actions over generic advice — \
        choose the single best tool for the request. When you run a command, state what \
        it does in one short sentence first. If no linked tool fits, say what you CAN do \
        and suggest linking one in Settings → App Adapters → \(appName).
        """
    }

    // MARK: - Skill content

    private static func starterSkills(for adapter: AppAdapter) -> [AdapterSkill] {
        var skills: [AdapterSkill] = []

        // Curated, high-value workflow skills for known apps / linked tools.
        if let curated = curatedSkill(for: adapter) {
            skills.append(curated)
        }

        // Media download workflow whenever yt-dlp is linked to this adapter
        // (YouTube / YT Music web apps, browsers, …).
        let hasYtDlp = TerminalPackageManager.shared.packages.contains {
            $0.command == "yt-dlp" && $0.contextAppBundleIds.contains(adapter.bundleId)
        }
        if hasYtDlp {
            skills.append(AdapterSkill(
                id: "seed.\(adapter.bundleId).media-download",
                adapterBundleId: adapter.bundleId,
                name: "Media Download Workflow",
                summary: "How to download video/audio with yt-dlp from the current page",
                instructions: """
                When the user asks to download the current video or its audio:
                1. Take the CURRENT PAGE URL from the context verbatim — never a placeholder, \
                never a made-up URL. If no URL is in context, ask the user to open the video first.
                2. Audio only: CMD: yt-dlp -f bestaudio --extract-audio --audio-format mp3 -P ~/Downloads "<the exact URL>"
                3. Video: CMD: yt-dlp -f "bv*+ba/b" -P ~/Downloads "<the exact URL>"
                4. Always pass -P ~/Downloads so results land in the Downloads folder.
                5. After the command finishes, tell the user the file name and that it is in \
                Downloads (a notification badge also appears in the launcher).
                Playlists: add --no-playlist unless the user explicitly asks for the whole playlist.
                """
            ))
        }

        // Generic starter — every adapter gets at least one skill so the feature
        // is visible and editable as an example.
        if skills.isEmpty {
            skills.append(AdapterSkill(
                id: "seed.\(adapter.bundleId).basics",
                adapterBundleId: adapter.bundleId,
                name: "\(adapter.appName) Assistant Basics",
                summary: "Starter skill — edit me to teach the AI your workflow",
                instructions: basicsInstructions(appName: adapter.appName),
                version: "1.1"
            ))
        }

        return skills
    }

    private static func curatedSkill(for adapter: AppAdapter) -> AdapterSkill? {
        let make: (String, String, String) -> AdapterSkill = { name, summary, body in
            AdapterSkill(
                id: "seed.\(adapter.bundleId).workflow",
                adapterBundleId: adapter.bundleId,
                name: name, summary: summary, instructions: body
            )
        }
        switch adapter.bundleId {
        case "com.openai.codex":
            return make(
                "Codex Workspace Workflow",
                "Use Codex CLI only for workspace and coding tasks",
                """
                Use the linked codex CLI for repository or coding work, not to infer the visible \
                ChatGPT conversation. Before running it, require a workspace path from live context \
                or the user. For questions about the current ChatGPT window, use Accessibility context \
                and state honestly when the conversation contents are unavailable. Never treat the app \
                window title as proof of the user's current task.
                """
            )
        case "com.anthropic.claudefordesktop":
            return make(
                "Claude Desktop and Code Workflow",
                "Separate desktop context from Claude Code execution",
                """
                Use Claude Desktop live Accessibility context for questions about the visible chat. \
                Use the linked claude CLI only for explicit code, repository, session, or prompt tasks. \
                Prefer non-interactive `claude -p` for a bounded query and preserve Claude Code's own \
                permission checks. A linked CLI does not grant access to Claude Desktop chat history.
                """
            )
        case "com.apple.dt.Xcode":
            return make(
                "Xcode Build and Test Workflow",
                "Inspect the project before invoking Xcode tools",
                """
                Use live Xcode context for the selected file, editor and issue text. Use xed only to \
                open or reveal files. Use xcodebuild for build/test/archive requests after identifying \
                the project or workspace and scheme; never guess them. Use xcrun for simulator/device \
                tools. Read-only git status, log and diff are safe; commits, pushes and destructive \
                repository operations require explicit approval.
                """
            )
        case "com.apple.Notes", "com.apple.iCal", "com.apple.AddressBook", "com.apple.reminders":
            return make(
                "Apple App Native Workflow",
                "Prefer Context Dock's built-in Apple data tools",
                """
                This Apple app ships with native Context Dock capabilities. Prefer the built-in \
                app reader and typed Apple data actions over shell commands or third-party MCP \
                servers. Reads may run directly. Creating, editing, sending or deleting data must \
                show a clear approval proposal first. Use linked Shortcuts only when the user has \
                explicitly configured one for a workflow the native tools do not cover.
                """
            )
        case "io.tailscale.ipn.macsys", "io.tailscale.ipn.macos":
            return make(
                "Tailnet Diagnosis Flow",
                "Read state before proposing changes",
                """
                For any connectivity question, read state first: CMD: tailscale status, then \
                CMD: tailscale ip. For "why can't I reach X": tailscale ping <peer> and \
                tailscale netcheck before proposing changes. State-changing commands \
                (up, down, set, logout) always need explicit user approval — propose, don't run.
                """
            )
        case "md.obsidian":
            return make(
                "Vault Workflow",
                "Prefer obs CLI and obsidian:// URIs",
                """
                To create or open notes prefer the obs CLI when installed \
                (obs open "<note>", obs search "<term>", obs create "<name>"). Without the CLI, \
                use obsidian:// URIs: obsidian://new?name=<title> and obsidian://search?query=<term>. \
                Note titles with spaces must be URL-encoded in URIs. Never edit vault files \
                directly on disk unless the user explicitly asks.
                """
            )
        case "com.github.GitHubClient":
            return make(
                "GitHub CLI Workflow",
                "Issues, PRs and repo state via gh",
                """
                Use gh for everything: gh issue list / gh pr list --repo <owner/repo>, \
                gh pr view <n> --comments, gh run list for CI. Detect the repo from context \
                when possible; otherwise ask. Creating or commenting on issues/PRs needs \
                explicit user approval — show the exact command first.
                """
            )
        case "com.microsoft.VSCode":
            return make(
                "VS Code Launch Workflow",
                "Open files, folders, diffs via code CLI",
                """
                Use the code CLI: code <path> to open, code -g <file>:<line> to jump to a line, \
                code -d <a> <b> for diffs, code -n for a new window. When the user mentions \
                a file from context (selection, Finder), pass its full path.
                """
            )
        case "com.spotify.client":
            return make(
                "Playback Control",
                "Control Spotify via AppleScript",
                """
                Control playback with AppleScript through osascript: \
                'tell application "Spotify" to playpause / next track / previous track'. \
                Read the current song with 'tell application "Spotify" to name of current track \
                & " — " & artist of current track'. For search/browse, open spotify: URIs.
                """
            )
        case "com.electron.ollama":
            return make(
                "Local Models Workflow",
                "Manage and run local LLMs via ollama CLI",
                """
                Use the ollama CLI: ollama list to show installed models, ollama pull <model> \
                to fetch, ollama run <model> "<prompt>" for a one-shot answer, ollama ps for \
                loaded models. Model pulls can be gigabytes — mention size before pulling.
                """
            )
        default:
            return nil
        }
    }
}
