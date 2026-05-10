//
//  UserContext.swift
//  ILauncher
//
//  User context types for AI Mode
//  Represents what the user has currently selected or focused
//

import Foundation
import AppKit
import ApplicationServices

/// User context - what the user currently has selected or focused
enum UserContext {
    case filesSelected([URL])
    case textSelected(String)
    case url(String)
    case appFocused(name: String, bundleID: String)
    case contactSelected(String)
    case none
    
    var description: String {
        switch self {
        case .filesSelected(let urls):
            return "filesSelected(\(urls.count) files)"
        case .textSelected(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = String(trimmed.prefix(80))
            return trimmed.count > 80 ? "textSelected(\(preview)… )" : "textSelected(\(preview))"
        case .url(let url):
            return "url(\(url.prefix(80)))"
        case .appFocused(let name, let bundleID):
            return "appFocused(\(name), \(bundleID))"
        case .contactSelected(let contact):
            return "contactSelected(\(contact))"
        case .none:
            return "none"
        }
    }
    
    var icon: String {
        switch self {
        case .filesSelected:
            return "doc.on.doc.fill"
        case .textSelected:
            return "doc.text.fill"
        case .url:
            return "link"
        case .appFocused:
            return "app.fill"
        case .contactSelected:
            return "person.crop.circle.fill"
        case .none:
            return "circle"
        }
    }
}

/// Context detection helper for AI Mode
/// NOTE: This detector intentionally avoids AppleScript to prevent repeated Automation prompts.
/// It delegates to the shared AX-based ContextDetector used across the app.
final class UserContextDetector {
    static let shared = UserContextDetector()
    private init() {}

    /// Detect current user context when AI Mode opens
    /// Pass in the previously frontmost app to detect context from it instead of ILauncher
    func detectCurrentContext(from app: NSRunningApplication? = nil) -> UserContext {
        print("🔍 [UserContextDetector] Starting context detection...")

        // Use provided app or fallback to current frontmost (which might be ILauncher)
        let frontmostApp: NSRunningApplication
        if let providedApp = app {
            print("🎯 [UserContextDetector] Using provided app: \(providedApp.localizedName ?? "Unknown")")
            frontmostApp = providedApp
        } else {
            guard let currentApp = NSWorkspace.shared.frontmostApplication else {
                print("⚠️ [UserContextDetector] No frontmost application. Falling back to clipboard.")
                return clipboardFallback()
            }

            // Skip ILauncher itself
            if currentApp.bundleIdentifier?.contains("ILauncher") == true {
                print("⚠️ [UserContextDetector] Frontmost app is ILauncher (should provide previous app!). Falling back to clipboard.")
                return clipboardFallback()
            }

            frontmostApp = currentApp
            print("🔍 [UserContextDetector] Using current frontmost app: \(currentApp.localizedName ?? "Unknown")")
        }

        // Use the shared detector (AX-based) to avoid AppleScript Automation prompts.
        guard let detected = ContextDetector.shared.detectContext(frontmostApp: frontmostApp) else {
            print("⚠️ [UserContextDetector] ContextDetector returned nil for \(frontmostApp.localizedName ?? "Unknown"). Falling back to clipboard.")
            return clipboardFallback()
        }

        print("✅ [UserContextDetector] Detected: \(detected.description)")

        let appName   = frontmostApp.localizedName ?? ""
        let bundleID  = frontmostApp.bundleIdentifier ?? ""

        switch detected {
        case .files(let urls):
            // Files selected → global context (selection-based)
            return .filesSelected(urls)

        case .text(let text):
            // Text selected → global context. URL on clipboard → url context.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), url.scheme != nil {
                return .url(trimmed)
            }
            return .textSelected(text)

        case .browserTab, .browserTabs:
            // User is IN a browser — enter that app's scope.
            // The current page URL is injected as additional context inside buildContextPrompt.
            return .appFocused(name: appName, bundleID: bundleID)

        case .clipboard(let text):
            // Clipboard content → global context (user copied something)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let url = URL(string: trimmed), url.scheme != nil { return .url(trimmed) }
                return .textSelected(trimmed)
            }
            // Empty clipboard → fall through to app scope
            return .appFocused(name: appName, bundleID: bundleID)

        case .app(let bid, let name):
            return .appFocused(name: name, bundleID: bid)

        default:
            // Any other detected context (music, email, note…) → app scope for that app
            return .appFocused(name: appName, bundleID: bundleID)
        }
    }

    private func clipboardFallback() -> UserContext {
        if let clipboardText = NSPasteboard.general.string(forType: .string) {
            let trimmed = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let url = URL(string: trimmed), url.scheme != nil {
                    return .url(trimmed)
                }
                return .textSelected(trimmed)
            }
        }
        return .none
    }
}
