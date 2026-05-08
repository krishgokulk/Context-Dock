// SystemCommands.swift
// Context-Dock
//
// Pre-seeded global system commands always available via natural language.
// Stored separately from Context Triggers — intended for device-level controls
// (volume, brightness, appearance, display, etc.) that feel native.

import Foundation

// MARK: - Model

struct SystemCommand: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var keywords: [String]
    var scriptType: String  // "applescript" | "bash"
    var script: String
    var description: String
    var isEnabled: Bool

    init(
        name: String, icon: String, keywords: [String],
        scriptType: String, script: String, description: String = ""
    ) {
        self.id          = UUID()
        self.name        = name
        self.icon        = icon
        self.keywords    = keywords
        self.scriptType  = scriptType
        self.script      = script
        self.description = description.isEmpty ? name : description
        self.isEnabled   = true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self,   forKey: .id)
        name        = try c.decode(String.self, forKey: .name)
        icon        = try c.decodeIfPresent(String.self, forKey: .icon)        ?? "command"
        keywords    = try c.decodeIfPresent([String].self, forKey: .keywords)  ?? []
        scriptType  = try c.decodeIfPresent(String.self, forKey: .scriptType)  ?? "applescript"
        script      = try c.decode(String.self, forKey: .script)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? name
        isEnabled   = try c.decodeIfPresent(Bool.self,   forKey: .isEnabled)   ?? true
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, keywords, scriptType, script, description, isEnabled
    }
}

// MARK: - Registry

final class SystemCommandsRegistry {
    static let shared = SystemCommandsRegistry()

    private let storageKey = "systemCommandsData_v1"

    private(set) var commands: [SystemCommand] = []

    private init() { load() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([SystemCommand].self, from: data) {
            commands = decoded
        } else {
            commands = Self.defaults
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func add(_ cmd: SystemCommand) {
        commands.append(cmd)
        save()
    }

    func remove(_ cmd: SystemCommand) {
        commands.removeAll { $0.id == cmd.id }
        save()
    }

    func update(_ cmd: SystemCommand) {
        if let idx = commands.firstIndex(where: { $0.id == cmd.id }) {
            commands[idx] = cmd
            save()
        }
    }

    // MARK: Matching

    /// Return the highest-scoring enabled command whose name/keywords overlap with the query.
    /// Threshold ≥ 25 prevents accidental matches on short words.
    func bestMatch(for query: String) -> SystemCommand? {
        let q = query.lowercased()
        let enabled = commands.filter { $0.isEnabled }

        func score(_ cmd: SystemCommand) -> Int {
            let n = cmd.name.lowercased()
            if n == q { return 100 }
            if q.contains(n) || n.contains(q) { return 80 }
            let words = q.components(separatedBy: " ").filter { !$0.isEmpty }
            let kwHits   = cmd.keywords.filter { kw in words.contains { w in w.contains(kw) || kw.contains(w) } }.count
            let nameHits = n.components(separatedBy: " ").filter { nw in words.contains { w in w.contains(nw) || nw.contains(w) } }.count
            return kwHits * 25 + nameHits * 20
        }

        return enabled
            .compactMap { cmd -> (SystemCommand, Int)? in let s = score(cmd); return s >= 25 ? (cmd, s) : nil }
            .sorted { $0.1 > $1.1 }
            .first?.0
    }

    // MARK: Defaults

    static let defaults: [SystemCommand] = [
        SystemCommand(
            name: "Toggle Dark Mode",
            icon: "circle.lefthalf.filled",
            keywords: ["dark", "mode", "light", "appearance", "theme", "toggle"],
            scriptType: "applescript",
            script: """
            tell application "System Events"
                tell appearance preferences
                    set dark mode to not dark mode
                end tell
            end tell
            """,
            description: "Switch between Light and Dark appearance"
        ),
        SystemCommand(
            name: "Mute Audio",
            icon: "speaker.slash.fill",
            keywords: ["mute", "unmute", "audio", "sound", "volume", "silence", "quiet"],
            scriptType: "applescript",
            script: "set volume with output muted",
            description: "Mute system audio output"
        ),
        SystemCommand(
            name: "Unmute Audio",
            icon: "speaker.wave.2.fill",
            keywords: ["unmute", "restore", "audio", "sound", "volume"],
            scriptType: "applescript",
            script: "set volume without output muted",
            description: "Unmute system audio output"
        ),
        SystemCommand(
            name: "Set Volume",
            icon: "speaker.wave.3.fill",
            keywords: ["set", "volume", "audio", "level", "percent", "loud"],
            scriptType: "bash",
            script: #"""
            #!/bin/bash
            QUERY="${CD_QUERY:-}"
            LEVEL=$(echo "$QUERY" | grep -oE '[0-9]+' | head -1)
            if [ -z "$LEVEL" ]; then
              LEVEL=$(osascript -e 'choose from list {"10","25","50","75","100"} with prompt "Set volume to:" default items {"50"}')
              [ "$LEVEL" = "false" ] && exit 0
            fi
            LEVEL=$(( LEVEL > 100 ? 100 : (LEVEL < 0 ? 0 : LEVEL) ))
            osascript -e "set volume output volume $LEVEL"
            echo "Volume set to ${LEVEL}%"
            """#,
            description: "Set system volume (0–100). Extracts number from query automatically."
        ),
        SystemCommand(
            name: "Lock Screen",
            icon: "lock.fill",
            keywords: ["lock", "screen", "secure", "password"],
            scriptType: "bash",
            script: #"/System/Library/CoreServices/Menu\ Extras/User.menu/Contents/Resources/CGSession -suspend"#,
            description: "Lock the screen immediately"
        ),
        SystemCommand(
            name: "Sleep Display",
            icon: "moon.fill",
            keywords: ["sleep", "display", "screen", "off", "dim", "turn off"],
            scriptType: "bash",
            script: "pmset displaysleepnow",
            description: "Put the display to sleep"
        ),
        SystemCommand(
            name: "Empty Trash",
            icon: "trash.fill",
            keywords: ["empty", "trash", "delete", "clean", "bin", "recycle"],
            scriptType: "applescript",
            script: #"tell application "Finder" to empty trash"#,
            description: "Empty the macOS Trash"
        ),
        SystemCommand(
            name: "Take Screenshot",
            icon: "camera.viewfinder",
            keywords: ["screenshot", "capture", "screen", "snap", "photo"],
            scriptType: "bash",
            script: #"screencapture -i ~/Desktop/Screenshot-$(date +%Y%m%d-%H%M%S).png"#,
            description: "Take an interactive screenshot and save to Desktop"
        ),
        SystemCommand(
            name: "Show Desktop",
            icon: "rectangle.on.rectangle.slash",
            keywords: ["show", "desktop", "hide", "windows", "clear", "mission control"],
            scriptType: "applescript",
            script: """
            tell application "System Events" to key code 103 using {command down, shift down}
            """,
            description: "Hide all windows and show the Desktop"
        ),
        SystemCommand(
            name: "Do Not Disturb",
            icon: "bell.slash.fill",
            keywords: ["do not disturb", "dnd", "focus", "notifications", "quiet"],
            scriptType: "bash",
            script: #"""
            #!/bin/bash
            # Toggle Focus / Do Not Disturb via shortcut
            osascript -e 'tell application "System Events" to tell process "Control Center" to click menu bar item "Control Center" of menu bar 1'
            sleep 0.5
            osascript -e 'tell application "System Events" to tell process "Control Center" to click button "Focus" of window "Control Center"'
            """#,
            description: "Toggle Do Not Disturb / Focus mode"
        ),
    ]
}
