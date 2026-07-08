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

    private static let seededKey = "adapterStarterActionsSeededBundles"

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
        let curated = curatedActions(for: bundleId)
        return curated.isEmpty ? [genericAssistAction(appName: appName)] : curated
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
                )
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
