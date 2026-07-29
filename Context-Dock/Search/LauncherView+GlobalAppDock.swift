import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class GlobalApplicationMetadataCache: @unchecked Sendable {
    static let shared = GlobalApplicationMetadataCache()

    private let lock = NSLock()
    private var bundleIdentifiersByPath: [String: String?] = [:]
    private var applicationURLsByBundleIdentifier: [String: URL?] = [:]

    func bundleIdentifier(forPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        lock.lock()
        if let cached = bundleIdentifiersByPath[standardizedPath] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = Bundle(path: standardizedPath)?.bundleIdentifier
        lock.lock()
        bundleIdentifiersByPath[standardizedPath] = resolved
        lock.unlock()
        return resolved
    }

    func applicationURL(bundleIdentifier: String) -> URL? {
        guard !bundleIdentifier.isEmpty else { return nil }
        lock.lock()
        if let cached = applicationURLsByBundleIdentifier[bundleIdentifier] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        lock.lock()
        applicationURLsByBundleIdentifier[bundleIdentifier] = resolved
        lock.unlock()
        return resolved
    }
}

extension LauncherView {
    func bundleIdentifierForApplicationPath(_ path: String?) -> String? {
        GlobalApplicationMetadataCache.shared.bundleIdentifier(forPath: path)
    }

    func applicationURLForBundleIdentifier(_ bundleIdentifier: String) -> URL? {
        GlobalApplicationMetadataCache.shared.applicationURL(bundleIdentifier: bundleIdentifier)
    }

    func currentRegularRunningApps() -> [NSRunningApplication] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                app.bundleIdentifier != Bundle.main.bundleIdentifier,
                !app.isTerminated
            else { return false }

