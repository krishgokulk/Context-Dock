// SystemCommands.swift
// Context-Dock
//
// Pre-seeded Apple menu commands always available via Global Context.
// Stored separately from Context Triggers so users can add/edit them in settings.

import Foundation

// MARK: - Model

struct SystemCommand: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var keywords: [String]
    var scriptType: String
    var script: String
    var description: String
    var isEnabled: Bool
    var successTitle: String
    var successMessage: String
    var undoTitle: String
    var undoScriptType: String
    var undoScript: String
    /// "none" | "slider" | "toggle" — renders a live control on the result row.
    var interaction: String
    var sliderMin: Double
    var sliderMax: Double
    var sliderStep: Double
    /// Optional script (same interpreter as `scriptType`) that prints the current
    /// value — a number for sliders, on/off for toggles — so the control opens
    /// reflecting real system state.
    var valueScript: String

    init(
        name: String, icon: String, keywords: [String],
        scriptType: String, script: String, description: String = "",
        successTitle: String = "",
        successMessage: String = "",
        undoTitle: String = "",
        undoScriptType: String = "applescript",
        undoScript: String = "",
        interaction: String = "none",
        sliderMin: Double = 0,
        sliderMax: Double = 100,
        sliderStep: Double = 1,
        valueScript: String = "",
        enabled: Bool = true
    ) {
        self.id             = UUID()
        self.name           = name
        self.icon           = icon
        self.keywords       = keywords
        self.scriptType     = scriptType
        self.script         = script
        self.description    = description.isEmpty ? name : description
        self.isEnabled      = enabled
        self.successTitle   = successTitle
        self.successMessage = successMessage
        self.undoTitle      = undoTitle
        self.undoScriptType = undoScriptType
        self.undoScript     = undoScript
        self.interaction    = interaction
        self.sliderMin      = sliderMin
        self.sliderMax      = sliderMax
        self.sliderStep     = sliderStep
        self.valueScript    = valueScript
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
        isEnabled      = try c.decodeIfPresent(Bool.self,   forKey: .isEnabled)      ?? true
        successTitle   = try c.decodeIfPresent(String.self, forKey: .successTitle)   ?? ""
        successMessage = try c.decodeIfPresent(String.self, forKey: .successMessage) ?? ""
        undoTitle      = try c.decodeIfPresent(String.self, forKey: .undoTitle)      ?? ""
        undoScriptType = try c.decodeIfPresent(String.self, forKey: .undoScriptType) ?? "applescript"
        undoScript     = try c.decodeIfPresent(String.self, forKey: .undoScript)     ?? ""
        interaction    = try c.decodeIfPresent(String.self, forKey: .interaction)    ?? "none"
        sliderMin      = try c.decodeIfPresent(Double.self, forKey: .sliderMin)      ?? 0
        sliderMax      = try c.decodeIfPresent(Double.self, forKey: .sliderMax)      ?? 100
        sliderStep     = try c.decodeIfPresent(Double.self, forKey: .sliderStep)     ?? 1
        valueScript    = try c.decodeIfPresent(String.self, forKey: .valueScript)    ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, keywords, scriptType, script, description, isEnabled
        case successTitle, successMessage, undoTitle, undoScriptType, undoScript
        case interaction, sliderMin, sliderMax, sliderStep, valueScript
    }
}

enum SystemCommandInteraction: String, CaseIterable, Identifiable {
    case none = "none"
    case slider = "slider"
    case toggle = "toggle"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None (run on Enter)"
        case .slider: return "Slider"
        case .toggle: return "Toggle"
        }
    }
}

enum SystemCommandActionType: String, CaseIterable, Identifiable {
    case url = "url"
    case file = "file"
    case bash = "bash"
    case applescript = "applescript"
    case jxa = "jxa"
    case scriptFile = "scriptFile"
    case aiPrompt = "aiPrompt"

    var id: String { rawValue }

