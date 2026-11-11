#if DEBUG
import AppKit

/// Scriptable summon for hand checks. DEBUG only.
///
/// ⌘⌘ and ⌥⌥ are read from a global `flagsChanged` monitor, which synthetic key events from
/// an agent's input tools never reach — so an agent could not open the Corner at all and
/// spent its hand checks guessing. `scripts/corner.sh <command>` posts a distributed
/// notification that lands here and calls the same entry points the hotkeys call.
///
/// After every command the resulting state is written to `corner-state.json` beside
/// `turns.log`, so "did it open, where, in which scope" is read, not guessed from pixels.
@MainActor
enum DevCornerRemote {
    static let notificationName = Notification.Name("com.krishgokul.ContextDock.dev.corner")
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: notificationName, object: nil, queue: .main
        ) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command) }
        }
    }

    static func run(_ raw: String) {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let command = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        let controller = CornerDockController.shared
        let presentation = controller.chatPresentation
        DoraXTurnLog.record("dev.corner \(command)")

        switch command {
        case "centre", "center":
            controller.showCentred()
        case "bottom":
            // Leaving the centre resets its placement on the next main-actor hop; open the
            // bottom dock after that, or it opens in the middle again.
            if presentation.isCentred { presentation.dismiss() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                AppDelegate.shared?.openBottomAppChat()
            }
        case "global":
            presentation.showGlobalContext()
            controller.armKeyboard()
        case "general":
            presentation.showGeneralFromPreview()
            controller.armKeyboard()
        case "cmd":
            presentation.applyCommandTap()
        case "ask":
            controller.prompt.query = argument
            _ = controller.prompt.submit()
        case "hide":
            presentation.dismiss()
        case "state":
            break
        default:
            DoraXTurnLog.record("dev.corner unknown command \(raw)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { writeState(after: raw) }
    }

    private static func writeState(after command: String) {
        let controller = CornerDockController.shared
        let presentation = controller.chatPresentation
        let prompt = controller.prompt
        let state: [String: Any] = [
            "after": command,
            "visible": presentation.isVisible,
            "centred": presentation.isCentred,
            "autoHidden": controller.isAutoHidden,
            "mode": "\(presentation.mode)",
            "focus": "\(presentation.surfaceFocus)",
            "onScreen": controller.isCornerChatVisible && !controller.isAutoHidden,
            "phase": "\(prompt.phase)",
            "shellWidth": Double(DockShellWidth.current),
            "app": prompt.appName,
            "query": prompt.query,
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Context-Dock"),
            let data = try? JSONSerialization.data(
                withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: directory.appendingPathComponent("corner-state.json"), options: .atomic)
    }
}
#endif
