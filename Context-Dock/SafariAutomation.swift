//
//  SafariAutomation.swift
//  ILauncher
//
//  Safari automation actions - PDF saving, bookmarking, etc.
//

import Foundation
import AppKit

class SafariAutomation {
    static let shared = SafariAutomation()

    private init() {}

    // MARK: - PDF Export

    /// Save current Safari page as PDF
    /// Returns the file path where PDF was saved
    func saveCurrentPageAsPDF(fileName: String? = nil) -> Result<String, SafariError> {
        // Determine save location and filename
        let downloadsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~/Downloads"
        let timestamp = Date().timeIntervalSince1970
        let defaultFileName = fileName ?? "webpage_\(Int(timestamp))"
        let savePath = "\(downloadsPath)/\(defaultFileName).pdf"

        print("📄 [SafariAutomation] Attempting to save PDF to: \(savePath)")

        // Use File > Export as PDF — more reliable than Cmd+P sheet automation
        let script = """
        tell application "Safari"
            activate
            delay 0.4
        end tell

        tell application "System Events"
            tell process "Safari"
                -- Try File > Export as PDF menu item
                try
                    click menu bar item "File" of menu bar 1
                    delay 0.3
                    click menu item "Export as PDF…" of menu "File" of menu bar 1
                    delay 1.2

                    -- Save panel is now open — type the path and hit Save
                    keystroke "g" using {command down, shift down}
                    delay 0.4
                    keystroke "\(savePath)"
                    delay 0.3
                    keystroke return
                    delay 0.4
                    keystroke return
                    delay 0.5
                    return "success"
                on error exportErr
                    -- Fallback: Cmd+P → PDF sheet
                    try
                        keystroke "p" using command down
                        delay 1.5
                        -- sheet 1 of front window contains the PDF button
                        click menu button "PDF" of sheet 1 of window 1
                        delay 0.4
                        click menu item "Save as PDF…" of menu 1 of menu button "PDF" of sheet 1 of window 1
                        delay 1.0
                        keystroke "g" using {command down, shift down}
                        delay 0.4
                        keystroke "\(savePath)"
                        delay 0.3
                        keystroke return
                        delay 0.4
                        keystroke return
                        delay 0.5
                        return "success"
                    on error fallbackErr
                        return "dialog_opened: " & fallbackErr
                    end try
                end try
            end tell
        end tell
        """

        guard let result = runAppleScript(script) else {
            return .failure(.scriptExecutionFailed)
        }

        if result.contains("success") {
            print("✅ [SafariAutomation] PDF saved successfully")
            return .success(savePath)
        } else if result.contains("dialog_opened") {
            print("⚠️ [SafariAutomation] Save dialog opened, manual completion needed")
            return .success("Save dialog opened - please complete manually")
        } else {
            return .failure(.saveFailed(result))
        }
    }

    /// Alternative: Use macOS printing system directly with better control
    func exportPageAsPDF() -> Result<String, SafariError> {
        print("📄 [SafariAutomation] Using alternative PDF export method")

        let script = """
        on run
            tell application "Safari"
                activate
                delay 0.2

                -- Get current page info
                set pageURL to URL of current tab of front window
                set pageTitle to name of current tab of front window

                -- Trigger print with Cmd+P
                tell application "System Events"
                    tell process "Safari"
                        keystroke "p" using command down
                    end tell
                end tell

                delay 1.5

                -- The print dialog is now open - user will see PDF option
                return "dialog_opened|" & pageTitle & "|" & pageURL
            end tell
        end run
        """

        guard let result = runAppleScript(script) else {
            return .failure(.scriptExecutionFailed)
        }

        if result.contains("dialog_opened") {
            let parts = result.components(separatedBy: "|")
            if parts.count >= 2 {
                print("✅ [SafariAutomation] Print dialog opened for: \(parts[1])")
            }
            return .success("Print dialog opened - use PDF button in bottom-left corner to save")
        }

        return .failure(.saveFailed(result))
    }

    // MARK: - Page Actions

    /// Get current page title and URL
    func getCurrentPage() -> (title: String, url: String)? {
        let script = """
        tell application "Safari"
            if (count of windows) > 0 then
                set currentTab to current tab of front window
                set pageTitle to name of currentTab
                set pageURL to URL of currentTab
                return pageTitle & "|||" & pageURL
            end if
        end tell
        """

        guard let result = runAppleScript(script), !result.isEmpty else {
            return nil
        }

        let parts = result.components(separatedBy: "|||")
        guard parts.count == 2 else { return nil }

        return (title: parts[0], url: parts[1])
    }

    /// Open Safari's File → Export as PDF menu
    func openExportMenu() -> Bool {
        let script = """
        tell application "Safari"
            activate
            delay 0.2
        end tell

        tell application "System Events"
            tell process "Safari"
                -- Click File menu
                click menu bar item "File" of menu bar 1
                delay 0.3

                -- Click "Export as PDF..."
                try
                    click menu item "Export as PDF…" of menu "File" of menu bar 1
                    return "success"
                on error
                    -- Fallback: use keyboard shortcut if menu item exists
                    keystroke "p" using {command down, shift down}
                    return "shortcut"
                end try
            end tell
        end tell
        """

        if let result = runAppleScript(script), result.contains("success") || result.contains("shortcut") {
            print("✅ [SafariAutomation] Export menu opened")
            return true
        }

        return false
    }

    // MARK: - Helper

    // NSAppleScript MUST run on the main thread — dispatch if needed
    private func runAppleScript(_ script: String) -> String? {
        if Thread.isMainThread {
            return runAppleScriptOnMain(script)
        } else {
            var result: String?
            DispatchQueue.main.sync { result = self.runAppleScriptOnMain(script) }
            return result
        }
    }

    private func runAppleScriptOnMain(_ script: String) -> String? {
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            print("❌ [SafariAutomation] Failed to create AppleScript object")
            return nil
        }
        let output = scriptObject.executeAndReturnError(&error)
        if let error = error {
            print("❌ [SafariAutomation] AppleScript error: \(error)")
            return nil
        }
        return output.stringValue
    }

    // MARK: - Error Types

    enum SafariError: Error, LocalizedError {
        case scriptExecutionFailed
        case saveFailed(String)
        case notInSafari

        var errorDescription: String? {
            switch self {
            case .scriptExecutionFailed:
                return "Failed to execute Safari automation script"
            case .saveFailed(let reason):
                return "PDF save failed: \(reason)"
            case .notInSafari:
                return "Not currently in Safari"
            }
        }
    }
}
