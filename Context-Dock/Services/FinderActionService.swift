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
