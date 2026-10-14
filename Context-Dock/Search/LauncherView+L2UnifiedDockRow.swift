import SwiftUI

extension LauncherView {











    /// Whether the result sheet is revealed. The rows stay MOUNTED either way: building the
    /// list only when ↓ is pressed rebuilt view identity at exactly the moment the window was
    /// animating, which is the stutter this replaces. Compact simply clips them to zero.
    var isDockResultSheetRevealed: Bool {
        // Surfaces that ARE their result list — they have no compact form to fall back to,
        // so gating them left a half-drawn or transparent shell. Listed once, here, because
        // the sheet's height, its chrome and the ↓ handler must all agree.
        if hasSelectionScopeSurface || isFinderDesktopOnlyMode || isInCLIToolScope
            || isCompactSmartScope || isContextDockChatRoutingLocked
        {
            return true
        }
        // A System Command / CLI extension scope draws its own rows (Bluetooth devices, a
        // tool's output) — the scope IS the sheet.
        if let bundle = currentGlobalScopedBundleID,
            bundle.hasPrefix("syscmd://") || bundle.hasPrefix("cli://")
        {
            return true
        }
        // Pure Global Context has its own phase-driven reveal in l2GlobalSearchListContent.
        if isGlobalContextActive, !isActiveGlobalRunningAppMenuScope() { return true }
        return globalContextViewModel.scopedSheetExpanded
    }


    /// The scoped SystemCommand when the user is inside a provider:notepad scope,
    /// else nil. Drives the Quick Note split editor surface.
    var activeNotepadScopeCommand: SystemCommand? {
        guard isGlobalContextActive,
            let bundle = currentGlobalScopedBundleID,
            bundle.hasPrefix("syscmd://"),
            let id = UUID(uuidString: String(bundle.dropFirst("syscmd://".count))),
            let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == id }),
            command.keywords.contains(where: { $0.lowercased() == "provider:notepad" })
        else { return nil }
        return command
    }





}
