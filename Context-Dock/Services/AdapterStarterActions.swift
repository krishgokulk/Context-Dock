//
//  AdapterStarterActions.swift
//  Context-Dock
//
//  Starter actions seeded into app adapters so no adapter ever shows
//  "No actions yet". Curated per known bundle id; every other app gets
//  a generic AI-prompt action. Users can edit or delete them like any
//  custom action — deleted starters are not re-seeded (tracked in
//  UserDefaults by bundle id).
//

import Foundation

enum AdapterStarterActions {

    /// Bump when bundled packs gain actions. Existing adapters then receive the
    /// new pack once, while later user deletions remain respected.
    private static let catalogVersion = 3
    private static var seededKey: String { "adapterStarterActionsSeededBundles.v\(catalogVersion)" }

    /// Bundle ids that have already been seeded once — never re-seed these,
    /// so a user deleting the starter action doesn't get it back on relaunch.
    static func alreadySeeded(_ bundleId: String) -> Bool {
        let seeded = UserDefaults.standard.stringArray(forKey: seededKey) ?? []
        return seeded.contains(bundleId)
    }

    static func markSeeded(_ bundleId: String) {
        var seeded = UserDefaults.standard.stringArray(forKey: seededKey) ?? []
        guard !seeded.contains(bundleId) else { return }
        seeded.append(bundleId)
        UserDefaults.standard.set(seeded, forKey: seededKey)
    }

    /// The starter actions for an app — curated when we know the app, generic otherwise.
    /// Always returns at least one action.
    static func starters(for bundleId: String, appName: String) -> [AdapterAction] {
        var curated = curatedActions(for: bundleId)
        // Web apps (YouTube, YT Music…) get a per-install Safari WebApp bundle id, so
        // match those by name.
        if curated.isEmpty { curated = curatedActionsByAppName(appName) }
        return curated.isEmpty ? [genericAssistAction(appName: appName)] : curated
    }

    /// Curated starters for apps whose bundle id isn't stable (Safari web apps).
    private static func curatedActionsByAppName(_ appName: String) -> [AdapterAction] {
        switch appName.lowercased() {
        case "youtube", "yt music", "youtube music":
            return youTubeStarters()
        default:
            return []
        }
    }

    /// YouTube (web app) — summarize the current video with AI, and grab the video or
    /// audio with yt-dlp. Showcases three action types: an AI prompt over live page
    /// content, and two approved shell commands driving a CLI tool.
    private static func youTubeStarters() -> [AdapterAction] {
        [
            AdapterAction(
                id: "starter.youtube.summarize",
                name: "Summarize Video",
                icon: "text.append",
                description: "Summarize the current video from the live page (speakers, topics, key points)",
                triggers: ["summarize", "summary", "tldr", "recap"],
                type: .aiPrompt,
                aiPromptTemplate:
                    "Summarize the current YouTube video \"$WINDOW_TITLE\" ($CURRENT_URL) using the "
                    + "live page content. Give the speakers, key topics, and a short takeaway.",
                accentColor: "red"
            ),
            AdapterAction(
                id: "starter.youtube.download",
                name: "Download Video (yt-dlp)",
                icon: "arrow.down.circle",
                description: "Download the current video to ~/Downloads with yt-dlp",
                triggers: ["download", "save", "video", "ytdlp"],
                type: .shell,
                script:
                    "yt-dlp -o '~/Downloads/%(title)s.%(ext)s' \"$CURRENT_URL\"",
                requiresApproval: true,
                accentColor: "red"
            ),
            AdapterAction(
                id: "starter.youtube.downloadAudio",
                name: "Download Audio (MP3)",
                icon: "music.note",
                description: "Extract audio from the current video as MP3 with yt-dlp",
                triggers: ["audio", "mp3", "music", "song"],
                type: .shell,
                script:
                    "yt-dlp -x --audio-format mp3 -o '~/Downloads/%(title)s.%(ext)s' \"$CURRENT_URL\"",
                requiresApproval: true,
                accentColor: "red"
            ),
        ]
    }

    static func missingStarters(for adapter: AppAdapter) -> [AdapterAction] {
        let existingIDs = Set(adapter.actions.map(\.id))
        return starters(for: adapter.bundleId, appName: adapter.appName)
            .filter { !existingIDs.contains($0.id) }
    }

