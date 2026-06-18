import AppKit
import SwiftUI

@MainActor
struct SelectionCommandBuilder {
    struct Actions {
        let askAI: (String, SelectionContextSnapshot) -> Void
        let executeExtension: (ILExtension, UserContext) -> Void
        let executeShortcutMenuCommand: (ShortcutMenuCommand) -> Void
        let executeFinderSelectionMenuAction: (String) -> Void
        let showQuickLookURL: (URL) -> Bool
        let presentSharingPicker: ([Any]) -> Void
        let createPDFFromImages: ([URL]) -> Void
    }

    static func allCommands(
        for snapshot: SelectionContextSnapshot,
        providerName: String,
        liveMenuItems: [AXMenuItem],
        shortcutSheetSourcePID: pid_t,
        normalize: (String) -> String,
        actions: Actions
    ) -> [SelectionSheetCommand] {
        var commands = writingToolCommands(
            providerName: providerName,
            snapshot: snapshot,
            actions: actions
        )

        commands.append(contentsOf: fileActions(for: snapshot, actions: actions))
        commands.append(contentsOf: finderContextualActions(
            for: snapshot,
            normalize: normalize,
            actions: actions
        ))

        let matches = LayeredExtensionManager.shared.discoverExtensions(
            for: "",
            selectedFiles: snapshot.selectedFiles,
            selectedText: snapshot.selectedText,
            frontmostApp: snapshot.sourceAppName,
            layer: .l2_context
        )
        for match in matches.prefix(8) {
            let ext = match.ilExtension
            commands.append(SelectionSheetCommand(
                id: "ext-\(ext.id)",
                title: ext.name,
                subtitle: ext.description,
                section: "Extensions",
                systemImage: ext.icon,
                shortcutDisplay: nil,
                score: 8_000 + match.relevanceScore,
                action: { actions.executeExtension(ext, snapshot.userContext) }
            ))
        }

        let menuCommands = ShortcutMenuCommand.commands(
            from: liveMenuItems,
            query: "",
            fallbackSourcePID: shortcutSheetSourcePID
        ).filter {
            isFileMenuCommand($0) || isExtensionMenuCommand($0, normalize: normalize)
        }
        for command in menuCommands.prefix(24) {
            let isExtensionAction = isExtensionMenuCommand(command, normalize: normalize)
            commands.append(SelectionSheetCommand(
                id: "menu-\(command.id)",
                title: command.title,
                subtitle: command.parentPath.isEmpty ? snapshot.sourceAppName : command.parentPath,
                section: isExtensionAction ? "Extensions" : "File Menu",
                systemImage: isExtensionAction ? "sparkles.rectangle.stack" : "menubar.rectangle",
                shortcutDisplay: command.shortcutDisplay,
                score: (isExtensionAction ? 6_200 : 1_000) + command.score,
                action: { actions.executeShortcutMenuCommand(command) }
            ))
        }

        return dedupe(commands, normalize: normalize)
    }

    static func dedupe(
        _ commands: [SelectionSheetCommand],
        normalize: (String) -> String
    ) -> [SelectionSheetCommand] {
        var seen = Set<String>()
        var result: [SelectionSheetCommand] = []
        for command in commands.sorted(by: { $0.score > $1.score }) {
            let key = [
                normalize(command.section),
                normalize(command.title),
                normalize(command.subtitle),
            ].joined(separator: "|")
            guard seen.insert(key).inserted else { continue }
            result.append(command)
        }
        return result.sorted(by: { $0.score > $1.score })
    }

    static func finderContextualActions(
        for snapshot: SelectionContextSnapshot,
        normalize: (String) -> String,
        actions: Actions
    ) -> [SelectionSheetCommand] {
        let urls = snapshot.selectedFiles
        guard !urls.isEmpty, snapshot.sourceBundleID == "com.apple.finder" else { return [] }
        let contextualActions = FinderContextualMenuActionSource.shared.cachedActions(for: urls)
        return contextualActions.prefix(32).map { action in
            let parts = action.path.map(normalize)
            let isQuickAction = parts.contains("quick actions")
            let section = isQuickAction ? "Quick Actions" : "Services"
            let copiedURLs = urls
            return SelectionSheetCommand(
                id: "finder-contextual-\(action.id)",
                title: action.title,
                subtitle: section,
                section: section,
                systemImage: isQuickAction ? "sparkles.rectangle.stack" : "gearshape.2",
                shortcutDisplay: nil,
                score: isQuickAction ? 7_250 : 7_000,
                action: {
                    let ok = FinderContextualMenuActionSource.shared.execute(
                        action,
                        selectedURLs: copiedURLs
                    )
                    if !ok {
                        actions.executeFinderSelectionMenuAction(action.title)
                    }
                }
            )
        }
    }

