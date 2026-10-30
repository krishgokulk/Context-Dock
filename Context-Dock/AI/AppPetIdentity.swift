// AppPetIdentity.swift
// Context-Dock
//
// Stable identity for an App Pet (#338). An App Pet is an app-scoped or CLI-scoped assistant
// profile over the shared DoraX engine and conversation stores. Names, icons and mutable
// running-app state do not belong in the identifier.

import Foundation

/// Stable identity for an App Pet in the Dock or a conversation scope.
enum AppPetID: Codable, Hashable, Sendable {
    case app(bundleID: String)
    case cli(command: String)

    static func normalizeCLICommand(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalized: AppPetID {
        switch self {
        case .app(let bundleID):
            return .app(bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines))
        case .cli(let command):
            return .cli(command: Self.normalizeCLICommand(command))
        }
    }

    var bundleID: String? {
        guard case .app(let bundleID) = normalized, !bundleID.isEmpty else { return nil }
        return bundleID
    }

    var cliCommand: String? {
        guard case .cli(let command) = normalized, !command.isEmpty else { return nil }
        return command
    }

    /// The string identifier the Dock uses (`<bundleID>` or `cli://<command>`).
    var dockBundleID: String {
        switch normalized {
        case .app(let bundleID): return bundleID
        case .cli(let command): return "cli://\(command)"
        }
    }

    init?(dockBundleID: String?) {
        guard let raw = dockBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        if raw.hasPrefix("cli://") {
            let command = Self.normalizeCLICommand(String(raw.dropFirst("cli://".count)))
            guard !command.isEmpty else { return nil }
            self = .cli(command: command)
        } else {
            self = .app(bundleID: raw)
        }
    }

    static func == (lhs: AppPetID, rhs: AppPetID) -> Bool {
        switch (lhs, rhs) {
        case (.app(let a), .app(let b)):
            return a.trimmingCharacters(in: .whitespacesAndNewlines)
                == b.trimmingCharacters(in: .whitespacesAndNewlines)
        case (.cli(let a), .cli(let b)):
            return normalizeCLICommand(a) == normalizeCLICommand(b)
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .app(let bundleID):
            hasher.combine(0)
            hasher.combine(bundleID.trimmingCharacters(in: .whitespacesAndNewlines))
        case .cli(let command):
            hasher.combine(1)
            hasher.combine(Self.normalizeCLICommand(command))
        }
    }
}