    static func normalize(_ value: String) -> SystemCommandActionType {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "url", "openurl", "deeplink", "deep-link", "open url / deep link":
            return .url
        case "file", "openfile", "app", "openapp", "open file / app":
            return .file
        case "shell", "sh", "zsh", "bash", "command":
            return .bash
        case "applescript", "apple script", "osascript":
            return .applescript
        case "javascript", "js", "jxa":
            return .jxa
        case "scriptfile", "script_file", "script-file", "script file":
            return .scriptFile
        case "ai", "aiprompt", "ai_prompt", "ai-prompt", "prompt":
            return .aiPrompt
        default:
            return .bash
        }
    }

    var label: String {
        switch self {
        case .url: return "Open URL / Deep Link"
        case .file: return "Open File / App"
        case .bash: return "Shell Command"
        case .applescript: return "AppleScript"
        case .jxa: return "JXA"
        case .scriptFile: return "Script File"
        case .aiPrompt: return "AI Prompt"
        }
    }

    var valueLabel: String {
        switch self {
        case .url: return "URL / Deep Link"
        case .file: return "File or App Path"
        case .bash: return "Shell Command"
        case .applescript, .jxa: return "Script"
        case .scriptFile: return "Script File Path"
        case .aiPrompt: return "Prompt"
        }
    }

    var placeholder: String {
        switch self {
        case .url: return "x-apple.systempreferences:com.apple.BluetoothSettings"
        case .file: return "~/Applications/My App.app"
        case .bash: return "say \"$CD_QUERY\""
        case .applescript:
            return """
            tell application "Finder"
                empty trash
            end tell
            """
        case .jxa:
            return #"Application("Finder").activate()"#
        case .scriptFile:
            return "~/Scripts/my-command.sh"
        case .aiPrompt:
            return "Summarize the current context and suggest the next action."
        }
    }
}

extension SystemCommand {
    var actionType: SystemCommandActionType {
        SystemCommandActionType.normalize(scriptType)
    }

    var interactionType: SystemCommandInteraction {
        SystemCommandInteraction(rawValue: interaction.lowercased()) ?? .none
    }

    var actionTypeLabel: String {
        actionType.label
    }