    static func fileActions(
        for snapshot: SelectionContextSnapshot,
        actions: Actions
    ) -> [SelectionSheetCommand] {
        let urls = snapshot.selectedFiles
        guard !urls.isEmpty else { return [] }
        let first = urls[0]
        var commands: [SelectionSheetCommand] = []

        func add(
            _ id: String,
            _ title: String,
            _ icon: String,
            _ score: Double,
            _ action: @escaping () -> Void
        ) {
            commands.append(SelectionSheetCommand(
                id: "file-\(id)",
                title: title,
                subtitle: "File",
                section: "Actions",
                systemImage: icon,
                shortcutDisplay: nil,
                score: score,
                action: action
            ))
        }

        add("open", "Open", "arrow.up.right.square", 7_000) {
            for url in urls { NSWorkspace.shared.open(url) }
        }
        add("quicklook", "Quick Look", "eye", 6_950) {
            _ = actions.showQuickLookURL(first)
        }
        add("reveal", "Reveal in Finder", "folder", 6_900) {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        add("copypath", "Copy Path", "doc.on.clipboard", 6_850) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                urls.map(\.path).joined(separator: "\n"),
                forType: .string
            )
        }
        add("share", "Share…", "square.and.arrow.up", 6_800) {
            actions.presentSharingPicker(urls)
        }
        if urls.allSatisfy({
            ["jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "webp"]
                .contains($0.pathExtension.lowercased())
        }) {
            add("create-pdf", "Create PDF", "doc.richtext", 6_780) {
                actions.createPDFFromImages(urls)
            }
        }
        add("trash", "Move to Bin", "trash", 6_700) {
            for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            AppToast.show("Moved to Bin", icon: "trash", tint: .red.opacity(0.9))
        }

        let openWithApps = DefaultAppResolver.shared.getAllApps(for: first).prefix(10)
        for (index, app) in openWithApps.enumerated() {
            let appURL = app.path
            let appIcon = app.icon ?? NSWorkspace.shared.icon(forFile: appURL.path)
            commands.append(SelectionSheetCommand(
                id: "file-openwith-\(app.bundleIdentifier)",
                title: "Open With \(app.displayName)",
                subtitle: "Open With",
                section: "Open With",
                systemImage: "app",
                iconImage: appIcon,
                shortcutDisplay: nil,
                score: 6_600 - Double(index),
                action: {
                    let config = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
                }
            ))
        }
        return commands
    }

    static func isFileMenuCommand(_ command: ShortcutMenuCommand) -> Bool {
        let section = command.section.trimmingCharacters(in: .whitespacesAndNewlines)
        if section.localizedCaseInsensitiveCompare("File") == .orderedSame { return true }
        guard let root = command.item.path.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return root.localizedCaseInsensitiveCompare("File") == .orderedSame
    }

    static func isExtensionMenuCommand(
        _ command: ShortcutMenuCommand,
        normalize: (String) -> String
    ) -> Bool {
        let parts = command.item.path.map { normalize($0) }
        return parts.contains("quick actions")
            || parts.contains("services")
            || parts.contains("share")
    }

    private static func writingToolCommands(
        providerName: String,
        snapshot: SelectionContextSnapshot,
        actions: Actions
    ) -> [SelectionSheetCommand] {
        let writingTools: [(id: String, title: String, icon: String, prompt: String, score: Double)] = [
            ("ai-what-is-this", "What is this?", "sparkles", "What is this?", 10_000),
            ("ai-summarize", "Summarize", "text.alignleft", "Summarize this selection concisely.", 9_950),
            ("ai-key-points", "Key Points", "list.bullet", "Extract the key points of this selection as a short bulleted list.", 9_900),
            ("ai-rewrite", "Rewrite", "pencil.line", "Rewrite this selection to be clearer and well-structured. Return only the rewritten text.", 9_850),
            ("ai-simplify", "Simplify", "wand.and.stars", "Rewrite this selection in simpler, plain language. Return only the rewritten text.", 9_800),
            ("ai-make-professional", "Make Professional", "briefcase", "Rewrite this selection in a professional tone. Return only the rewritten text.", 9_750),
            ("ai-translate", "Translate", "character.bubble", "Translate this selection to English. If it is already English, translate to the user's likely preferred language. Return only the translation.", 9_700),
            ("ai-explain", "Explain", "questionmark.bubble", "Explain this selection clearly.", 9_650),
        ]
        return writingTools.map { tool in
            SelectionSheetCommand(
                id: tool.id,
                title: tool.title,
                subtitle: providerName,
                section: "Writing Tools",
                systemImage: tool.icon,
                shortcutDisplay: nil,
                score: tool.score,
                action: { actions.askAI(tool.prompt, snapshot) }
            )
        }
    }
}
