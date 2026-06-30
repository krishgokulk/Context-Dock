import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class BrowserNativeCommandService {
    static let shared = BrowserNativeCommandService()

    private init() {}

    enum Command: String, CaseIterable {
        case nextTab
        case previousTab
        case back
        case forward
        case reload
        case newTab
        case closeTab

        var title: String {
            switch self {
            case .nextTab: return "Next Tab"
            case .previousTab: return "Previous Tab"
            case .back: return "Back"
            case .forward: return "Forward"
            case .reload: return "Reload"
            case .newTab: return "New Tab"
            case .closeTab: return "Close Tab"
            }
        }

        var subtitle: String { "Native browser command" }

        var icon: String {
            switch self {
            case .nextTab: return "arrow.right.square"
            case .previousTab: return "arrow.left.square"
            case .back: return "chevron.left"
            case .forward: return "chevron.right"
            case .reload: return "arrow.clockwise"
            case .newTab: return "plus.square.on.square"
            case .closeTab: return "xmark.square"
            }
        }

        var shortcutLabel: String {
            switch self {
            case .nextTab: return "⌃⇥"
            case .previousTab: return "⌃⇧⇥"
            case .back: return "⌘["
            case .forward: return "⌘]"
            case .reload: return "⌘R"
            case .newTab: return "⌘T"
            case .closeTab: return "⌘W"
            }
        }

        var aliases: [String] {
            switch self {
            case .nextTab:
                return ["next tab", "next", "tab next", "right tab", "switch next tab", "show next tab"]
            case .previousTab:
                return ["previous tab", "prev tab", "previous", "prev", "last tab", "left tab", "switch previous tab", "show previous tab"]
            case .back:
                return ["back", "go back", "browser back", "previous page"]
            case .forward:
                return ["forward", "go forward", "browser forward", "next page"]
            case .reload:
                return ["reload", "refresh", "reload page", "refresh page"]
            case .newTab:
                return ["new tab", "open new tab", "create tab"]
            case .closeTab:
                return ["close tab", "close current tab", "delete tab"]
            }
        }

        var keyCode: CGKeyCode {
            switch self {
            case .nextTab, .previousTab: return 48
            case .back: return 33
            case .forward: return 30
            case .reload: return 15
            case .newTab: return 17
            case .closeTab: return 13
            }
        }

        var flags: CGEventFlags {
            switch self {
            case .nextTab:
                return .maskControl
            case .previousTab:
                return CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue)
            case .back, .forward, .reload, .newTab, .closeTab:
                return .maskCommand
            }
        }

        func matches(_ normalizedQuery: String) -> Bool {
            guard !normalizedQuery.isEmpty else { return false }
            let words = Set(normalizedQuery.split(separator: " ").map(String.init))
            if aliases.contains(where: { $0 == normalizedQuery || $0.hasPrefix(normalizedQuery) }) {
                return true
            }
            switch self {
            case .nextTab:
                return words.contains("tab") && (words.contains("next") || words.contains("right"))
            case .previousTab:
                return words.contains("tab") && (words.contains("previous") || words.contains("prev") || words.contains("left") || words.contains("last"))
            case .back:
                return normalizedQuery == "back" || normalizedQuery == "go back"
            case .forward:
                return normalizedQuery == "forward" || normalizedQuery == "go forward"
            case .reload:
                return normalizedQuery == "reload" || normalizedQuery == "refresh"
            case .newTab:
                return words.contains("tab") && (words.contains("new") || words.contains("create") || words.contains("open"))
            case .closeTab:
                return words.contains("tab") && (words.contains("close") || words.contains("delete"))
            }
        }
    }

    func matchingCommands(for query: String) -> [Command] {
        let normalized = Self.normalized(query)
        guard !normalized.isEmpty else { return [] }
        return Command.allCases.filter { $0.matches(normalized) }
    }

    func execute(_ command: Command, bundleIdentifier: String, appName: String) {
        guard MenuExecutionCoordinator.ensureAccessibilityTrustOrPrompt() else { return }
        guard let app = runningBrowser(bundleIdentifier: bundleIdentifier) else {
            AppToast.show("\(appName) is not running", icon: "exclamationmark.triangle", tint: .orange)
            return
        }

        AppDelegate.shared?.hideLauncher(force: true)
        let feedbackId = DockActionFeedback.start(
            command.title,
            subject: appName,
            icon: command.icon,
            tint: .blue,
            bundleID: bundleIdentifier
        )
        app.activate(options: [.activateIgnoringOtherApps])

        let pid = app.processIdentifier
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            Self.postKey(command.keyCode, flags: command.flags, to: pid)
            DockActionFeedback.complete(
                feedbackId,
                label: "\(command.title) sent",
                subject: appName,
                bundleID: bundleIdentifier
            )
        }
    }

    private func runningBrowser(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
