import AppKit
import Foundation
import SwiftUI

private final class SelectionExtensionRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}

extension LauncherView {
    func prewarmFinderContextualActionsForSelection(delayNanoseconds: UInt64 = 180_000_000) {
        let selectedURLs = effectiveFinderSelectionURLsForPills()
        guard !selectedURLs.isEmpty else { return }
        guard !FinderContextualMenuActionSource.shared.hasFreshCache(for: selectedURLs) else {
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard self.isGlobalContextActive, self.hasActiveDockContextSelection else { return }

            let currentURLs = self.effectiveFinderSelectionURLsForPills()
            guard !currentURLs.isEmpty else { return }
            guard !FinderContextualMenuActionSource.shared.hasFreshCache(for: currentURLs) else {
                return
            }

            let actions = FinderContextualMenuActionSource.shared.actions(for: currentURLs)
            guard !actions.isEmpty else { return }

            self.scheduleDockPillRebuild(
                query: self.searchState.query,
                delayNanoseconds: 0,
                refreshContext: false
            )
        }
    }

    func buildMacOSExtensionActionPills(
        query rawQuery: String,
        excludingTitles: Set<String> = []
    ) -> [DockPill] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let services = buildServicesActionSourcePills(
            query: query,
            excludingTitles: excludingTitles
        )
        let serviceTitles = excludingTitles.union(
            services.map { normalizedDockPillText($0.name) }
        )
        let finderQuickActions = buildFinderQuickActionSourcePills(
            query: query,
            excludingTitles: serviceTitles
        )
        let finderTitles = serviceTitles.union(
            finderQuickActions.map { normalizedDockPillText($0.name) }
        )
        let sharing = buildSharingActionSourcePills(
            query: query,
            excludingTitles: finderTitles
        )
        let shortcutTitles = finderTitles.union(
            sharing.map { normalizedDockPillText($0.name) }
        )
        let shortcuts = buildShortcutsActionSourcePills(
            query: query,
            excludingTitles: shortcutTitles
        )
        let appIntentTitles = shortcutTitles.union(
            shortcuts.map { normalizedDockPillText($0.name) }
        )
        let appIntents = buildAppIntentsActionSourcePills(
            query: query,
            excludingTitles: appIntentTitles
        )

