import Foundation

@MainActor
struct SelectionShortcutCoordinator {
    struct DockActivation {
        let context: UserContext
        let globalActivation: GlobalContextActivation
        let showContextInDock: Bool
        let aiModeActive: Bool
        let query: String
    }

    static func executeShortcutMenuCommand(
        _ command: ShortcutMenuCommand,
        fallbackSourcePID: pid_t,
        closeSheet: () -> Void,
        executeMenuAction: (_ sourcePID: pid_t, _ path: [String], _ shortcutChar: String?, _ shortcutModifiers: Int) -> Void
    ) {
        closeSheet()
        let item = command.item
        let pid = item.sourcePID != 0 ? item.sourcePID : fallbackSourcePID
        guard pid != 0 else { return }
        executeMenuAction(pid, item.path, item.shortcutChar, item.shortcutModifiers)
    }

    static func executeSelectionCommand(
        _ command: SelectionSheetCommand,
        closeSheet: () -> Void
    ) {
        closeSheet()
        command.action()
    }

    static func dockActivation(
        for snapshot: SelectionContextSnapshot,
        startAI: Bool,
        prompt: String
    ) -> DockActivation {
        DockActivation(
            context: snapshot.userContext,
            globalActivation: GlobalContextActivation(
                autoActivated: false,
                frozenText: snapshot.title,
                frozenIcon: snapshot.iconName,
                sourceBundleId: snapshot.sourceBundleID,
                frozenFilePaths: snapshot.selectedFiles.map(\.path)
            ),
            showContextInDock: true,
            aiModeActive: startAI,
            query: prompt
        )
    }
}
