import AppKit
import SwiftUI

enum FinderDirectActionResult {
    case handled(success: Bool, message: String, icon: String, tint: Color)
    case notHandled
}

final class FinderActionService {
    static let shared = FinderActionService()

    private init() {}

    func executeDirectActionIfNeeded(path: [String]) async -> FinderDirectActionResult {
        let normalizedPath = path.map(Self.normalizedMenuText)
        if Self.isOpenWithApplicationAction(normalizedPath),
            let appName = Self.openWithApplicationName(from: path)
        {
            let result = await openFinderSelection(withApplicationNamed: appName)
            return .handled(
                success: result.success,
                message: result.success ? "Opening in \(result.displayName ?? appName)" : result.message,
                icon: result.success ? "arrow.up.right.square" : "exclamationmark.triangle",
                tint: result.success ? .blue.opacity(0.9) : .orange.opacity(0.9)
            )
        }

        if Self.isMoveToBinAction(normalizedPath) {
            let result = await moveSelectionToBin()
            return .handled(
                success: result.success,
                message: result.success ? "Moved to Bin" : result.message,
                icon: result.success ? "trash" : "exclamationmark.triangle",
                tint: result.success ? .red.opacity(0.9) : .orange.opacity(0.9)
            )
        }

        if Self.isEmptyBinAction(normalizedPath) {
            let result = await emptyBin()
            return .handled(
                success: result.success,
                message: result.success ? "Bin emptied" : result.message,
                icon: result.success ? "trash" : "exclamationmark.triangle",
                tint: result.success ? .green.opacity(0.85) : .orange.opacity(0.9)
            )
        }

        return .notHandled
    }

    private func openFinderSelection(
        withApplicationNamed appName: String
    ) async -> (success: Bool, message: String, displayName: String?) {
        let urls = await Self.selectedFinderURLs()
        guard !urls.isEmpty else {
            return (false, "No Finder selection", nil)
        }

        let suggestions = DefaultAppResolver.shared.getOpenWithSuggestions(for: urls)
        let normalizedTarget = Self.normalizedApplicationName(appName)
        guard
            let suggestion = suggestions.first(where: {
                Self.normalizedApplicationName($0.app.displayName) == normalizedTarget
                    || Self.normalizedApplicationName($0.app.name) == normalizedTarget
                    || Self.normalizedApplicationName($0.app.path.lastPathComponent) == normalizedTarget
            })
                ?? suggestions.first(where: {
                    let display = Self.normalizedApplicationName($0.app.displayName)
                    return display.contains(normalizedTarget) || normalizedTarget.contains(display)
                })
        else {
            return (false, "\(appName) cannot open selection", nil)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            try await NSWorkspace.shared.open(
                urls,
                withApplicationAt: suggestion.app.path,
                configuration: configuration
            )
            return (true, "Opening", suggestion.app.displayName)
        } catch {
            return (false, error.localizedDescription, suggestion.app.displayName)
        }
    }

    private func emptyBin() async -> (success: Bool, message: String) {
        await Task.detached(priority: .userInitiated) {
            let script = """
                tell application "Finder"
                    empty trash
                end tell
                """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                let message =
                    error[NSAppleScript.errorMessage] as? String
                    ?? "Could not empty Bin"
                return (false, message)
            }
            return (true, "Bin emptied")
        }.value
    }

    private func moveSelectionToBin() async -> (success: Bool, message: String) {
        await Task.detached(priority: .userInitiated) {
            let script = """
                tell application "Finder"
                    set sel to (selection as alias list)
                    if sel is {} then
                        return
                    end if
                    move sel to trash
                end tell
                """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                let message =
                    error[NSAppleScript.errorMessage] as? String
                    ?? "Could not move to Bin"
                return (false, message)
            }
            return (true, "Moved to Bin")
        }.value
    }

    private static func isEmptyBinAction(_ normalizedPath: [String]) -> Bool {
        normalizedPath.contains("empty bin")
            || normalizedPath.contains("empty trash")
    }

    private static func isMoveToBinAction(_ normalizedPath: [String]) -> Bool {
        normalizedPath.contains("move to bin")
            || normalizedPath.contains("move to trash")
    }

    private static func isOpenWithApplicationAction(_ normalizedPath: [String]) -> Bool {
        guard normalizedPath.contains("open with"),
            let leaf = normalizedPath.last,
            leaf != "open with",
            leaf != "other",
            leaf != "app store"
        else { return false }
        return true
    }

    private static func openWithApplicationName(from path: [String]) -> String? {
        guard let leaf = path.last else { return nil }
        let cleaned = leaf
            .replacingOccurrences(of: #"\s*\(default\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned
    }

    private static func selectedFinderURLs() async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let script = """
                tell application "Finder"
                    set sel to selection as alias list
                    set output to ""
                    repeat with f in sel
                        set output to output & POSIX path of f & linefeed
                    end repeat
                    return output
                end tell
                """
            var error: NSDictionary?
            guard
                let value = NSAppleScript(source: script)?.executeAndReturnError(&error)
                    .stringValue,
                error == nil
            else { return [] }
            return value
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
        }.value
    }

    private static func normalizedApplicationName(_ value: String) -> String {
        normalizedMenuText(value)
            .replacingOccurrences(of: " app", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedMenuText(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            {
                return Character(scalar)
            }
            return " "
        }
        return String(mapped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
