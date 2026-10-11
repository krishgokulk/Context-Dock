// SystemConnectors.swift
// Context-Dock
//
// The user's Global Commands grouped by topic into "System" packs — Bluetooth, Wi-Fi,
// Sound, Appearance and so on — so the chat can find "is Bluetooth on?" under a name a
// person would use, and so Settings (task 12b) has one model to list them from.
//
// A view over SystemCommandsRegistry, not a second store: nothing here is persisted, and
// the group is derived from each command's name and keywords every time, so a command the
// user writes or edits lands in the right pack without anyone maintaining a table.

import Foundation

/// One System pack. Order of the cases is the order packs are listed in, and the order a
/// command is tested against them — Bluetooth before Wi-Fi, because both carry "wireless".
enum SystemConnectorGroup: String, CaseIterable, Equatable {
    case bluetooth
    case wifi
    case display
    case sound
    case appearance
    case focus
    case battery
    case windows
    /// Everything that fits no topic: Sleep, Restart, Empty Trash, the user's own scripts.
    case system

    var title: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .wifi: return "Wi-Fi"
        case .display: return "Display"
        case .sound: return "Sound"
        case .appearance: return "Appearance"
        case .focus: return "Focus"
        case .battery: return "Battery"
        case .windows: return "Windows"
        case .system: return "System"
        }
    }

    /// The pack's symbol in Settings ▸ App Packs.
    var symbol: String {
        switch self {
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .wifi: return "wifi"
        case .display: return "sun.max.fill"
        case .sound: return "speaker.wave.2.fill"
        case .appearance: return "circle.lefthalf.filled"
        case .focus: return "moon.fill"
        case .battery: return "battery.100"
        case .windows: return "macwindow"
        case .system: return "gearshape.fill"
        }
    }

    /// Whole names or keywords that put a command in this pack. Compared as whole words
    /// and whole keywords, never substrings: "power off" (Shut Down) is not "low power",
    /// and "monitor" in Process Monitor is not a display.
    fileprivate var markers: Set<String> {
        switch self {
        case .bluetooth: return ["bluetooth", "provider:bluetooth"]
        case .wifi: return ["wifi", "wi-fi", "provider:wifi", "airport"]
        case .display: return ["display", "brightness", "night shift", "true tone"]
        case .sound: return ["volume", "sound", "audio", "mute", "speaker"]
        case .appearance: return ["appearance", "dark mode", "dark", "theme"]
        case .focus: return ["focus", "dnd", "do not disturb"]
        case .battery: return ["battery", "charging", "low power", "low power mode"]
        case .windows: return ["windows", "window", "provider:windows"]
        case .system: return []
        }
    }

    /// The pack a command belongs to. Its name is asked first — a command called "Volume"
    /// is about sound whatever else its keywords mention — then its keywords, in case order.
    static func group(for command: SystemCommand) -> SystemConnectorGroup {
        let name = command.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let nameTerms = Set(name.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .union([name, name.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))])
        if let byName = allCases.first(where: { !$0.markers.isDisjoint(with: nameTerms) }) {
            return byName
        }
        let keywords = Set(command.keywords.map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        })
        return allCases.first { !$0.markers.isDisjoint(with: keywords) } ?? .system
    }
}

/// One pack and the enabled commands in it, in the user's own order.
struct SystemConnector: Equatable {
    let group: SystemConnectorGroup
    let commands: [SystemCommand]
}

enum SystemConnectors {
    /// The packs the chat can use. Disabled commands are left out, and so are the ones with
    /// nothing to run (the Windows and Quick Note pickers), so an empty pack never appears.
    /// Settings passes `includingDisabled` so a pack that is switched off is still listed.
    static func connectors(
        from commands: [SystemCommand], includingDisabled: Bool = false
    ) -> [SystemConnector] {
        let usable = commands.filter {
            (includingDisabled || $0.isEnabled) && GlobalCommandCapabilities.isRunnable($0)
        }
        return SystemConnectorGroup.allCases.compactMap { group in
            let members = usable.filter { SystemConnectorGroup.group(for: $0) == group }
            return members.isEmpty ? nil : SystemConnector(group: group, commands: members)
        }
    }
}
