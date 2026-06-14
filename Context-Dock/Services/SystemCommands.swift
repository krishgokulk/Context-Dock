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
        valueScript: String = ""
    ) {
        self.id             = UUID()
        self.name           = name
        self.icon           = icon
        self.keywords       = keywords
        self.scriptType     = scriptType
        self.script         = script
        self.description    = description.isEmpty ? name : description
        self.isEnabled      = true
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
        "Empty Trash",
        "Take Screenshot",
        "Show Desktop",
        "Do Not Disturb",
    ]

    private static func migratedCommands(from decoded: [SystemCommand]) -> [SystemCommand] {
        var migrated = decoded.filter { !legacyDefaultNames.contains($0.name) }
            .map { command -> SystemCommand in
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
            keywords: ["wifi", "wi-fi", "wireless", "network", "networks", "provider:wifi"],
            scriptType: "applescript",
            script: #"""
            set targetNetwork to system attribute "CD_QUERY"
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
            description: "Show visible Wi-Fi networks and open selected network"
        ),
        SystemCommand(
            name: "Bluetooth",
            icon: "dot.radiowaves.left.and.right",
            keywords: ["bluetooth", "bt", "wireless", "devices", "provider:bluetooth"],
            scriptType: "applescript",
            script: #"""
            set targetDevice to system attribute "CD_QUERY"
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
            description: "Show paired Bluetooth devices and open selected device"
        ),
        SystemCommand(
            name: "Volume",
            icon: "speaker.wave.3.fill",
            keywords: ["volume", "sound", "audio", "speaker", "presets:10|25|30|45|50|65|75|80|95|max"],
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
            description: "Set Mac output volume",
            interaction: "slider",
            sliderMin: 0,
            sliderMax: 100,
            sliderStep: 1,
            valueScript: "output volume of (get volume settings)"
        ),
        SystemCommand(
            name: "Wi-Fi Power",
            icon: "wifi.circle",
            keywords: ["wifi", "wi-fi", "wireless", "power", "toggle", "airport"],
            scriptType: "bash",
            script: #"""
            dev=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')
            networksetup -setairportpower "$dev" "$CD_QUERY"
            """#,
            description: "Turn Wi-Fi on or off",
            interaction: "toggle",
            valueScript: #"""
            dev=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')
            networksetup -getairportpower "$dev" | awk '{print tolower($NF)}'
            """#
        ),
        SystemCommand(
            name: "About This Mac",
            icon: "laptopcomputer",
            keywords: ["about", "mac", "about this mac", "system info"],
            scriptType: "applescript",
            script: appleMenuClickScript("About This Mac"),
            description: "Open About This Mac from Apple menu"
        ),
        SystemCommand(
            name: "System Settings...",
            icon: "gearshape",
            keywords: ["settings", "system settings", "preferences", "system preferences"],
            scriptType: "applescript",
            script: #"tell application "System Settings" to activate"#,
            description: "Open System Settings"
        ),
        SystemCommand(
            name: "App Store...",
            icon: "app.badge",
            keywords: ["app store", "updates", "software", "apps"],
            scriptType: "applescript",
            script: #"tell application "App Store" to activate"#,
            description: "Open App Store"
        ),
        SystemCommand(
            name: "Force Quit...",
            icon: "exclamationmark.octagon",
            keywords: ["force quit", "quit app", "force", "applications"],
            scriptType: "applescript",
            script: appleMenuClickScript("Force Quit..."),
            description: "Open Force Quit Applications"
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
            name: "Lock Screen",
            icon: "lock",
            keywords: ["lock", "lock screen", "secure", "password"],
            scriptType: "applescript",
            script: #"tell application "System Events" to keystroke "q" using {control down, command down}"#,
            description: "Lock screen"
        ),
        SystemCommand(
            name: "Log Out...",
            icon: "rectangle.portrait.and.arrow.right",
            keywords: ["log out", "logout", "sign out"],
            scriptType: "applescript",
            script: appleMenuClickScript("Log Out..."),
            description: "Log out current user"
        ),
    ]
}