    // MARK: - Generic fallback

    /// Works for any app: pre-fills AI chat with the app + window + selection context.
    private static func genericAssistAction(appName: String) -> AdapterAction {
        AdapterAction(
            id: "starter.ai.assist",
            name: "Ask AI about \(appName)",
            icon: "sparkles",
            description: "Open AI chat with the current \(appName) window and selection as context",
            triggers: ["ask", "ai", "help"],
            type: .aiPrompt,
            aiPromptTemplate: "I'm working in $APP_NAME (window: \"$WINDOW_TITLE\"). "
                + "Selected text: \"$AX_SELECTED_TEXT\". Help me with: {{query}}",
            accentColor: "purple"
        )
    }

    // MARK: - Curated catalog

    private static func curatedActions(for bundleId: String) -> [AdapterAction] {
        switch bundleId {
        case "com.apple.iCal":
            return [
                AdapterAction(
                    id: "starter.calendar.newEvent",
                    name: "New Event",
                    icon: "calendar.badge.plus",
                    description: "Create a new calendar event",
                    triggers: ["new", "event", "create"],
                    type: .menubar,
                    menuPath: ["File", "New Event"],
                    accentColor: "red"
                ),
                AdapterAction(
                    id: "starter.calendar.today",
                    name: "Go to Today",
                    icon: "calendar.circle",
                    description: "Jump the calendar view to today",
                    triggers: ["today", "now"],
                    type: .menubar,
                    menuPath: ["View", "Go to Today"],
                    accentColor: "red"
                ),
            ]
        case "com.apple.AddressBook":
            return [
                AdapterAction(
                    id: "starter.contacts.newCard",
                    name: "New Contact",
                    icon: "person.crop.circle.badge.plus",
                    description: "Create a new contact card",
                    triggers: ["new", "contact", "card"],
                    type: .menubar,
                    menuPath: ["File", "New Card"],
                    accentColor: "brown"
                )
            ]
        case "com.apple.reminders":
            return [
                AdapterAction(
                    id: "starter.reminders.new",
                    name: "New Reminder",
                    icon: "plus.circle",
                    description: "Create a new reminder",
                    triggers: ["new", "reminder", "todo"],
                    type: .menubar,
                    menuPath: ["File", "New Reminder"],
                    accentColor: "orange"
                )
            ]
        case "com.apple.Notes":
            return [
                AdapterAction(
                    id: "starter.notes.new",
                    name: "New Note",
                    icon: "square.and.pencil",
                    description: "Create a new note",
                    triggers: ["new", "note"],
                    type: .menubar,
                    menuPath: ["File", "New Note"],
                    accentColor: "yellow"
                )
            ]
        case "com.apple.mail":
            return [
                AdapterAction(
                    id: "starter.mail.newMessage", name: "New Message",
                    icon: "square.and.pencil", description: "Compose a new email",
                    triggers: ["new", "compose", "email", "mail"], type: .menubar,
                    menuPath: ["File", "New Message"], accentColor: "blue"
                ),
                AdapterAction(
                    id: "starter.mail.check", name: "Get New Mail",
                    icon: "arrow.clockwise", description: "Check all accounts for new mail",
                    triggers: ["check", "refresh", "new mail"], type: .menubar,
                    menuPath: ["Mailbox", "Get All New Mail"], accentColor: "blue"
                ),
            ]
        case "com.apple.MobileSMS":
            return [
                AdapterAction(
                    id: "starter.messages.new", name: "New Message",
                    icon: "square.and.pencil", description: "Start a new conversation",
                    triggers: ["new", "message", "compose"], type: .menubar,
                    menuPath: ["File", "New Message"], accentColor: "green"
                )
            ]
        case "com.apple.Maps":
            return [
                AdapterAction(
                    id: "starter.maps.search", name: "Search Maps",
                    icon: "map", description: "Search Apple Maps",
                    triggers: ["map", "search", "place", "directions"], type: .urlScheme,
                    urlScheme: "https://maps.apple.com/?q={{query}}", accentColor: "green"
                )
            ]
        case "com.apple.Safari":
            return [
                AdapterAction(
                    id: "starter.safari.newTab", name: "New Tab",
                    icon: "plus.square", description: "Open a new Safari tab",
                    triggers: ["new", "tab"], type: .menubar,
                    menuPath: ["File", "New Tab"], accentColor: "blue"
                ),
                AdapterAction(
                    id: "starter.safari.reader", name: "Show Reader",
                    icon: "doc.plaintext", description: "Show Reader for the current page",
                    triggers: ["reader", "read", "article"], type: .menubar,
                    menuPath: ["View", "Show Reader"], accentColor: "blue"
                ),
            ]
        case "com.apple.Preview":
            return [
                AdapterAction(
                    id: "starter.preview.inspector", name: "Show Inspector",
                    icon: "info.circle", description: "Show information for the open document",
                    triggers: ["info", "inspector", "metadata"], type: .menubar,
                    menuPath: ["Tools", "Show Inspector"], accentColor: "blue"
                )
            ]
        case "com.apple.TextEdit":
            return [
                AdapterAction(
                    id: "starter.textedit.new", name: "New Document",
                    icon: "doc.badge.plus", description: "Create a new text document",
                    triggers: ["new", "document", "text"], type: .menubar,
                    menuPath: ["File", "New"], accentColor: "gray"
                )
            ]
        case "com.apple.dt.Xcode":
            return [
                AdapterAction(
                    id: "starter.xcode.build", name: "Build",
                    icon: "hammer", description: "Build the active Xcode scheme",
                    triggers: ["build", "compile"], type: .menubar,
                    menuPath: ["Product", "Build"], accentColor: "blue"
                ),
                AdapterAction(
                    id: "starter.xcode.test", name: "Test",
                    icon: "checkmark.diamond", description: "Test the active Xcode scheme",
                    triggers: ["test", "tests"], type: .menubar,
                    menuPath: ["Product", "Test"], accentColor: "blue"
                ),
                AdapterAction(
                    id: "starter.xcode.run", name: "Run",
                    icon: "play", description: "Run the active Xcode scheme",
                    triggers: ["run", "launch"], type: .menubar,
                    menuPath: ["Product", "Run"], accentColor: "green"
                ),
            ]
        case "com.apple.Automator":
            return [
                AdapterAction(
                    id: "starter.automator.new",
                    name: "New Workflow",
                    icon: "gearshape.2",
                    description: "Start a new Automator workflow",
                    triggers: ["new", "workflow"],
                    type: .menubar,
                    menuPath: ["File", "New"],
                    accentColor: "gray"
                )
            ]
        case "com.apple.DiskUtility":
            return [
                AdapterAction(
                    id: "starter.diskutility.freespace",
                    name: "Check Free Disk Space",
                    icon: "internaldrive",
                    description: "Show free space on the startup disk",
                    triggers: ["free", "space", "disk"],
                    type: .shell,
                    script: "df -h / | tail -1 | awk '{print \"Free: \" $4 \" of \" $2 \" (\" $5 \" used)\"}'",
                    accentColor: "blue"
                )
            ]
        case "com.microsoft.VSCode":
            return [
                AdapterAction(
                    id: "starter.vscode.newWindow",
                    name: "New Window",
                    icon: "macwindow.badge.plus",
                    description: "Open a new VS Code window",
                    triggers: ["new", "window"],
                    type: .menubar,
                    menuPath: ["File", "New Window"],
                    accentColor: "blue"
                ),
                AdapterAction(
                    id: "starter.vscode.mcpDocs", name: "VS Code MCP Setup",
                    icon: "server.rack", description: "Open the official VS Code MCP guide",
                    triggers: ["mcp", "tools", "setup", "docs"], type: .urlScheme,
                    urlScheme: "https://code.visualstudio.com/docs/agent-customization/mcp-servers",
                    accentColor: "blue"
                )
            ]
        case "com.openai.codex":
            return [
                AdapterAction(
                    id: "starter.codex.docs", name: "Codex Documentation",
                    icon: "book", description: "Open the official Codex documentation",
                    triggers: ["codex", "docs", "help", "cli"], type: .urlScheme,
                    urlScheme: "https://developers.openai.com/codex/",
                    accentColor: "green"
                )
            ]
        case "com.anthropic.claudefordesktop":
            return [
                AdapterAction(
                    id: "starter.claude.codeDocs", name: "Claude Code CLI Reference",
                    icon: "book", description: "Open Anthropic's official Claude Code CLI reference",
                    triggers: ["claude", "code", "cli", "docs"], type: .urlScheme,
                    urlScheme: "https://docs.anthropic.com/en/docs/claude-code/cli-usage",
                    accentColor: "orange"
                ),
                AdapterAction(
                    id: "starter.claude.mcpDocs", name: "Claude MCP Setup",
                    icon: "server.rack", description: "Open Anthropic's official MCP guide",
                    triggers: ["claude", "mcp", "tools", "setup"], type: .urlScheme,
                    urlScheme: "https://docs.anthropic.com/en/docs/mcp",
                    accentColor: "orange"
                ),
            ]
        case "com.charliemonroe.Downie-4":
            return [
                AdapterAction(
                    id: "starter.downie.downloadCurrent",
                    name: "Download Current Page",
                    icon: "arrow.down.circle",
                    description: "Send the browser's current URL to Downie",
                    triggers: ["download", "video"],
                    type: .urlScheme,
                    urlScheme: "downie://XUOpenLink?url=$CURRENT_URL",
                    accentColor: "teal"
                )
            ]
        case "md.obsidian":
            return [
                AdapterAction(
                    id: "starter.obsidian.newNote",
                    name: "New Note",
                    icon: "square.and.pencil",
                    description: "Create a new note in the active vault",
                    triggers: ["new", "note"],
                    type: .urlScheme,
                    urlScheme: "obsidian://new?name={{query}}",
                    accentColor: "purple"
                ),
                AdapterAction(
                    id: "starter.obsidian.search",
                    name: "Search Vault",
                    icon: "magnifyingglass",
                    description: "Search the active Obsidian vault",
                    triggers: ["search", "find", "vault"],
                    type: .urlScheme,
                    urlScheme: "obsidian://search?query={{query}}",
                    accentColor: "purple"
                ),
            ]
        case "com.spotify.client":
            return [
                AdapterAction(
                    id: "starter.spotify.playpause",
                    name: "Play / Pause",
                    icon: "playpause",
                    description: "Toggle Spotify playback",
                    triggers: ["play", "pause", "music"],
                    type: .applescript,
                    script: "tell application \"Spotify\" to playpause",
                    accentColor: "green"
                ),
                AdapterAction(
                    id: "starter.spotify.next",
                    name: "Next Track",
                    icon: "forward.end",
                    description: "Skip to the next track",
                    triggers: ["next", "skip"],
                    type: .applescript,
                    script: "tell application \"Spotify\" to next track",
                    accentColor: "green"
                ),
                AdapterAction(
                    id: "starter.spotify.copyTrack",
                    name: "Copy Current Track",
                    icon: "doc.on.clipboard",
                    description: "Copy the now-playing artist and title to the clipboard",
                    triggers: ["copy", "track", "now", "playing"],
                    type: .shell,
                    script:
                        "osascript -e 'tell application \"Spotify\" to (get artist of current track) "
                        + "& \" — \" & (get name of current track)' | pbcopy",
                    accentColor: "green"
                ),
                AdapterAction(
                    id: "starter.spotify.lyrics",
                    name: "Find Lyrics",
                    icon: "quote.bubble",
                    description: "Open a web search for the current track's lyrics",
                    triggers: ["lyrics", "words", "sing"],
                    type: .shell,
                    script:
                        "t=$(osascript -e 'tell application \"Spotify\" to (get artist of current track) "
                        + "& \" \" & (get name of current track)'); "
                        + "open \"https://www.google.com/search?q=$(printf '%s lyrics' \"$t\" | sed 's/ /+/g')\"",
                    accentColor: "green"
                ),
            ]
        case "com.duckduckgo.macos.browser":
            return [
                AdapterAction(
                    id: "starter.ddg.search",
                    name: "Search DuckDuckGo",
                    icon: "magnifyingglass",
                    description: "Search DuckDuckGo for your query",
                    triggers: ["search", "ddg"],
                    type: .urlScheme,
                    urlScheme: "https://duckduckgo.com/?q={{query}}",
                    accentColor: "orange"
                )
            ]
        default:
            return []
        }
    }
}