    var hasUndoAction: Bool {
        !undoScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var undoActionType: SystemCommandActionType {
        SystemCommandActionType.normalize(undoScriptType)
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
            commands = Self.migratedCommands(from: decoded)
            save()
        } else {
            commands = Self.defaults
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        Task { @MainActor in
            DoraXSpotlightIndexService.shared.scheduleRebuild(reason: "system-commands")
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

    private static let legacyDefaultNames: Set<String> = [
        "Toggle Dark Mode",
        "Mute Audio",
        "Unmute Audio",
        "Set Volume",
        "Sleep Display",
        "Take Screenshot",
        "Show Desktop",
        "Do Not Disturb",
        // Retired built-in Global Commands — trimmed to a focused default set
        // (Wi-Fi, Bluetooth, Volume, Keep Awake, Sleep, Restart, Shut Down). Wi-Fi
        // Power is folded into the Wi-Fi command's inline toggle. Users can
        // re-create any of these as their own commands.
        "Wi-Fi Power",
        "About This Mac",
        "System Settings...",
        "App Store...",
        "Force Quit...",
        "Lock Screen",
        "Log Out...",
    ]

    private static func migratedCommands(from decoded: [SystemCommand]) -> [SystemCommand] {
        var migrated = decoded.filter { !legacyDefaultNames.contains($0.name) }
            .map { command -> SystemCommand in
                if command.name == "Bluetooth",
                    command.keywords.contains(where: { $0.lowercased() == "provider:bluetooth" }),
                    let currentDefault = defaults.first(where: { $0.name == "Bluetooth" })
                {
                    // Keep the built-in provider implementation current. Older
                    // persisted copies used a single brittle AX lookup that
                    // opened Settings but skipped switches with a missing name.
                    var enriched = command
                    enriched.description = currentDefault.description
                    enriched.script = currentDefault.script
                    enriched.interaction = currentDefault.interaction
                    enriched.valueScript = currentDefault.valueScript
                    return enriched
                }
                if command.name == "Wi-Fi",
                    command.keywords.contains(where: { $0.lowercased() == "provider:wifi" }),
                    let currentDefault = defaults.first(where: { $0.name == "Wi-Fi" })
                {
                    // Fold the standalone "Wi-Fi Power" toggle into the Wi-Fi command:
                    // refresh persisted copies so they gain the inline power toggle plus
                    // the on/off handling in the script.
                    var enriched = command
                    enriched.keywords = currentDefault.keywords
                    enriched.description = currentDefault.description
                    enriched.script = currentDefault.script
                    enriched.interaction = currentDefault.interaction
                    enriched.valueScript = currentDefault.valueScript
                    return enriched
                }
                guard command.name == "Sleep",
                    !command.keywords.contains(where: { $0.lowercased().hasPrefix("presets:") }),
                    command.script.contains(#"System Events" to sleep"#),
                    let defaultSleep = defaults.first(where: { $0.name == "Sleep" })
                else { return command }
                return defaultSleep
            }
        let existingNames = Set(migrated.map(\.name))
        migrated.append(contentsOf: defaults.filter { !existingNames.contains($0.name) })
        return migrated
    }

    private static func appleMenuClickScript(_ itemName: String) -> String {
        """
        tell application "System Events"
            set frontProc to first application process whose frontmost is true
            click menu item "\(itemName)" of menu 1 of menu bar item 1 of menu bar 1 of frontProc
        end tell
        """
    }

    static let defaults: [SystemCommand] = [
        SystemCommand(
            name: "Wi-Fi",
            icon: "wifi",
            keywords: ["wifi", "wi-fi", "wireless", "network", "networks", "power", "airport", "provider:wifi"],
            scriptType: "applescript",
            script: #"""
            set targetNetwork to system attribute "CD_QUERY"
            if targetNetwork is "on" or targetNetwork is "off" then
                do shell script "dev=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}'); networksetup -setairportpower \"$dev\" " & quoted form of targetNetwork
                return
            end if
            if targetNetwork is missing value or targetNetwork is "" or targetNetwork is "settings" then
                open location "x-apple.systempreferences:com.apple.wifi-settings-extension"
                return
            end if
            open location "x-apple.systempreferences:com.apple.wifi-settings-extension"
            delay 1
            tell application "System Events"
                tell process "System Settings"
                    set matches to UI elements of scroll areas of groups of windows whose name contains targetNetwork
                    if (count of matches) > 0 then click item 1 of matches
                end tell
            end tell
            """#,
            description: "Wi-Fi power and visible networks",
            interaction: "toggle",
            valueScript: #"""
            do shell script "dev=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}'); networksetup -getairportpower \"$dev\" | awk '{print tolower($NF)}'"
            """#
        ),
        SystemCommand(
            name: "Bluetooth",
            icon: "dot.radiowaves.left.and.right",
            keywords: ["bluetooth", "bt", "wireless", "devices", "provider:bluetooth"],
            scriptType: "applescript",
            script: #"""
            set targetDevice to system attribute "CD_QUERY"
            if targetDevice is "on" or targetDevice is "off" then
                set wantedValue to 1
                if targetDevice is "off" then set wantedValue to 0
                tell application "System Events"
                    tell process "ControlCenter"
                        set controlCenterItem to missing value
                        repeat with menuItem in menu bar items of menu bar 1
                            set itemName to ""
                            set itemDescription to ""
                            try
                                set itemName to name of menuItem as text
                            end try
                            try
                                set itemDescription to description of menuItem as text
                            end try
                            if itemName contains "Control Center" or itemDescription contains "Control Center" then
                                set controlCenterItem to menuItem
                                exit repeat
                            end if
                        end repeat
                        if controlCenterItem is missing value then error "Control Center menu was not found"
                        click controlCenterItem

                        repeat 30 times
                            if exists window 1 then
                                repeat with candidate in entire contents of window 1
                                    set candidateRole to ""
                                    set candidateName to ""
                                    set candidateDescription to ""
                                    try
                                        set candidateRole to role of candidate as text
                                    end try
                                    try
                                        set candidateName to name of candidate as text
                                    end try
                                    try
                                        set candidateDescription to description of candidate as text
                                    end try
                                    if (candidateRole is "AXCheckBox" or candidateRole is "AXSwitch") and (candidateName is "Bluetooth" or candidateDescription is "Bluetooth") then
                                        set currentValue to -1
                                        try
                                            set currentValue to value of candidate as integer
                                        end try
                                        if currentValue is not wantedValue then
                                            try
                                                perform action "AXPress" of candidate
                                            on error
                                                click candidate
                                            end try
                                        end if
                                        key code 53
                                        return
                                    end if
                                end repeat
                            end if
                            delay 0.1
                        end repeat
                        key code 53
                    end tell
                end tell
                error "Bluetooth power control was not found in Control Center"
                return
            end if
            if targetDevice is missing value or targetDevice is "" or targetDevice is "settings" then
                open location "x-apple.systempreferences:com.apple.BluetoothSettings"
                return
            end if
            open location "x-apple.systempreferences:com.apple.BluetoothSettings"
            delay 1
            tell application "System Events"
                tell process "System Settings"
                    set matchingElements to UI elements of scroll areas of groups of windows whose name contains targetDevice
                    if (count of matchingElements) > 0 then
                        click item 1 of matchingElements
                        delay 0.4
                    end if
                    set connectButtons to buttons of windows whose name is "Connect"
                    if (count of connectButtons) > 0 then click item 1 of connectButtons
                end tell
            end tell
            """#,
            description: "Bluetooth power and paired devices",
            interaction: "toggle",
            // Read natively by InteractiveCommandState. Retained as a portable
            // fallback for imported/exported command configurations.
            valueScript: #"do shell script "ioreg -r -c IOBluetoothHCIController -l | grep -q '\"CurrentPowerState\"=3' && echo on || echo off""#
        ),
        SystemCommand(
            name: "Volume",
            icon: "speaker.wave.3.fill",
            keywords: ["volume", "sound", "audio", "speaker"],
            scriptType: "applescript",
            script: #"""
            set rawValue to system attribute "CD_QUERY"
            if rawValue is missing value or rawValue is "" then set rawValue to "50"
            if rawValue is "max" then
                set targetVolume to 100
            else
                set targetVolume to rawValue as integer
            end if
            if targetVolume < 0 then set targetVolume to 0
            if targetVolume > 100 then set targetVolume to 100
            set volume output volume targetVolume
            """#,
            description: "Adjust Mac output volume",
            interaction: "slider",
            sliderMin: 0,
            sliderMax: 100,
            sliderStep: 1,
            valueScript: "output volume of (get volume settings)"
        ),
        SystemCommand(
            name: "Appearance",
            icon: "circle.lefthalf.filled",
            keywords: ["appearance", "theme", "dark", "light", "mode", "presets:Light|Dark|Auto"],
            scriptType: "applescript",
            script: #"""
            set rawValue to system attribute "CD_QUERY"
            if rawValue is missing value then set rawValue to ""
            set q to do shell script "printf %s " & quoted form of (rawValue as text) & " | tr '[:upper:]' '[:lower:]'"
            if q is "" then return
            if q is "auto" then
                do shell script "defaults write -g AppleInterfaceStyleSwitchesAutomatically -bool true"
                return
            end if
            set wantDark to false
            if q is "on" or q is "dark" then set wantDark to true
            do shell script "defaults delete -g AppleInterfaceStyleSwitchesAutomatically 2>/dev/null; true"
            tell application "System Events"
                tell appearance preferences to set dark mode to wantDark
            end tell
            """#,
            description: "Light / Dark / Auto appearance",
            interaction: "toggle",
            valueScript: #"tell application "System Events" to tell appearance preferences to get dark mode"#
        ),
        SystemCommand(
            name: "Windows",
            icon: "macwindow.on.rectangle",
            keywords: ["windows", "window", "layout", "tile", "arrange", "snap", "resize", "halves", "quarters", "provider:windows"],
            scriptType: "applescript",
            // Enter opens the scoped layout picker; there is no single action. The
            // provider:windows scope renders native window-management tiles that act
            // on the app you were in before opening Context-Dock.
            script: #"return"#,
            description: "Tile and arrange the frontmost window"
        ),
        SystemCommand(
            name: "Quick Note",
            icon: "note.text",
            keywords: ["note", "notes", "quicknote", "notepad", "scratch", "jot", "provider:notepad"],
            scriptType: "applescript",
            // Enter opens the capture scope; there is no single action. The
            // provider:notepad scope renders a Save row plus saved notes.
            script: #"return"#,
            description: "Capture and search quick notes"
        ),
        SystemCommand(
            name: "Keep Awake",
            icon: "cup.and.saucer.fill",
            keywords: ["caffeine", "caffeinate", "keep awake", "stay awake", "awake", "insomnia", "nosleep", "no sleep"],
            scriptType: "bash",
            script: #"""
            pidf=/tmp/context-dock-caffeinate.pid
            if [ -f "$pidf" ]; then kill "$(cat "$pidf")" >/dev/null 2>&1 || true; rm -f "$pidf"; fi
            v=$(printf '%s' "$CD_QUERY" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
            case "$v" in
                ""|off|false|0|stop|disable) exit 0 ;;
            esac
            secs=0
            case "$v" in
                on|true|1|start|enable) secs=0 ;;
                *h) secs=$(( ${v%h} * 3600 )) ;;
                *m|*min) n=${v%min}; n=${n%m}; secs=$(( n * 60 )) ;;
                *) printf '%s' "$v" | grep -qE '^[0-9]+$' && secs=$v ;;
            esac
            if [ "$secs" -gt 0 ]; then
                nohup /usr/bin/caffeinate -dimsu -t "$secs" >/dev/null 2>&1 &
            else
                nohup /usr/bin/caffeinate -dimsu >/dev/null 2>&1 &
            fi
            echo $! > "$pidf"
            """#,
            description: "Keep the Mac awake (prevents display + system sleep). Type a duration like 1h or 30m, or leave on indefinitely.",
            interaction: "toggle",
            valueScript: #"""
            pidf=/tmp/context-dock-caffeinate.pid
            if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" >/dev/null 2>&1; then echo on; else echo off; fi
            """#
        ),
        SystemCommand(
            name: "Sleep",
            icon: "moon",
            keywords: ["sleep", "standby", "awake", "caffeinate", "presets:Now|Stay Awake Infinity"],
            scriptType: "applescript",
            script: #"""
            set rawValue to system attribute "CD_QUERY"
            if rawValue is missing value or rawValue is "" then set rawValue to "now"
            set targetAction to rawValue as text
            set targetAction to do shell script "printf %s " & quoted form of targetAction & " | tr '[:upper:]' '[:lower:]'"
            if targetAction contains "awake" or targetAction contains "infinity" then
                do shell script "if [ -f /tmp/context-dock-caffeinate.pid ]; then kill $(cat /tmp/context-dock-caffeinate.pid) >/dev/null 2>&1 || true; fi; /usr/bin/caffeinate -dimsu >/tmp/context-dock-caffeinate.log 2>&1 & echo $! > /tmp/context-dock-caffeinate.pid"
            else
                do shell script "if [ -f /tmp/context-dock-caffeinate.pid ]; then kill $(cat /tmp/context-dock-caffeinate.pid) >/dev/null 2>&1 || true; rm -f /tmp/context-dock-caffeinate.pid; fi"
                tell application "System Events" to sleep
            end if
            """#,
            description: "Sleep Mac or keep Mac awake indefinitely"
        ),
        SystemCommand(
            name: "Restart...",
            icon: "arrow.clockwise.circle",
            keywords: ["restart", "reboot"],
            scriptType: "applescript",
            script: appleMenuClickScript("Restart..."),
            description: "Restart Mac"
        ),
        SystemCommand(
            name: "Shut Down...",
            icon: "power",
            keywords: ["shutdown", "shut down", "power off"],
            scriptType: "applescript",
            script: appleMenuClickScript("Shut Down..."),
            description: "Shut down Mac"
        ),
        SystemCommand(
            name: "Empty Trash",
            icon: "trash",
            keywords: ["empty trash", "trash", "bin", "empty bin", "clear trash"],
            scriptType: "applescript",
            script: #"tell application "Finder" to empty trash"#,
            description: "Empty the Trash"
        ),
        SystemCommand(
            name: "Process Monitor",
            icon: "cpu",
            keywords: [
                "process", "processes", "memory", "ram", "cpu", "usage", "activity",
                "monitor", "kill", "quit", "task", "provider:processes",
            ],
            // Enter opens the scoped list; there is no single action. The
            // provider:processes scope renders live apps grouped with their helper
            // processes (CPU% + memory), sortable, with Kill on Enter.
            scriptType: "applescript",
            script: #"return"#,
            description: "Live CPU + memory usage by app; Enter to quit"
        ),

        // ── Example templates (disabled) ──────────────────────────────────────
        // Shipped OFF so they don't clutter Global Context. They live in
        // Settings → Automation → Global Commands as editable, working examples of
        // what user-authored commands can do. Enable or duplicate to use.
        SystemCommand(
            name: "Ask AI",
            icon: "sparkles",
            keywords: ["ask", "ai", "explain", "assistant"],
            scriptType: "aiPrompt",
            script: "Act on the selected text. Selection:\n\n$CD_TEXT\n\nRequest: $CD_QUERY",
            description: "Example: send your selection + query to AI",
            enabled: false
        ),
        SystemCommand(
            name: "Open in Chrome",
            icon: "safari",
            keywords: ["chrome", "open in chrome", "browser"],
            scriptType: "applescript",
            script: #"do shell script "open -a 'Google Chrome' " & quoted form of (system attribute "CD_URL")"#,
            description: "Example: open the current page URL in Chrome (uses $CD_URL)",
            enabled: false
        ),
        SystemCommand(
            name: "Focus",
            icon: "moon.circle",
            keywords: ["focus", "dnd", "do not disturb", "presets:Work|Personal|Off"],
            scriptType: "bash",
            script: #"""
            shortcuts run "Focus $CD_QUERY" 2>/dev/null \
              || open "x-apple.systempreferences:com.apple.Focus-Settings.extension"
            """#,
            description: "Example: run a Focus shortcut; scope for Work / Personal / Off",
            enabled: false
        ),

        // ── List Extension example ────────────────────────────────────────────
        // A user-authored LIVE LIST scope, the general-purpose version of the
        // built-in Process Monitor. Marked with `provider:custom`: the Script prints
        // one JSON row per line, and the Undo field is the per-row action (with the
        // row exposed as $CD_ROW_ID / $CD_ROW_TITLE). `refresh:3` re-samples every
        // 3s. Duplicate this to build your own extension (Docker containers, git
        // branches, open ports, …). Shipped OFF so it only lives in Settings.
        SystemCommand(
            name: "Top Memory",
            icon: "memorychip",
            keywords: ["top", "memory", "ram", "hogs", "provider:custom", "refresh:3"],
            scriptType: "bash",
            script: #"""
            # Print the top memory apps as JSON rows. Each line: one JSON object.
            ps -axo rss=,comm= | sort -rn | head -12 | while read rss comm; do
              name=$(basename "$comm")
              mb=$(( rss / 1024 ))
              printf '{"id":"%s","title":"%s","badge":"%s MB"}\n' "$comm" "$name" "$mb"
            done
            """#,
            description:
                "Example List Extension: top memory apps (JSON rows). Enter reveals the process in Finder. Duplicate to build your own.",
            undoScriptType: "bash",
            undoScript: #"open -R "$CD_ROW_ID" 2>/dev/null || open "$(dirname "$CD_ROW_ID")""#,
            enabled: false
        ),
        SystemCommand(
            name: "Top CPU",
            icon: "cpu",
            keywords: ["top", "cpu", "processor", "busy", "hot", "provider:custom", "refresh:2"],
            scriptType: "bash",
            script: #"""
            # Top CPU processes as JSON rows. id = PID (so the action can kill it).
            ps -axo pid=,%cpu=,comm= | sort -k2 -rn | head -12 | while read pid cpu comm; do
              name=$(basename "$comm")
              printf '{"id":"%s","title":"%s","badge":"%s%% CPU","icon":"cpu"}\n' "$pid" "$name" "$cpu"
            done
            """#,
            description:
                "Example List Extension: busiest CPU processes. Enter quits the process (SIGTERM).",
            undoScriptType: "bash",
            undoScript: #"kill "$CD_ROW_ID" 2>/dev/null"#,
            enabled: false
        ),
        SystemCommand(
            name: "Listening Ports",
            icon: "network",
            keywords: [
                "ports", "port", "listening", "lsof", "server", "servers", "localhost",
                "provider:custom", "refresh:3",
            ],
            scriptType: "bash",
            script: #"""
            # Processes listening on TCP ports. id = PID so Enter can kill the server.
            /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
              | awk 'NR>1 {split($9,a,":"); print $2"\t"$1"\t"a[length(a)]}' \
              | sort -u | head -20 | while IFS=$'\t' read pid name port; do
                printf '{"id":"%s","title":"%s","subtitle":"PID %s","badge":"port %s","icon":"network"}\n' "$pid" "$name" "$pid" "$port"
              done
            """#,
            description:
                "Example List Extension: apps listening on TCP ports. Enter kills the process — handy for freeing a stuck dev server.",
            undoScriptType: "bash",
            undoScript: #"kill "$CD_ROW_ID" 2>/dev/null"#,
            enabled: false
        ),
    ]
}