            let key =
                app.bundleIdentifier
                ?? app.bundleURL?.standardizedFileURL.path
                ?? (app.localizedName ?? "").lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }

    func runningApplicationLookup() -> (
        byBundleIdentifier: [String: NSRunningApplication],
        byPath: [String: NSRunningApplication],
        byName: [String: NSRunningApplication]
    ) {
        let source = runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps
        var byBundleIdentifier: [String: NSRunningApplication] = [:]
        var byPath: [String: NSRunningApplication] = [:]
        var byName: [String: NSRunningApplication] = [:]
        byBundleIdentifier.reserveCapacity(source.count)
        byPath.reserveCapacity(source.count)
        byName.reserveCapacity(source.count)

        for app in source {
            if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
                byBundleIdentifier[bundleIdentifier] = app
            }
            if let path = app.bundleURL?.standardizedFileURL.path, !path.isEmpty {
                byPath[path] = app
            }
            if let name = app.localizedName, !name.isEmpty {
                byName[name.lowercased()] = app
            }
        }
        return (byBundleIdentifier, byPath, byName)
    }

    func runningApplication(
        forGlobalResult result: SearchResult,
        lookup: (
            byBundleIdentifier: [String: NSRunningApplication],
            byPath: [String: NSRunningApplication],
            byName: [String: NSRunningApplication]
        )
    ) -> NSRunningApplication? {
        if let path = result.filePath {
            if let bundleId = bundleIdentifierForApplicationPath(path),
                let match = lookup.byBundleIdentifier[bundleId]
            {
                return match
            }
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            if let match = lookup.byPath[standardizedPath] { return match }
        }

        return lookup.byName[result.title.lowercased()]
    }

    struct DockPillItem: Identifiable {
        let id: String
        let index: Int
        let icon: NSImage?
        let label: String
        let subtitle: String?
        let hoverKey: String
        let previewApp: NSRunningApplication?
        let action: () -> Void
        let destructiveAction: (() -> Void)?
        let removeAction: (() -> Void)?
    }

    func buildAppCascadeItems(
        pinnedApps: [PinnedApp],
        runningApps: [NSRunningApplication],
        pinnedCount: Int
    ) -> [DockPillItem] {
        var items: [DockPillItem] = []
        for (idx, app) in pinnedApps.enumerated() {
            let c = app
            let previewApp = runningApp(for: app)
            let isRunning = previewApp != nil
            items.append(
                DockPillItem(
                    id: "pinned-\(app.id)", index: idx,
                    icon: resolvedPinnedIcon(for: app), label: app.name,
                    subtitle: isRunning ? "Running" : "Launch",
                    hoverKey: "dock-pinned-\(app.id.uuidString)",
                    previewApp: previewApp,
                    action: {
                        launchPinnedApp(c)
                        if isGlobalContextActive {
                            scheduleContextDockTransition(
                                bundleId: c.bundleIdentifier, appName: c.name)
                        }
                    },
                    destructiveAction: nil,
                    removeAction: { settings.unpinApp(c) }
                ))
        }
        for (off, app) in runningApps.enumerated() {
            let i = pinnedCount + off
            let c = app
            items.append(
                DockPillItem(
                    id: "running-\(app.processIdentifier)", index: i,
                    icon: resolvedRunningAppIcon(for: app), label: app.localizedName ?? "App",
                    subtitle: "Running",
                    hoverKey: "dock-running-\(app.processIdentifier)",
                    previewApp: app,
                    action: {
                        activateRunningAppFromDock(c)
                        if isGlobalContextActive {
                            scheduleContextDockTransition(
                                bundleId: c.bundleIdentifier, appName: c.localizedName ?? "App")
                        }
                    },
                    destructiveAction: { terminateRunningAppFromDock(c) },
                    removeAction: nil
                ))
        }
        return items
    }

    @ViewBuilder
    var pinnedAndRecentAppsRow: some View {
        let searchQuery = searchState.query.trimmingCharacters(in: .whitespaces).lowercased()

        let basePinnedApps: [PinnedApp] = []
        let visiblePinnedApps =
            searchQuery.isEmpty
            ? basePinnedApps
            : basePinnedApps.filter { $0.name.lowercased().contains(searchQuery) }

        let pinnedCount = visiblePinnedApps.count
        let focusedIdx = focusedAppPillIndex

        if let kbIdx = focusedAppPillIndex {
            // ── Keyboard nav cascade: prev compact | FOCUSED expanded fills | next compact ──
            // Mirrors context dock action-pill cascade exactly.
            let allAppItems = buildAppCascadeItems(
                pinnedApps: visiblePinnedApps,
                runningApps: [],
                pinnedCount: pinnedCount
            )
            let prevItem = allAppItems.first(where: { $0.index == kbIdx - 1 })
            let focusedItem = allAppItems.first(where: { $0.index == kbIdx })
            let nextItem = allAppItems.first(where: { $0.index == kbIdx + 1 })

            HStack(alignment: .top, spacing: 6) {
                if let p = prevItem {
                    appPillButton(
                        icon: p.icon, label: p.label, subtitle: p.subtitle, hoverKey: p.hoverKey,
                        focused: false, index: p.index, isExpanded: false,
                        destructiveAction: p.destructiveAction, removeAction: p.removeAction,
                        previewApp: p.previewApp,
                        action: p.action
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.9)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))))
                }
                if let f = focusedItem {
                    appPillButton(
                        icon: f.icon, label: f.label, subtitle: f.subtitle, hoverKey: f.hoverKey,
                        focused: true, index: f.index, isExpanded: true,
                        destructiveAction: nil, removeAction: nil, previewApp: f.previewApp, action: f.action
                    )
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                }
                if let n = nextItem {
                    appPillButton(
                        icon: n.icon, label: n.label, subtitle: n.subtitle, hoverKey: n.hoverKey,
                        focused: false, index: n.index, isExpanded: false,
                        destructiveAction: n.destructiveAction, removeAction: n.removeAction,
                        previewApp: n.previewApp,
                        action: n.action
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.9)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))))
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: focusedAppPillIndex)
        } else {
            // ── Normal scrollable row — all apps visible, frontmost auto-highlighted ──
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(visiblePinnedApps.enumerated()), id: \.element.id) {
                            idx, app in
                            appPillButton(
                                icon: resolvedPinnedIcon(for: app), label: app.name,
                                hoverKey: "dock-pinned-\(app.id.uuidString)",
                                focused: idx == focusedIdx, index: idx,
                                removeAction: { settings.unpinApp(app) },
                                previewApp: runningApp(for: app),
                                action: {
                                    launchPinnedApp(app)
                                    if isGlobalContextActive {
                                        scheduleContextDockTransition(
                                            bundleId: app.bundleIdentifier, appName: app.name)
                                    }
                                }
                            )
                            .id("app-pill-\(idx)")
                            .scrollTransition(.interactive, axis: .horizontal) { effect, phase in
                                effect
                                    .rotation3DEffect(
                                        .degrees(phase.value * 22), axis: (x: 0, y: 1, z: 0),
                                        perspective: 0.45
                                    )
                                    .scaleEffect(max(0.78, 1 - abs(phase.value) * 0.18))
                                    .opacity(max(0.45, 1 - abs(phase.value) * 0.38))
                            }
                            .contextMenu {
                                Button {
                                    launchPinnedApp(app)
                                } label: {
                                    Label("Open", systemImage: "arrow.up.right.square")
                                }
                                if app.type == .folder {
                                    Button {
                                        NSWorkspace.shared.selectFile(
                                            app.path, inFileViewerRootedAtPath: "")
                                    } label: {
                                        Label("Show in Finder", systemImage: "folder")
                                    }
                                }
                            }
                        }

                    }
                }
                .onChange(of: focusedAppPillIndex) { idx in
                    guard let idx else { return }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        proxy.scrollTo("app-pill-\(idx)", anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func globalAppSearchPillRow(
        query: String, matches providedMatches: [SearchResult]? = nil
    ) -> some View {
        let matches = providedMatches ?? globalApplicationMatches(for: query)

        let makeAction: (SearchResult) -> () -> Void = { result in
            {
                executeGlobalAppSearchResult(result)
            }
        }
        let makeQuitAction: (SearchResult) -> (() -> Void)? = { result in
            guard let runningApp = runningApplication(forGlobalResult: result) else { return nil }
            return { terminateRunningAppFromDock(runningApp) }
        }

        let makePinAction: (SearchResult) -> (() -> Void)? = { result in
            nil
        }

        if matches.isEmpty {
            HStack {
                Text("No apps matching \"\(query)\"")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .padding(.horizontal, 8)
            }
        } else if let focIdx = focusedAppPillIndex, focIdx < matches.count {
            // ── Keyboard nav: icon-anchor + prev(normal) + FOCUSED(expanded) + next(normal) ──
            let prev = focIdx > 0 ? matches[focIdx - 1] : nil
            let focused = matches[focIdx]
            let next = focIdx + 1 < matches.count ? matches[focIdx + 1] : nil

            HStack(alignment: .top, spacing: 6) {
                if let prev {
                    let pi = focIdx - 1
                    appPillButton(
                        icon: prev.icon, label: prev.title,
                        hoverKey: "gsearch-\(prev.title)", focused: false, index: pi,
                        isExpanded: false, destructiveAction: makeQuitAction(prev),
                        pinAction: makePinAction(prev),
                        previewApp: runningApplication(forGlobalResult: prev),
                        action: makeAction(prev)
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.9)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))))
                }

                appPillButton(
                    icon: focused.icon, label: focused.title,
                    hoverKey: "gsearch-\(focused.title)", focused: true, index: focIdx,
                    isExpanded: true, destructiveAction: makeQuitAction(focused),
                    pinAction: makePinAction(focused),
                    previewApp: runningApplication(forGlobalResult: focused),
                    action: makeAction(focused)
                )
                .frame(maxWidth: .infinity)
                .transition(.opacity)

                if let next {
                    let ni = focIdx + 1
                    appPillButton(
                        icon: next.icon, label: next.title,
                        hoverKey: "gsearch-\(next.title)", focused: false, index: ni,
                        isExpanded: false, destructiveAction: makeQuitAction(next),
                        pinAction: makePinAction(next),
                        previewApp: runningApplication(forGlobalResult: next),
                        action: makeAction(next)
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.9)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))))
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: focIdx)
        } else {
            // ── Normal scrollable row ──
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(matches.enumerated()), id: \.element.title) { idx, result in
                            appPillButton(
                                icon: result.icon,
                                label: result.title,
                                hoverKey: "global-search-\(result.title)",
                                focused: false,
                                index: idx,
                                isExpanded: false,
                                destructiveAction: makeQuitAction(result),
                                pinAction: makePinAction(result),
                                previewApp: runningApplication(forGlobalResult: result),
                                action: makeAction(result)
                            )
                            .id("gsearch-pill-\(idx)")
                            .scrollTransition(.interactive, axis: .horizontal) { effect, phase in
                                effect
                                    .rotation3DEffect(
                                        .degrees(phase.value * 22),
                                        axis: (x: 0, y: 1, z: 0),
                                        perspective: 0.45
                                    )
                                    .scaleEffect(max(0.78, 1 - abs(phase.value) * 0.18))
                                    .opacity(max(0.45, 1 - abs(phase.value) * 0.38))
                            }
                        }
                    }
                }
                .onChange(of: focusedAppPillIndex) { idx in
                    guard let idx else { return }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        proxy.scrollTo("gsearch-pill-\(idx)", anchor: .center)
                    }
                }
            }
        }
    }

    func globalAppSearchListView(
        query: String,
        matches providedMatches: [SearchResult]? = nil,
        menuPills providedMenuPills: [DockPill] = [],
        appMenuGroups providedAppMenuGroups: [AppMenuGroup] = [],
        launchHint: (bundleId: String, appName: String, appPath: String?)? = nil,
        scopedMenuAppName: String? = nil,
        scopedMenuActionQuery: String = "",
        isLoading: Bool = false,
        menuFirst: Bool = false
    ) -> some View {
        let rawMatches = Array(
            (providedMatches ?? globalApplicationMatches(for: query)).prefix(maxListViewDockPills))
        let scopedMenuAppName = scopedMenuAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isScopedMenuMode = scopedMenuAppName?.isEmpty == false
        let scopedMenuActionQuery = scopedMenuActionQuery.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let candidateMenuPills =
            providedMenuPills
            .filter { !$0.isSeparator }
            .filter { $0.rankingKind != "appLaunch" }
            .filter { !$0.name.lowercased().hasPrefix("open ") || rawMatches.isEmpty }
        // Count all menu pills (frontmost/scoped + cross-app) to match the nav state's appLimit formula.
        // When cross-app groups exist, candidateMenuPills is empty (menuGroups=[]) so without this
        // the view includes more app results than the nav state, causing index mismatches and missing highlights.
        let totalMenuPillCount =
            candidateMenuPills.count + providedAppMenuGroups.flatMap(\.pills).count
        let appLimit =
            totalMenuPillCount == 0
            ? maxListViewDockPills
            : min(rawMatches.count, max(8, maxListViewDockPills - min(totalMenuPillCount, 12)))
        let limitedMatches = Array(
            dedupeGlobalApplicationResults(rawMatches).prefix(appLimit))
        let runningLookup = runningApplicationLookup()
        // For a TYPED query, preserve score-based relevance order. Floating running apps to
        // the top desyncs the highlighted first row from the leading icon + ghost completion
        // (both use score order) — e.g. "cod" highlighted ChatGPT (running) while the icon
        // showed VS Code (exact match). Only float running-first when the query is empty (idle).
        let matches: [SearchResult] = {
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return limitedMatches
            }
            return limitedMatches.filter { runningApplication(forGlobalResult: $0, lookup: runningLookup) != nil }
                + limitedMatches.filter { runningApplication(forGlobalResult: $0, lookup: runningLookup) == nil }
        }()
        let indexedMatches = Array(matches.enumerated())
        // In global context, isEnabled reflects AX state of whatever app was frontmost at
        // snapshot time — meaningless here. Force enabled so no "Unavailable" badge shows.
        let visibleMenuPills = Array(
            candidateMenuPills.prefix(
                matches.isEmpty
                    ? maxListViewDockPills : max(0, maxListViewDockPills - matches.count))
        ).map { pill -> DockPill in
            var p = pill
            p.isEnabled = true
            return p
        }
        let menuGroups = groupMenuPillsByTitle(visibleMenuPills)
        let menuRowID: (MenuPillGroup) -> String = { group in
            group.isGrouped
                ? "global-menu-group-\(group.id)"
                : "global-menu-pill-\(group.primaryPill.id)"
        }
        let menuRowIDs: [String] = menuGroups.map(menuRowID)
        let appRowID: (SearchResult) -> String = { result in
            "global-app-\(result.trackingIdentifier)"
        }
        let appRowIDs: [String] = matches.map(appRowID)
        @ViewBuilder
        func crossAppMenuGroupsView() -> some View {
            let crossBase = matches.count + menuGroups.count
            let groupStartIndices: [String: Int] = {
                var d: [String: Int] = [:]
                var offset = 0
                for g in providedAppMenuGroups {
                    d[g.id] = crossBase + offset
                    offset += g.pills.count
                }
                return d
            }()
            ForEach(providedAppMenuGroups) { group in
                let groupBase = groupStartIndices[group.id] ?? crossBase
                resultGroupHeader(group.appName, icon: group.icon)
                    .transition(.opacity)
                    .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                ForEach(Array(group.pills.enumerated()), id: \.element.id) {
                    pillIdx, pill in
                    pillListRow(pill: pill, index: groupBase + pillIdx)
                        .id("xapp-pill-\(group.id)-\(pill.id)")
                        .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                }
            }
        }
        let showLaunchHint = launchHint != nil
            && visibleMenuPills.isEmpty
            && !(launchHint?.bundleId.hasPrefix("syscmd://") ?? false)
            && !(launchHint?.bundleId.hasPrefix("cli://") ?? false)
        let hasRenderableRows =
            !matches.isEmpty || !visibleMenuPills.isEmpty || !providedAppMenuGroups.isEmpty
            || showLaunchHint
        let isEmpty = !isLoading && !hasRenderableRows
        let makeAction: (SearchResult) -> () -> Void = { result in
            {
                let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                executeGlobalAppSearchResult(result)
                // Teach intent: user picked an app for this query
                if !q.isEmpty { AppUsageLearner.shared.recordQueryIntent(query: q, wasMenu: false) }
            }
        }
        let makeQuitAction: (SearchResult) -> (() -> Void)? = { result in
            guard let runningApp = runningApplication(forGlobalResult: result, lookup: runningLookup) else { return nil }
            return { terminateRunningAppFromDock(runningApp) }
        }
        let makePinAction: (SearchResult) -> (() -> Void)? = { result in
            nil
        }

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    if isEmpty {
                        HStack {
                            Text(
                                isScopedMenuMode
                                    ? (scopedMenuActionQuery.isEmpty
                                        ? "No cached menus for \(scopedMenuAppName ?? "this app")"
                                        : "No \(scopedMenuAppName ?? "app") menus matching \"\(scopedMenuActionQuery)\"")
                                    : "No apps matching \"\(query)\""
                            )
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.65))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                    }

                    // When intent favours a menu action, surface menus above app results.
                    if menuFirst {
                        if !menuGroups.isEmpty {
                            resultGroupHeader(
                                isScopedMenuMode ? "\(scopedMenuAppName ?? "App") Menus" : "Menus")
                                .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                        }
                        ForEach(Array(menuGroups.enumerated()), id: \.element.id) { idx, group in
                            if group.isGrouped {
                                groupedMenuPillRow(group: group, index: matches.count + idx)
                                    .id(menuRowID(group))
                                    .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                            } else {
                                pillListRow(pill: group.primaryPill, index: matches.count + idx)
                                    .id(menuRowID(group))
                                    .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                            }
                        }
                    }

                    if menuFirst {
                        crossAppMenuGroupsView()
                    }

                    if !indexedMatches.isEmpty {
                        resultGroupHeader(
                            indexedMatches.contains(where: { $0.element.type != .application })
                                ? "Results" : "Apps")
                            .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                    }
                    ForEach(indexedMatches, id: \.element.trackingIdentifier) { idx, result in
                        // Match by bundleId → path → localized name (robust for apps whose
                        // indexed bundleId differs from the live one, e.g. ChatGPT), and fall
                        // back to the live running set when runningRegularApps is empty.
                        let runningApp = runningApplication(forGlobalResult: result, lookup: runningLookup)
                        let isRunning = runningApp != nil
                        appListRow(
                            icon: result.icon,
                            name: result.title,
                            subtitle: globalListSubtitle(for: result, isRunning: isRunning),
                            index: idx,
                            isCommandIcon: globalListUsesCommandIcon(for: result),
                            defaultsToFirstSelection: true,
                            interactiveCommand: interactiveSystemCommand(forResult: result),
                            quitAction: isRunning ? makeQuitAction(result) : nil,
                            quitPhase: appQuitFeedbackPhase(bundleID: runningApp?.bundleIdentifier),
                            previewApp: runningApp,
                            action: makeAction(result)
                        )
                        .id(appRowID(result))
                        .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                        .contextMenu {
                            if let quitAction = makeQuitAction(result) {
                                Button(role: .destructive, action: quitAction) {
                                    Label("Quit \(result.title)", systemImage: "xmark.circle")
                                }
                            }
                        }
                    }

                    if !menuFirst {
                        if !menuGroups.isEmpty {
                            resultGroupHeader(
                                isScopedMenuMode ? "\(scopedMenuAppName ?? "App") Menus" : "Menus")
                                .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                        }
                        ForEach(Array(menuGroups.enumerated()), id: \.element.id) { idx, group in
                            if group.isGrouped {
                                groupedMenuPillRow(group: group, index: matches.count + idx)
                                    .id(menuRowID(group))
                                    .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                            } else {
                                pillListRow(pill: group.primaryPill, index: matches.count + idx)
                                    .id(menuRowID(group))
                                    .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                            }
                        }
                    }

                    // Cross-app menus grouped by source app.
                    // Each group shows app icon + name header, then matching menu pills below.
                    if !menuFirst {
                        crossAppMenuGroupsView()
                    }

                    // No cached menus + app not running: invite user to open it once so menus get snapshotted.
                    if showLaunchHint, let hint = launchHint {
                        Button {
                            // Hide proactively — waiting for the launched app to
                            // steal focus leaves the dock lingering for seconds.
                            hideLauncherAfterResultExecution()
                            if let path = hint.appPath {
                                NSWorkspace.shared.openApplication(
                                    at: URL(fileURLWithPath: path),
                                    configuration: .init()
                                )
                            } else {
                                NSWorkspace.shared.launchApplication(
                                    withBundleIdentifier: hint.bundleId,
                                    options: [], additionalEventParamDescriptor: nil,
                                    launchIdentifier: nil)
                            }
                            searchState.query = ""
                        } label: {
                            HStack(spacing: 12) {
                                if let path = hint.appPath {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                        .resizable().aspectRatio(contentMode: .fit)
                                        .frame(width: 32, height: 32)
                                } else {
                                    Image(systemName: "app.badge.checkmark")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32, height: 32)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open \(hint.appName) to enable menu search")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text("Menus are cached after first launch")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                        .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // Measure the real rendered content height so the sheet hugs the rows
                // exactly (no half-empty box / count mismatch). LazyVStack reports its
                // full intrinsic height even with lazy row rendering.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    updateMeasuredGlobalListHeight(height)
                }
            }
            .contextDockBottomListFlip(settings.effectiveDockAtBottom)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(minHeight: isEmpty ? 86 : 0, maxHeight: listViewVisibleHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(nil, value: hasRenderableRows)
            .onChange(of: focusedAppPillIndex) { idx in
                guard let idx, idx < appRowIDs.count else { return }
                proxy.scrollTo(appRowIDs[idx], anchor: .center)
            }
            .onChange(of: l2.focusedPillIndex) { idx in
                guard let idx, idx >= matches.count else { return }
                let menuIdx = idx - matches.count
                DispatchQueue.main.async { refreshQuickLookPreviewForCurrentFocusIfVisible() }
                if menuIdx >= 0, menuIdx < menuRowIDs.count {
                    proxy.scrollTo(menuRowIDs[menuIdx], anchor: .center)
                } else if menuIdx >= menuGroups.count {
                    // Cross-app group pill — find which group and local index
                    let crossIdx = menuIdx - menuGroups.count
                    var offset = 0
                    for group in providedAppMenuGroups {
                        let localIdx = crossIdx - offset
                        if localIdx < group.pills.count {
                            proxy.scrollTo(
                                "xapp-pill-\(group.id)-\(group.pills[localIdx].id)",
                                anchor: .center)
                            break
                        }
                        offset += group.pills.count
                    }
                }
            }
            .onChange(of: matches.count) { count in
                guard let idx = focusedAppPillIndex else { return }
                let crossAppMenuCount = providedAppMenuGroups.reduce(0) { $0 + $1.pills.count }
                let totalCount = count + visibleMenuPills.count + crossAppMenuCount
                if totalCount <= 0 {
                    focusedAppPillIndex = nil
                    l2.focusedPillIndex = nil
                    l2.pillNavViaKeyboard = false
                } else if idx >= totalCount {
                    focusedAppPillIndex = totalCount - 1
                }
            }
        }
    }

    func resolvedPinnedIcon(for app: PinnedApp) -> NSImage? {
        if app.type == .application {
            if let bundleId = app.bundleIdentifier,
                let runningURL = runningRegularApps.first(where: {
                    $0.bundleIdentifier == bundleId
                })?.bundleURL
            {
                return preparedDockIcon(NSWorkspace.shared.icon(forFile: runningURL.path))
            }
            if let bundleId = app.bundleIdentifier,
                let appURL = applicationURLForBundleIdentifier(bundleId)
            {
                return preparedDockIcon(NSWorkspace.shared.icon(forFile: appURL.path))
            }
        }

        return preparedDockIcon(NSWorkspace.shared.icon(forFile: app.path))
    }

    func globalApplicationMatches(
        for query: String,
        limit: Int = Int.max,
        includeRecentItems: Bool = true
    ) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        if isGenericApplicationListQuery(q) {
            return groupedGlobalApplicationList(limit: limit)
        }

        // Do not wait for the asynchronous global-index refresh to recognize an
        // installed CLI. This is a bounded in-memory prefix lookup over registered
        // packages, so `brew` becomes the first result from its first keystroke and
        // can never be displaced by a same-named recent executable/document.
        let directCLIMatches = directGlobalCLIScopeMatches(for: q, limit: limit)
        if !directCLIMatches.isEmpty {
            return directCLIMatches
        }

        if GlobalSearchService.shared.documentCount > 0 {
            let snapshot = GlobalContextSearchCoordinator.shared.snapshot(
                query: q,
                limit: min(max(limit, 20), 80),
                includeCachedMenus: false,
                includeRunningCachedMenus: false
            )
            let indexedRows = searchResults(from: snapshot.appDocuments, query: q)
            if !indexedRows.isEmpty {
                return Array(indexedRows.prefix(limit))
            }
        }

        let exactSystemCommandRows = globalSystemCommandPresetRows(
            for: normalizedDockPillText(q),
            limit: max(limit, 12)
        )

        var candidates: [(result: SearchResult, score: Double, order: Int)] = []
        var seen = Set<String>()
        var order = 0

        func add(_ result: SearchResult, bundleIdentifier explicitBundleId: String? = nil) {
            let bundleId = explicitBundleId ?? bundleIdentifier(forApplicationResult: result)
            guard
                let score = appSearchMatchScore(
                    query: q,
                    appName: result.title,
                    bundleIdentifier: bundleId
                )
            else { return }

            let key = bundleId ?? result.filePath ?? result.title.lowercased()
            guard seen.insert(key).inserted else { return }
            // Cross-register the file path so a later path-keyed entry for the same app is blocked.
            if let bid = bundleId, !bid.isEmpty, let path = result.filePath, !path.isEmpty,
                path != bid
            {
                seen.insert(path)
            }
            var enriched = result
            enriched.score = score
            candidates.append((enriched, score, order))
            order += 1
        }

        for app in settings.pinnedApps where app.type == .application {
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    path: app.path
                )
            else { continue }
            let path = app.path
            let title = app.name
            add(
                SearchResult(
                    title: title,
                    subtitle: path,
                    icon: resolvedPinnedIcon(for: app),
                    action: { launchPinnedApp(app) },
                    type: .application,
                    filePath: path,
                    contactData: nil
                ), bundleIdentifier: app.bundleIdentifier)
        }

        // Recent apps from macOS Recent Items — higher signal than full installed list.
        // Deduped by seen set; running/pinned apps already inserted win on action (activate vs open).
        if isGlobalContextActive && includeRecentItems {
            for recent in RecentItemsService.shared.recentApplications() {
                guard
                    !shouldIgnoreApplicationFromAppSearch(
                        appName: recent.name,
                        bundleIdentifier: recent.bundleId,
                        path: recent.url.path
                    )
                else { continue }
                let capturedURL = recent.url
                add(
                    SearchResult(
                        title: recent.name,
                        subtitle: recent.url.path,
                        icon: recent.icon,
                        action: {
                            NSWorkspace.shared.openApplication(
                                at: capturedURL, configuration: .init())
                        },
                        type: .application,
                        filePath: recent.url.path,
                        contactData: nil
                    ), bundleIdentifier: recent.bundleId)
            }
        }

        let runningSource =
            runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps
        for app in runningSource where app.bundleIdentifier != "com.apple.finder" {
            guard let name = app.localizedName else { continue }
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: name,
                    bundleIdentifier: app.bundleIdentifier,
                    path: app.bundleURL?.path
                )
            else { continue }
            let path = app.bundleURL?.path
            add(
                SearchResult(
                    title: name,
                    subtitle: path ?? "Running",
                    icon: resolvedRunningAppIcon(for: app),
                    action: { activateRunningAppFromGlobalContext(app) },
                    type: .application,
                    filePath: path,
                    contactData: nil
                ), bundleIdentifier: app.bundleIdentifier)
        }

        let installedMatches =
            allApplications
            .filter {
                $0.type == .application
                    && !shouldIgnoreApplicationFromAppSearch(
                        appName: $0.title,
                        bundleIdentifier: bundleIdentifierForApplicationPath($0.subtitle),
                        path: $0.subtitle
                    )
            }

        for app in installedMatches {
            add(app)
        }

        let builtInAppTargets: [(name: String, bundleId: String, path: String)] = [
            ("Safari", "com.apple.Safari", "/Applications/Safari.app"),
            ("Notes", "com.apple.Notes", "/System/Applications/Notes.app"),
            ("Messages", "com.apple.MobileSMS", "/System/Applications/Messages.app"),
            ("Mail", "com.apple.mail", "/System/Applications/Mail.app"),
            ("Calendar", "com.apple.iCal", "/System/Applications/Calendar.app"),
            ("Reminders", "com.apple.reminders", "/System/Applications/Reminders.app"),
            ("Photos", "com.apple.Photos", "/System/Applications/Photos.app"),
            ("Contacts", "com.apple.AddressBook", "/System/Applications/Contacts.app"),
            (
                "System Settings", "com.apple.systempreferences",
                "/System/Applications/System Settings.app"
            ),
            ("FaceTime", "com.apple.FaceTime", "/System/Applications/FaceTime.app"),
            ("Freeform", "com.apple.freeform", "/System/Applications/Freeform.app"),
            ("Maps", "com.apple.Maps", "/System/Applications/Maps.app"),
            ("Music", "com.apple.Music", "/System/Applications/Music.app"),
            (
                "QuickTime Player", "com.apple.QuickTimePlayerX",
                "/System/Applications/QuickTime Player.app"
            ),
        ]
        for target in builtInAppTargets {
            let path =
                applicationURLForBundleIdentifier(target.bundleId)?.path
                ?? target.path
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: target.name,
                    bundleIdentifier: target.bundleId,
                    path: path
                )
            else { continue }
            add(
                SearchResult(
                    title: target.name,
                    subtitle: path,
                    icon: resolvedApplicationIcon(
                        bundleIdentifier: target.bundleId, appName: target.name)
                        ?? preparedDockIcon(NSWorkspace.shared.icon(forFile: path)),
                    action: {
                        if let url = applicationURLForBundleIdentifier(target.bundleId)
                        {
                            NSWorkspace.shared.openApplication(
                                at: url, configuration: NSWorkspace.OpenConfiguration())
                        } else {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    },
                    type: .application,
                    filePath: path,
                    contactData: nil
                ), bundleIdentifier: target.bundleId)
        }

        // Recent documents are durable cross-app file results. They are backed by both
        // macOS Recent Items and resolved cached menu records.
        if isGlobalContextActive, includeRecentItems, q.count >= 3 {
            for result in recentDocumentGlobalMatches(for: q, limit: limit) {
                let key = result.filePath ?? result.title
                guard seen.insert(key).inserted else { continue }
                candidates.append((result, result.score, order))
                order += 1
            }
        }

        for result in exactSystemCommandRows + globalSystemCommandScopeMatches(for: q, limit: limit)
        {
            let key = globalApplicationIdentityKey(
                for: result,
                explicitBundleIdentifier: result.subtitle
            )
            guard seen.insert(key).inserted else { continue }
            candidates.append((result, result.score, order))
            order += 1
        }

        return Array(
            candidates
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    if $0.result.title.count != $1.result.title.count {
                        return $0.result.title.count < $1.result.title.count
                    }
                    return $0.order < $1.order
                }
                .map(\.result)
                .prefix(limit)
        )
    }

    /// Immediate command-name matching for Global Context. Natural-language aliases
    /// continue through `GlobalSearchService`; this hot path intentionally remains
    /// prefix-only so it is predictable and effectively free while typing.
    func directGlobalCLIScopeMatches(for query: String, limit: Int) -> [SearchResult] {
        let q = normalizedDockPillText(query)
        guard !q.isEmpty, limit > 0 else { return [] }

        let matches: [(package: TerminalPackage, score: Double)] =
            TerminalPackageManager.shared.packages.lazy
            .filter(\.isEnabled)
            .compactMap { package in
                let command = normalizedDockPillText(package.command)
                let name = normalizedDockPillText(package.name)
                if command == q { return (package, 20_000) }
                if command.hasPrefix(q) { return (package, 19_500 - Double(command.count)) }
                if !name.isEmpty && name.hasPrefix(q) {
                    return (package, 19_000 - Double(name.count))
                }
                return nil
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.package.command.localizedCaseInsensitiveCompare($1.package.command)
                    == .orderedAscending
            }

        return matches.prefix(limit).map { match in
            let command = match.package.command
            let displayName = match.package.name.isEmpty ? command : match.package.name
            let scopedResult = SearchResult(
                title: command,
                subtitle: "cli://\(command)",
                icon: nil,
                action: {},
                type: .cliTool,
                filePath: nil,
                contactData: nil
            )
            var result = SearchResult(
                title: command,
                subtitle: "cli://\(command)",
                icon: NSWorkspace.shared.icon(forFileType: "public.unix-executable"),
                action: {
                    _ = activateGlobalInlineScope(
                        result: scopedResult,
                        bundleID: "cli://\(command)"
                    )
                },
                type: .cliTool,
                filePath: nil,
                contactData: nil,
                stableID: "cli://\(command)"
            )
            result.score = match.score
            result.displayBadges = [displayName == command ? "CLI Tool" : displayName]
            return result
        }
    }

    func globalListSubtitle(for result: SearchResult, isRunning: Bool) -> String {
        if result.type == .extensionCommand {
            if result.subtitle.hasPrefix("syscmd://") { return "System Command" }
            if result.subtitle.hasPrefix("cli://") { return "CLI Tool" }
            return result.subtitle.isEmpty ? "System" : result.subtitle
        }
        guard result.type == .application else { return "Recent Document" }
        if isRunning { return "Running" }
        return settings.isPinned(path: result.filePath ?? result.subtitle) ? "Pinned" : "Open"
    }

    func globalListUsesCommandIcon(for result: SearchResult) -> Bool {
        if result.type == .cliTool { return true }
        guard result.type == .extensionCommand else { return false }
        if result.titleLower.hasPrefix("quit "), result.filePath != nil { return false }
        return true
    }

    func groupedGlobalApplicationList(limit: Int) -> [SearchResult] {
        var results: [SearchResult] = []
        var seen = Set<String>()

        func bundleIdentifier(for path: String?) -> String? {
            bundleIdentifierForApplicationPath(path)
        }

        func add(_ result: SearchResult) {
            guard results.count < limit else { return }
            let bundleId = bundleIdentifier(for: result.filePath ?? result.subtitle)
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: result.title,
                    bundleIdentifier: bundleId,
                    path: result.filePath ?? result.subtitle
                )
            else { return }

            let key = bundleId ?? result.filePath ?? result.subtitle.lowercased()
            guard seen.insert(key).inserted else { return }
            results.append(result)
        }

        let runningSource =
            runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps
        for app in runningSource
        where results.count < limit && app.bundleIdentifier != "com.apple.finder" {
            guard let name = app.localizedName else { continue }
            let path = app.bundleURL?.path
            let bundleId = app.bundleIdentifier
            guard
                !shouldIgnoreApplicationFromAppSearch(
                    appName: name,
                    bundleIdentifier: bundleId,
                    path: path
                )
            else { continue }

            let key = bundleId ?? path ?? name.lowercased()
            guard seen.insert(key).inserted else { continue }
            results.append(
                SearchResult(
                    title: name,
                    subtitle: path ?? "Running",
                    icon: resolvedRunningAppIcon(for: app),
                    action: { activateRunningAppFromGlobalContext(app) },
                    type: .application,
                    filePath: path,
                    contactData: nil
                ))
        }

        for app in settings.pinnedApps where app.type == .application {
            add(
                SearchResult(
                    title: app.name,
                    subtitle: app.path,
                    icon: resolvedPinnedIcon(for: app),
                    action: { launchPinnedApp(app) },
                    type: .application,
                    filePath: app.path,
                    contactData: nil
                ))
        }

        for app in allApplications where app.type == .application {
            add(app)
        }

        return results
    }

    func runningApplication(forGlobalResult result: SearchResult) -> NSRunningApplication? {
        runningApplication(forGlobalResult: result, lookup: runningApplicationLookup())
    }

    func resolvedApplicationIcon(bundleIdentifier: String?, appName: String? = nil)
        -> NSImage?
    {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            if let runningURL = runningRegularApps.first(where: {
                $0.bundleIdentifier == bundleIdentifier
            })?.bundleURL {
                return preparedDockIcon(NSWorkspace.shared.icon(forFile: runningURL.path))
            }
            if let appURL = applicationURLForBundleIdentifier(bundleIdentifier)
            {
                return preparedDockIcon(NSWorkspace.shared.icon(forFile: appURL.path))
            }
        }

        guard let appName, !appName.isEmpty else { return nil }
        if let result = allApplications.first(where: {
            $0.title.compare(appName, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }) {
            return preparedDockIcon(result.icon)
        }

        let appDirectories = [
            "/Applications",
            "/System/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "\(NSHomeDirectory())/Applications",
        ]
        let fileManager = FileManager.default
        for directory in appDirectories {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent(appName)
                .appendingPathExtension("app")
            if fileManager.fileExists(atPath: url.path) {
                return preparedDockIcon(NSWorkspace.shared.icon(forFile: url.path))
            }
        }

        return nil
    }

    func typedL2AppIcon(for query: String) -> (icon: NSImage, bundleId: String)? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isL2ContextActive, isGlobalContextActive, !trimmed.isEmpty else { return nil }

        let normalized = trimmed.lowercased()
        let installedScopeMode = contextDockInstalledAppScopeMatching
        let dockOnlyMode = contextDockRunningOnlyAppMatching && !installedScopeMode
        let runningBundleIds = runningBundleIdsForContextDock()
        if let target = L2AppActionRouter.shared.appScopeTarget(for: normalized),
            !dockOnlyMode || runningBundleIds.contains(target.bundleId),
            let icon = resolvedApplicationIcon(
                bundleIdentifier: target.bundleId, appName: target.appName)
        {
            return (icon, target.bundleId)
        }

        if let target = installedAppMenuTarget(
            for: normalized,
            runningOnly: dockOnlyMode,
            includeAppsWithoutMenuSnapshot: installedScopeMode,
            allowPrefixAlias: installedScopeMode
        ),
            let icon = resolvedApplicationIcon(
                bundleIdentifier: target.bundleId,
                appName: target.appName
            ) ?? preparedDockIcon(NSWorkspace.shared.icon(forFile: target.appPath))
        {
            return (icon, target.bundleId)
        }

        if let completion = l2.appCompletion,
            let icon = resolvedApplicationIcon(
                bundleIdentifier: completion.bundleId, appName: completion.appName)
        {
            return (icon, completion.bundleId)
        }

        if let completion = bestL2PartialAppCompletion(for: normalized, runningOnly: dockOnlyMode),
            let icon = resolvedApplicationIcon(
                bundleIdentifier: completion.bundleId,
                appName: completion.appName
            )
                ?? installedApplicationResult(bundleIdentifier: completion.bundleId)?.icon
                .flatMap(preparedDockIcon)
        {
            return (icon, completion.bundleId)
        }

        guard let firstToken = normalized.split(separator: " ").first,
            firstToken.count >= (dockOnlyMode ? 3 : 2)
        else { return nil }
        let first = String(firstToken)
        if dockOnlyMode {
            let runningSource =
                runningRegularApps.isEmpty ? currentRegularRunningApps() : runningRegularApps
            if let app = runningSource.first(where: { app in
                guard let name = app.localizedName?.lowercased() else { return false }
                return name == first || name.hasPrefix(first)
            }), let bundleId = app.bundleIdentifier,
                let icon = resolvedRunningAppIcon(for: app)
            {
                return (icon, bundleId)
            }
            return nil
        }
        let appMatch = allApplications.first { result in
            let title = result.title.lowercased()
            let bundleId = bundleIdentifierForApplicationPath(result.subtitle)
            return title == first
                || (title.hasPrefix(first)
                    && shouldAllowShortAppPrefixMatch(
                        prefix: first,
                        appName: result.title,
                        bundleIdentifier: bundleId
                    ))
        }
        guard let appMatch else { return nil }

        let bundleId =
            bundleIdentifierForApplicationPath(appMatch.subtitle)
            ?? appMatch.subtitle
        if let icon = resolvedApplicationIcon(bundleIdentifier: bundleId, appName: appMatch.title)
            ?? preparedDockIcon(appMatch.icon)
        {
            return (icon, bundleId)
        }
        return nil
    }

    func globalScopedAppIcon(for query: String) -> (icon: NSImage, bundleId: String)? {
        guard isL2ContextActive, isGlobalContextActive, !hasSelectionScopeSurface else {
            return nil
        }
        let scope = resolveDockScope(for: query)
        guard scope.isExplicitAppScope, !scope.scopedBundleId.isEmpty else { return nil }
        if scope.scopedBundleId.hasPrefix("syscmd://") {
            let id = String(scope.scopedBundleId.dropFirst("syscmd://".count))
            if let uuid = UUID(uuidString: id),
                let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == uuid }),
                let icon = NSImage(systemSymbolName: command.icon, accessibilityDescription: command.name)
            {
                return (icon, scope.scopedBundleId)
            }
        }
        let scopedAppPath =
            allApplications.first { result in
                bundleIdentifierForApplicationPath(result.subtitle)
                    == scope.scopedBundleId
            }?.subtitle
            ?? applicationURLForBundleIdentifier(scope.scopedBundleId)?.path
        if isCLIToolScopeChip(
            bundleId: scope.scopedBundleId, appName: scope.scopedAppName,
            appPath: scopedAppPath ?? ""),
            let icon = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: scope.scopedAppName)
        {
            return (icon, scope.scopedBundleId)
        }
        let appPath = scopedAppPath
        let icon =
            resolvedApplicationIcon(
                bundleIdentifier: scope.scopedBundleId, appName: scope.scopedAppName)
            ?? appPath.map { preparedDockIcon(NSWorkspace.shared.icon(forFile: $0)) } ?? nil
        guard let icon else { return nil }
        return (icon, scope.scopedBundleId)
    }

    func bestL2PartialAppCompletion(
        for query: String, runningOnly: Bool = false
    ) -> AppCompletion? {
        let rawTrimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip .app suffix so "Clock.app" completes the same as "Clock"
        let trimmed =
            rawTrimmed.hasSuffix(".app")
            ? String(rawTrimmed.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            : rawTrimmed
        guard trimmed.count >= (runningOnly ? 3 : 2) else { return nil }
        let runningBundleIds: Set<String>? =
            runningOnly
            ? Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
            : nil

        if !runningOnly, "clipboard".hasPrefix(trimmed) && trimmed != "clipboard" {
            return AppCompletion(
                appName: "Clipboard",
                bundleId: "scope://clipboard",
                ghost: String("clipboard".dropFirst(trimmed.count)),
                actionQuery: ""
            )
        }

        if let routerCompletion = L2AppActionRouter.shared.partialAppCompletion(for: trimmed),
            runningBundleIds == nil || runningBundleIds?.contains(routerCompletion.bundleId) == true
        {
            return routerCompletion
        }

        let tokens = trimmed.split(separator: " ").map(String.init)
        guard let firstToken = tokens.first, firstToken.count >= (runningOnly ? 3 : 2) else {
            return nil
        }
        let actionQuery = tokens.dropFirst().joined(separator: " ")
        guard
            shouldAllowLocalAppPartialCompletion(
                fullQuery: trimmed,
                firstToken: firstToken,
                actionQuery: actionQuery
            )
        else { return nil }

        func normalizeAppAlias(_ text: String) -> String {
            text.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var best:
            (appName: String, bundleId: String, ghost: String, actionQuery: String, score: Double)?

        for result in allApplications where result.type == .application {
            let appName = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let appPath = result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appName.isEmpty, !appPath.isEmpty else { continue }

            let bundleId = bundleIdentifierForApplicationPath(appPath) ?? appPath
            // In context dock mode: skip apps that aren't currently running
            if let runningBundleIds, !runningBundleIds.contains(bundleId) { continue }
            let normalizedName = normalizeAppAlias(appName)
            guard !normalizedName.isEmpty else { continue }

            var aliases = Set<String>()
            aliases.insert(normalizedName)
            if let first = normalizedName.split(separator: " ").first {
                aliases.insert(String(first))
            }
            if normalizedName.hasSuffix("s"), normalizedName.count > 3 {
                aliases.insert(String(normalizedName.dropLast()))
            }

            for alias in aliases {
                let aliasTokens = alias.split(separator: " ").map(String.init)
                guard let firstAliasToken = aliasTokens.first else { continue }
                guard firstAliasToken.hasPrefix(firstToken), firstAliasToken != firstToken else {
                    continue
                }
                guard
                    shouldAllowShortAppPrefixMatch(
                        prefix: firstToken,
                        appName: appName,
                        bundleIdentifier: bundleId
                    )
                else { continue }

                let ghost = String(alias.dropFirst(firstToken.count))
                let aliasUsage = UsageTracker.shared.getScore(for: "app:\(appPath)") / 100.0
                let exactFirstTokenBonus = firstAliasToken == normalizedName ? 0.4 : 0.0
                let score = Double(firstAliasToken.count) + aliasUsage + exactFirstTokenBonus

                if best.map({ score > $0.score }) ?? true {
                    best = (appName, bundleId, ghost, actionQuery, score)
                }
            }
        }

        guard let best else { return nil }
        return AppCompletion(
            appName: best.appName,
            bundleId: best.bundleId,
            ghost: best.ghost,
            actionQuery: best.actionQuery
        )
    }

    func installedApplicationResult(bundleIdentifier: String) -> SearchResult? {
        allApplications.first { result in
            result.type == .application
                && bundleIdentifierForApplicationPath(result.subtitle)
                    == bundleIdentifier
        }
    }

    func launchTypedAppMatchIfNeeded() -> Bool {
        let trimmed = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        guard normalized.count >= 2 else { return false }
        guard !(isL2ContextActive && !isGlobalContextActive) else { return false }

        let installedScopeMode = contextDockInstalledAppScopeMatching
        let runningOnly = contextDockRunningOnlyAppMatching && !installedScopeMode
        let runningBundleIds = runningOnly ? runningBundleIdsForContextDock() : []

        if let target = L2AppActionRouter.shared.appScopeTarget(for: normalized),
            !runningOnly || runningBundleIds.contains(target.bundleId),
            target.actionQuery.isEmpty
        {
            return launchApplication(
                bundleIdentifier: target.bundleId,
                appName: target.appName
            )
        }

        if let target = installedAppMenuTarget(
            for: normalized,
            runningOnly: runningOnly,
            includeAppsWithoutMenuSnapshot: installedScopeMode,
            allowPrefixAlias: installedScopeMode
        ),
            target.actionQuery.isEmpty
        {
            return launchApplication(
                bundleIdentifier: target.bundleId,
                appName: target.appName,
                path: target.appPath
            )
        }

        guard !normalized.contains(" ") else { return false }
        let shouldUsePrefixMatch = (runningOnly ? 3...3 : 2...3).contains(normalized.count)

        if isL2ContextActive,
            let completion = l2.appCompletion
                ?? bestL2PartialAppCompletion(for: normalized, runningOnly: runningOnly),
            completion.actionQuery.isEmpty,
            !completion.ghost.isEmpty
        {
            return launchApplication(
                bundleIdentifier: completion.bundleId, appName: completion.appName)
        }

        if shouldUsePrefixMatch,
            let completion = bestL2PartialAppCompletion(for: normalized, runningOnly: runningOnly),
            completion.actionQuery.isEmpty
        {
            return launchApplication(
                bundleIdentifier: completion.bundleId, appName: completion.appName)
        }

        if let result = allApplications.first(where: { result in
            guard !runningOnly else { return false }
            let title = result.title.lowercased()
            return title == normalized
                || (shouldUsePrefixMatch
                    && title.hasPrefix(normalized)
                    && shouldAllowShortAppPrefixMatch(
                        prefix: normalized,
                        appName: result.title,
                        bundleIdentifier: bundleIdentifierForApplicationPath(result.subtitle)
                    ))
        }) {
            let bundleId = bundleIdentifierForApplicationPath(result.subtitle)
            return launchApplication(
                bundleIdentifier: bundleId, appName: result.title, path: result.subtitle)
        }

        if let app = runningRegularApps.first(where: { app in
            guard let name = app.localizedName?.lowercased() else { return false }
            return name == normalized
                || (shouldUsePrefixMatch
                    && name.hasPrefix(normalized)
                    && shouldAllowShortAppPrefixMatch(
                        prefix: normalized,
                        appName: app.localizedName ?? "",
                        bundleIdentifier: app.bundleIdentifier
                    ))
        }) {
            return launchApplication(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.localizedName,
                path: app.bundleURL?.path
            )
        }

        return false
    }

}
