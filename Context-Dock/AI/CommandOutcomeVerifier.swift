// CommandOutcomeVerifier.swift
// Context-Dock
//
// Reads back what a command claimed to change.
//
// A shell command that exits zero has *run*. That is not the same as having *worked*, and
// the difference is invisible to the model: `defaults write NSGlobalDomain
// AppleInterfaceStyle -string "Light"` returns nothing and exits zero whether or not the
// desktop ever changed, so the answer came back as "the system appearance has been
// successfully changed" on the strength of an exit code.
//
// So the commands whose effect can be read back are read back, and the result carries the
// reading. Where nothing can be checked the result says so, because the model cannot tell
// an unverifiable command from a verified one and will narrate both as done.
//
// Deliberately small. A verifier that guesses is worse than none: it would confirm things
// that did not happen, which is the exact failure this exists to stop.

import AppKit
import Foundation

enum CommandOutcomeVerifier {

    /// What the machine says after the command ran, or nil when nothing here can check it.
    ///
    /// Carries a status alongside the sentence. The sentence used to be the whole answer,
    /// and callers decided pass or fail by looking for the prefix "NOT applied" — a verdict
    /// encoded in prose, which every reader had to parse and any rewording would break.
    struct Reading {
        let status: VerificationStatus
        /// The reading itself, for the model and for the receipt.
        let message: String
    }

    static func verify(command: String) -> Reading? {
        let lowered = command.lowercased()

        if lowered.contains("appleinterfacestyle") {
            return appearanceState(expectingDark: !lowered.contains("delete"))
        }
        if lowered.contains("appearance preferences"), lowered.contains("dark mode") {
            return appearanceState(expectingDark: lowered.contains("to true"))
        }
        if let app = quitTarget(in: command) {
            return runningState(of: app)
        }
        return nil
    }

    /// True when a command's effect is checkable at all — used to mark the ones that are
    /// not, so an unverified success is never read as a verified one.
    static func isVerifiable(command: String) -> Bool {
        verify(command: command) != nil
    }

    // MARK: - Readings

    /// Read from the same defaults domain the command writes, rather than from a cached
    /// NSApp appearance: the app's own appearance can lag the system's by a run loop, and a
    /// verifier that reads a stale copy reports the change it was checking for.
    private static func appearanceState(expectingDark: Bool) -> Reading {
        let domain = UserDefaults.standard.persistentDomain(
            forName: UserDefaults.globalDomain)
        let value = domain?["AppleInterfaceStyle"] as? String
        let isDark = value?.lowercased() == "dark"
        let now = isDark ? "dark" : "light"
        let wanted = expectingDark ? "dark" : "light"
        return isDark == expectingDark
            ? Reading(status: .verified, message: "System appearance is now \(now).")
            : Reading(
                status: .contradicted,
                message: "System appearance is still \(now), not \(wanted).")
    }

    private static func runningState(of appName: String) -> Reading {
        let running = NSWorkspace.shared.runningApplications.contains {
            ($0.localizedName ?? "").caseInsensitiveCompare(appName) == .orderedSame
                && !$0.isTerminated
        }
        return running
            ? Reading(status: .contradicted, message: "\(appName) is still running.")
            : Reading(status: .verified, message: "\(appName) is no longer running.")
    }

    /// The app a quit-shaped command names — `killall Safari`, `osascript -e 'quit app
    /// "Safari"'`, `pkill -x Notes`.
    private static func quitTarget(in command: String) -> String? {
        let patterns = [
            #"(?i)\bkillall\s+(?:-\w+\s+)*"?([A-Za-z][\w \-]*)"?"#,
            #"(?i)\bpkill\s+(?:-\w+\s+)*"?([A-Za-z][\w \-]*)"?"#,
            #"(?i)quit\s+app(?:lication)?\s+"([^"]+)""#,
        ]
        for pattern in patterns {
            guard let range = command.range(of: pattern, options: .regularExpression) else {
                continue
            }
            let match = String(command[range])
            // The capture is whatever follows the verb and its flags — taken from the raw
            // match rather than a capture group, which NSRegularExpression would need a
            // second pass to extract for no gain here.
            let name = match
                .replacingOccurrences(
                    of: #"(?i)^\s*(killall|pkill|quit\s+app(lication)?)\s+"#,
                    with: "", options: .regularExpression)
                .replacingOccurrences(
                    of: #"^(-\w+\s+)+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name }
        }
        return nil
    }
}
