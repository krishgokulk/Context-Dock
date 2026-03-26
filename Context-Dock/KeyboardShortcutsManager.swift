//
//  KeyboardShortcutsManager.swift
//  ILauncher
//
//  Keyboard shortcuts for common actions within the launcher
//

import Foundation
import SwiftUI
import AppKit

// MARK: - Keyboard Shortcut Actions
enum LauncherShortcutAction: String, CaseIterable {
    case openSettings = "cmd+,"
    case clearSearch = "cmd+backspace"
    case toggleAIMode = "cmd+k"
    case toggleAIExtensions = "cmd+e"
    case quickLookPreview = "space"
    case pinUnpinItem = "cmd+p"
    case copyPath = "cmd+c"
    case revealInFinder = "cmd+r"
    case openWithDefault = "enter"
    case openWith = "cmd+o"
    case deleteItem = "cmd+delete"

    var description: String {
        switch self {
        case .openSettings: return "Open Settings"
        case .clearSearch: return "Clear Search"
        case .toggleAIMode: return "Toggle AI Chat Mode"
        case .toggleAIExtensions: return "AI Extension Suggestions"
        case .quickLookPreview: return "Quick Look Preview"
        case .pinUnpinItem: return "Pin/Unpin Item"
        case .copyPath: return "Copy Path"
        case .revealInFinder: return "Reveal in Finder"
        case .openWithDefault: return "Open with Default App"
        case .openWith: return "Open With..."
        case .deleteItem: return "Move to Trash"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .openSettings: return ","
        case .clearSearch: return String(UnicodeScalar(NSBackspaceCharacter)!)
        case .toggleAIMode: return "k"
        case .toggleAIExtensions: return "e"
        case .quickLookPreview: return " "
        case .pinUnpinItem: return "p"
        case .copyPath: return "c"
        case .revealInFinder: return "r"
        case .openWithDefault: return "\r"
        case .openWith: return "o"
        case .deleteItem: return String(UnicodeScalar(NSDeleteCharacter)!)
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .openSettings, .clearSearch, .toggleAIMode, .toggleAIExtensions, .pinUnpinItem, .copyPath, .revealInFinder, .openWith, .deleteItem:
            return .command
        case .quickLookPreview, .openWithDefault:
            return []
        }
    }
}

// MARK: - Keyboard Shortcuts Handler
class KeyboardShortcutsHandler {
    static let shared = KeyboardShortcutsHandler()

    private init() {}

    /// Handle keyboard event and return true if handled
    func handleKeyEvent(_ event: NSEvent, for selectedResult: SearchResult?) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Quick Look (Space)
        if event.keyCode == 49 && flags.isEmpty { // Space key
            if let filePath = selectedResult?.filePath {
                QuickLookPreviewManager.shared.showPreview(for: filePath)
                return true
            }
        }

        // Command+K - Toggle AI Chat Mode
        if flags == .command && event.charactersIgnoringModifiers == "k" {
            NotificationCenter.default.post(name: .toggleAIMode, object: nil)
            return true
        }

        // Command+E - Toggle AI Extension Suggestions
        if flags == .command && event.charactersIgnoringModifiers == "e" {
            NotificationCenter.default.post(name: .toggleAIExtensions, object: nil)
            return true
        }

        // Command+, - Open Settings
        if flags == .command && event.charactersIgnoringModifiers == "," {
            NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            return true
        }

        // Command+Backspace - Clear Search
        if flags == .command && event.keyCode == 51 { // Backspace
            NotificationCenter.default.post(name: .clearSearchRequested, object: nil)
            return true
        }

        // Command+P - Pin/Unpin
        if flags == .command && event.charactersIgnoringModifiers == "p" {
            if let result = selectedResult {
                NotificationCenter.default.post(name: .pinUnpinRequested, object: result)
                return true
            }
        }

        // Command+C - Copy Path
        if flags == .command && event.charactersIgnoringModifiers == "c" {
            if let filePath = selectedResult?.filePath {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(filePath, forType: .string)
                return true
            }
        }

        // Command+R - Reveal in Finder
        if flags == .command && event.charactersIgnoringModifiers == "r" {
            if let filePath = selectedResult?.filePath {
                NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
                return true
            }
        }

        // Command+O - Open With
        if flags == .command && event.charactersIgnoringModifiers == "o" {
            if let filePath = selectedResult?.filePath {
                let url = URL(fileURLWithPath: filePath)
                NSWorkspace.shared.open(url)
                return true
            }
        }

        return false
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let toggleAIMode = Notification.Name("toggleAIMode")
    static let toggleAIExtensions = Notification.Name("toggleAIExtensions")
    static let openSettingsRequested = Notification.Name("openSettingsRequested")
    static let clearSearchRequested = Notification.Name("clearSearchRequested")
    static let pinUnpinRequested = Notification.Name("pinUnpinRequested")
    // launcherWindowOpened already defined in ContentView.swift
}