        return services + finderQuickActions + sharing + shortcuts + appIntents
    }

    func buildFinderQuickActionSourcePills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        buildFinderFilePills(query: query).compactMap { pill in
            let title = normalizedDockPillText(pill.name)
            guard !excludingTitles.contains(title) else { return nil }
            var copy = pill
            if copy.rankingKind.isEmpty || copy.rankingKind == "finderSelection" {
                copy.rankingKind = "finderQuickAction"
            }
            copy.sourceBundleId = copy.sourceBundleId.isEmpty ? "com.apple.finder" : copy.sourceBundleId
            copy.sourceAppName = copy.sourceAppName.isEmpty ? "Finder" : copy.sourceAppName
            copy.menuContext = copy.menuContext ?? "Finder"
            copy.trackingIdentifier =
                copy.trackingIdentifier.isEmpty
                ? "finder-quick-action:\(title)"
                : copy.trackingIdentifier
            if copy.searchTerms.isEmpty {
                copy.searchTerms = [copy.name, copy.badge ?? "", "finder", "quick action", "file"]
            } else {
                copy.searchTerms.append(contentsOf: ["finder", "quick action", "file"])
            }
            copy.rankingScore = max(copy.rankingScore, 1_400)
            return copy
        }
    }

    func buildServicesActionSourcePills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        let contextualPills = buildFinderContextualMenuActionPills(
            query: query,
            excludingTitles: excludingTitles
        )
        if !contextualPills.isEmpty {
            return contextualPills
        }

        return buildFinderSelectionMenuPills(
            query: query,
            excludingTitles: excludingTitles,
            allowedRootNames: ["services", "quick actions"]
        ).map { pill in
            var copy = pill
            copy.rankingKind = "servicesAction"
            copy.menuContext = copy.menuContext ?? "Services"
            copy.searchTerms.append(contentsOf: ["services", "quick actions", "macos extension"])
            copy.rankingScore = max(copy.rankingScore, 1_250)
            return copy
        }
    }

    func buildFinderContextualMenuActionPills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        let selectedURLs = effectiveFinderSelectionURLsForPills()
        guard !selectedURLs.isEmpty else { return [] }
        let normalizedQuery = normalizedDockPillText(query)
        let actions: [FinderContextualMenuAction] = {
            if FinderContextualMenuActionSource.shared.hasFreshCache(for: selectedURLs) {
                return FinderContextualMenuActionSource.shared.cachedActions(for: selectedURLs)
            }
            guard normalizedQuery.count >= 2 else { return [] }
            return FinderContextualMenuActionSource.shared.actions(for: selectedURLs)
        }()

        return actions.compactMap { action -> DockPill? in
            let normalizedTitle = normalizedDockPillText(action.title)
            guard !normalizedTitle.isEmpty, !excludingTitles.contains(normalizedTitle) else {
                return nil
            }
            guard macOSExtensionActionMatches(query: normalizedQuery, terms: [action.title] + action.path)
            else { return nil }

            let pathParts = action.path.map(normalizedDockPillText)
            let isQuickAction = pathParts.contains("quick actions")
            let badge = isQuickAction ? "Quick Actions" : "Services"
            let selectedCopy = selectedURLs
            var pill = DockPill(
                id: "finder-contextual-\(action.id)",
                name: action.title,
                icon: isQuickAction ? "sparkles.rectangle.stack" : "gearshape.2",
                accentColorName: isQuickAction ? "purple" : "gray",
                badge: badge,
                execute: {
                    let ok = FinderContextualMenuActionSource.shared.execute(action, selectedURLs: selectedCopy)
                    if !ok {
                        executeFinderSelectionMenuAction(titleContains: action.title)
                    }
                }
            )
            pill.sourceBundleId = "com.apple.finder"
            pill.sourceAppName = "Finder"
            pill.menuContext = badge
            pill.rankingKind = isQuickAction ? "finderQuickAction" : "servicesAction"
            pill.isEnabled = action.isEnabled
            pill.hasLiveAvailability = true
            pill.trackingIdentifier = "finder-contextual:\(action.id)"
            pill.searchTerms = action.path + ["finder", "selection", "quick actions", "services"]
            pill.rankingScore = isQuickAction ? 1_350 : 1_250
            return pill
        }
    }

    func buildSharingActionSourcePills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        let context = effectiveShareAXContext()
        let items = ShareIntentRouter.shared.shareableItems(for: context)
        guard !items.isEmpty else { return [] }

        let normalizedQuery = normalizedDockPillText(query)
        let services = NSSharingService.sharingServices(forItems: items)
        return services.compactMap { service -> DockPill? in
            let title = service.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let normalizedTitle = normalizedDockPillText(title)
            guard !excludingTitles.contains(normalizedTitle) else { return nil }
            guard macOSExtensionActionMatches(
                query: normalizedQuery,
                terms: [title, "share", "send", "sharing", service.menuItemTitle]
            ) else { return nil }

            var pill = DockPill(
                id: "sharing-action-\(normalizedTitle)",
                name: title,
                icon: "square.and.arrow.up",
                accentColorName: "blue",
                badge: "Share",
                execute: {
                    // Resolve the payload while the source app context is still available.
                    let freshItems = liveShareItems()
                    guard !freshItems.isEmpty else {
                        AppToast.show(
                            "Nothing to share",
                            icon: "exclamationmark.triangle",
                            tint: .orange
                        )
                        return
                    }
                    // Share-EXTENSION targets (Freeform/Notes/Reminders…) render their own
                    // compose sheet, which needs a host window to anchor to. Hiding the
                    // launcher FIRST left the extension nothing to present into, so the app
                    // just opened without the content. Keep the overlay as the source window
                    // and dismiss it only once the share reports back.
                    ShareActionCoordinator.shared.performDirectShare(
                        service,
                        items: freshItems,
                        title: title
                    ) {
                        forceHideLauncherAfterResultExecution()
                    }
                }
            )
            pill.menuItemImage = service.image
            pill.isShareAction = true
            pill.sourceBundleId = "com.apple.sharing"
            pill.sourceAppName = "Sharing"
            pill.menuContext = "Sharing"
            pill.rankingKind = "sharingAction"
            pill.trackingIdentifier = "sharing-action:\(normalizedTitle)"
            pill.searchTerms = [title, service.menuItemTitle, "share", "send", "sharing"]
            pill.rankingScore = 1_100
            return pill
        }
        .prefix(12)
        .map { $0 }
    }

    func buildShortcutsActionSourcePills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        let context = effectiveShareAXContext()
        let fileURLs = context.selectedFilePaths.map(URL.init(fileURLWithPath:))
        let selectedText = context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentURL = context.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileURLs.isEmpty || selectedText?.isEmpty == false || currentURL?.isEmpty == false
        else { return [] }

        ShortcutsCatalog.shared.loadIfNeeded()
        let normalizedQuery = normalizedDockPillText(query)
        guard !normalizedQuery.isEmpty else { return [] }

        return ShortcutsCatalog.shared.shortcuts.compactMap { shortcut -> DockPill? in
            let normalizedTitle = normalizedDockPillText(shortcut.name)
            guard !excludingTitles.contains(normalizedTitle) else { return nil }
            guard macOSExtensionActionMatches(
                query: normalizedQuery,
                terms: [shortcut.name, "shortcut", "shortcuts", "automation"]
            ) else { return nil }

            var pill = DockPill(
                id: "shortcut-action-\(normalizedTitle)",
                name: shortcut.name,
                icon: shortcut.iconName,
                accentColorName: shortcut.accentColor,
                badge: "Shortcut",
                execute: {
                    Task {
                        do {
                            let input: ShortcutRunner.DirectInput
                            if !fileURLs.isEmpty {
                                input = .files(fileURLs)
                            } else if let selectedText, !selectedText.isEmpty {
                                input = .text(selectedText)
                            } else {
                                input = .url(currentURL ?? "")
                            }
                            _ = try await ShortcutRunner.shared.runDirectly(shortcut.name, with: input)
                            await MainActor.run {
                                AppToast.show(
                                    "Ran \(shortcut.name)",
                                    icon: shortcut.iconName,
                                    tint: .purple
                                )
                            }
                        } catch {
                            await MainActor.run {
                                AppToast.show(
                                    error.localizedDescription,
                                    icon: "exclamationmark.triangle",
                                    tint: .orange
                                )
                            }
                        }
                    }
                }
            )
            pill.menuItemImage = ShortcutsCatalog.appIcon
            pill.sourceBundleId = "com.apple.shortcuts"
            pill.sourceAppName = "Shortcuts"
            pill.menuContext = "Shortcuts"
            pill.rankingKind = "shortcutsAction"
            pill.trackingIdentifier = "shortcut-action:\(normalizedTitle)"
            pill.searchTerms = [shortcut.name, "shortcut", "shortcuts", "automation"]
            pill.rankingScore = 900
            return pill
        }
        .prefix(8)
        .map { $0 }
    }

    func buildAppIntentsActionSourcePills(
        query: String,
        excludingTitles: Set<String>
    ) -> [DockPill] {
        // Keep this source explicit but quiet until an app exposes a concrete executable adapter.
        // The macOS extension list is not a command list, so generic App Intents are not surfaced here.
        []
    }

    /// User-imported Selection Scope extensions (Create Extension → Selection Scope).
    /// Stored in LayeredExtensionManager as l2 + category "shortcutSheet"; nothing else
    /// renders them, so surface them here as runnable pills. Runs the script against the
    /// FROZEN selection (effectiveShareAXContext) — live AX is the launcher by now — and
    /// shows the script's output as a toast.
    func buildCustomSelectionExtensionPills(
        query: String,
        excludingTitles: Set<String> = []
    ) -> [DockPill] {
        let selectionContext = effectiveShareAXContext()
        let selectedPaths = effectiveSelectedFileURLsForConversation().map(\.path)
        let exts = LayeredExtensionManager.shared.allExtensions.filter {
            SelectionScopeExtensionPolicy.isEligible(
                $0, context: selectionContext, filePaths: selectedPaths)
        }
        guard !exts.isEmpty else { return [] }
        let normalizedQuery = normalizedDockPillText(query)

        return exts.compactMap { ext -> DockPill? in
            let normalizedTitle = normalizedDockPillText(ext.name)
            guard !excludingTitles.contains(normalizedTitle) else { return nil }
            guard macOSExtensionActionMatches(
                query: normalizedQuery,
                terms: [ext.name, ext.description] + ext.tags.map(\.rawValue) + ["selection", "extension"]
            ) else { return nil }

            var pill = DockPill(
                id: "custom-selection-ext-\(ext.id.uuidString)",
                name: ext.name,
                icon: ext.icon,
                accentColorName: "indigo",
                badge: "Extension",
                execute: { self.runCustomSelectionExtension(ext) }
            )
            pill.rankingKind = "customSelectionExtension"
            pill.rankingScore = 92_000
            pill.trackingIdentifier = "custom-selection-ext:\(normalizedTitle)"
            pill.searchTerms = [ext.name, ext.description, "selection", "extension", "action"]
            return pill
        }
    }

    /// Run an imported selection extension against the frozen selection and toast its output.
    private func runCustomSelectionExtension(_ ext: ILExtension) {
        guard let rawScript = ext.scriptContent, !rawScript.isEmpty else { return }
        if SelectionScopeExtensionPolicy.needsApproval(ext), !confirmSelectionExtensionRun(ext) {
            AppToast.show("Cancelled \(ext.name)", icon: "xmark.circle", tint: .secondary)
            return
        }
        // Same expansion the proposal "Run Once" path uses: extensions are written against the
        // documented {file}/{selectedText}/{url} placeholders, so they must be substituted here
        // or the script runs with the literal braces and silently does nothing.
        let script = expandSelectionPlaceholders(in: rawScript)
        let ctx = effectiveShareAXContext()
        let frozenFilePaths = effectiveSelectedFileURLsForConversation().map(\.path)
        let filePaths = SelectionScopeExtensionPolicy.resolvedFilePaths(
            context: ctx, frozenFilePaths: frozenFilePaths)
        var env: [String: String] = [
            "CD_TEXT":      ctx.selectedText ?? "",
            "CD_URL":       ctx.currentURL ?? "",
            "CD_FILE":      filePaths.first ?? "",
            "CD_FILES":     filePaths.joined(separator: "\n"),
            "CD_APP":       ctx.appName,
            "CD_BUNDLE":    ctx.bundleId,
        ]
        // Clipboard is not part of selection context. Only expose it when the extension
        // explicitly asks for it instead of leaking it to every imported script.
        if rawScript.contains("{clipboard}") || rawScript.contains("CD_CLIPBOARD") {
            env["CD_CLIPBOARD"] = NSPasteboard.general.string(forType: .string) ?? ""
        }
        let interpreter: (url: String, args: [String]) = {
            switch ext.scriptType {
            case .bash:        return ("/bin/zsh", ["-lc", script])
            case .python:      return ("/usr/bin/env", ["python3", "-c", script])
            case .applescript: return ("/usr/bin/osascript", ["-e", script])
            case .javascript:  return ("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
            case .swift:       return ("/usr/bin/env", ["swift", "-"])
            }
        }()
        let extName = ext.name
        setScriptRunStatus("Running \(extName)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: interpreter.url)
            process.arguments = interpreter.args + filePaths
            var processEnv = ProcessInfo.processInfo.environment
            for (k, v) in env { processEnv[k] = v }
            process.environment = processEnv
            let pipe = Pipe()
            // One pipe means a noisy stderr cannot deadlock behind an unread stdout pipe.
            process.standardOutput = pipe
            process.standardError = pipe
            let inputPipe = Pipe()
            if ext.scriptType == .swift {
                process.standardInput = inputPipe
            }
            let runState = SelectionExtensionRunState()
            let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timeout.schedule(deadline: .now() + 60)
            timeout.setEventHandler {
                guard process.isRunning else { return }
                runState.markTimedOut()
                process.terminate()
            }
            timeout.resume()
            do {
                try process.run()
                if ext.scriptType == .swift {
                    inputPipe.fileHandleForWriting.write(script.data(using: .utf8) ?? Data())
                    inputPipe.fileHandleForWriting.closeFile()
                }
            } catch {
                timeout.cancel()
                DispatchQueue.main.async {
                    self.setScriptRunStatus(nil)
                    AppToast.show("Failed: \(extName)", icon: "exclamationmark.triangle", tint: .orange)
                }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let exitCode = process.terminationStatus
            _ = env  // keep env alive for the closure
            DispatchQueue.main.async {
                guard exitCode == 0 else {
                    let detail = runState.didTimeOut
                        ? "Timed out after 60 seconds.\n\(output)"
                        : output
                    AppToast.show(
                        "\(extName) failed", icon: "exclamationmark.triangle", tint: .orange)
                    self.reportExtensionRun(
                        name: extName, succeeded: false, detail: detail, exitCode: exitCode)
                    return
                }
                if output.isEmpty {
                    AppToast.show("Ran \(extName)", icon: "checkmark.circle", tint: .blue)
                } else {
                    let shown = output.count > 120 ? String(output.prefix(120)) + "…" : output
                    AppToast.show(shown, icon: "text.viewfinder", tint: .indigo)
                }
                self.reportExtensionRun(
                    name: extName, succeeded: true, detail: output, exitCode: 0)
            }
        }
    }

    /// Imported scripts are code, not ordinary menu items.  A provider route therefore cannot
    /// execute a script that writes, sends, automates, or accesses the network without a clear
    /// person-in-the-loop decision.
    @MainActor
    private func confirmSelectionExtensionRun(_ ext: ILExtension) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Run \(ext.name)?"
        alert.informativeText = "This Selection Scope extension may \(SelectionScopeExtensionPolicy.approvalSummary(ext)). It receives only the frozen selection captured when this sheet opened."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func macOSExtensionActionMatches(query: String, terms: [String]) -> Bool {
        guard !query.isEmpty else { return true }
        let normalizedTerms = terms.map(normalizedDockPillText).filter { !$0.isEmpty }
        return normalizedTerms.contains { term in
            term == query
                || term.hasPrefix(query)
                || term.contains(query)
                || query.contains(term)
                || dockPillTokens(query).contains { queryToken in
                    dockPillTokens(term).contains { termToken in
                        termToken == queryToken || termToken.hasPrefix(queryToken)
                    }
                }
        }
    }
}
