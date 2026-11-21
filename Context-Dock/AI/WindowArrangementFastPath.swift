import AppKit
import os

@MainActor
enum WindowArrangementFastPath {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Context-Dock",
        category: "WindowArrangementFastPath")

    private static let arrangementPatterns: [(pattern: String, command: WindowManagementService.Command)] = [
        ("split left", .left),
        ("snap left", .left),
        ("tile left", .left),
        ("move left", .left),
        ("move it left", .left),
        ("put it on the left", .left),
        ("split right", .right),
        ("snap right", .right),
        ("tile right", .right),
        ("move right", .right),
        ("move it right", .right),
        ("put it on the right", .right),
        ("maximize window", .fill),
        ("maximise window", .fill),
        ("maximize it", .fill),
        ("maximise it", .fill),
        ("maximize this", .fill),
        ("maximise this", .fill),
        ("fill screen", .fill),
        ("fill the screen", .fill),
        ("make it full screen", .fullScreen),
        ("go full screen", .fullScreen),
        ("enter full screen", .fullScreen),
        ("full screen", .fullScreen),
        ("fullscreen", .fullScreen),
        ("center window", .center),
        ("centre window", .center),
        ("center the window", .center),
        ("centre the window", .center),
        ("center it", .center),
        ("centre it", .center),
        ("minimize window", .minimize),
        ("minimise window", .minimize),
        ("minimize it", .minimize),
        ("minimise it", .minimize),
        ("minimize this", .minimize),
        ("minimise this", .minimize),
        ("tile windows", .leftAndRight),
        ("split windows", .leftAndRight),
        ("side by side", .leftAndRight),
        ("restore window", .restorePreviousSize),
        ("restore size", .restorePreviousSize),
        ("restore previous size", .restorePreviousSize),
        ("previous size", .restorePreviousSize),
        ("exit full screen", .restorePreviousSize),
        ("leave full screen", .restorePreviousSize),
        ("unmaximize", .restorePreviousSize),
        ("unmaximise", .restorePreviousSize),
        ("top left", .topLeft),
        ("top right", .topRight),
        ("bottom left", .bottomLeft),
        ("bottom right", .bottomRight),
        ("bring all to front", .bringAllToFront),
        ("bring all windows", .bringAllToFront),
    ]

    static func resolve(query: String, scope: GeneralChatScope) -> (command: WindowManagementService.Command, app: NSRunningApplication)? {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        if lower.contains("?") || lower.hasPrefix("how ") || lower.hasPrefix("what ")
            || lower.hasPrefix("can ") || lower.hasPrefix("why ") || lower.hasPrefix("when ")
            || lower.hasPrefix("where ") || lower.hasPrefix("is ") || lower.hasPrefix("does ") {
            return nil
        }

        guard let command = matchCommand(lower) else { return nil }
        guard let app = targetApp(for: scope) else { return nil }

        log.notice("fast-path: \(command.rawValue, privacy: .public) → \(app.localizedName ?? "app", privacy: .public)")
        return (command, app)
    }

    static func execute(command: WindowManagementService.Command, app: NSRunningApplication) -> AppScopedChatService.Answer {
        let appName = app.localizedName ?? "the window"
        let ok = WindowManagementService.shared.execute(command, sourceApp: app)
        let text = ok
            ? "Done — applied **\(command.title)** to \(appName)."
            : "Could not apply \(command.title) to \(appName) — the app may not have a resizable window."
        var answer = AppScopedChatService.Answer(
            text: text,
            toolChips: ["Window: \(command.title) · \(appName)"])
        answer.trace = ["Fast-path: window arrangement (0 LLM tokens)"]
        return answer
    }

    // MARK: - Internal (visible for testing)

    static func matchCommand(_ lower: String) -> WindowManagementService.Command? {
        for (pattern, command) in arrangementPatterns {
            if lower.contains(pattern) { return command }
        }
        if lower.split(separator: " ").count <= 4 {
            let matches = WindowManagementService.shared.matchingCommands(query: lower)
            if matches.count == 1 { return matches.first }
        }
        return nil
    }

    private static func targetApp(for scope: GeneralChatScope) -> NSRunningApplication? {
        if case .app(let bundleId) = scope {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        }
        if let prev = AppDelegate.shared?.previousFrontmostApp,
           prev.bundleIdentifier != Bundle.main.bundleIdentifier {
            return prev
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
    }
}
