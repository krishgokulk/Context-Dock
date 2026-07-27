import AppKit
import SwiftUI

extension LauncherView {
    func activateWindowReviewScope() {
        AppDelegate.shared?.smartScopeActive = true
        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
            searchState.contextApp = nil
            searchState.activeSmartQueryKey = "windows"
            l2.targetApp = nil
            showContextInDock = true
            showMediaLayer = false
            aiMode.isActive = false
            globalContextActivation = nil
            globalInlineAppScope = nil
            additionalGlobalInlineAppScopes = []
            searchState.isInSmartMode = false
            searchState.results = []
            searchState.grouped = GroupedResults()
            searchState.selectedIndex = nil
            clearPinnedResults()
            searchState.query = ""
            windowReviewFocusedID = nil
            isSearchBarExpanded = true
            livePanelVisible = false
        }
        windowReviewService.loadWindowReview()
        syncSafariTabStrip(force: true)
        reclaimCompactScopeInputFocus()
        // The hotkey first opens the shell at compact height, then posts this scope on the
        // following run-loop turn. Size only after SwiftUI has observed `activeSmartQueryKey`;
        // otherwise the resolver measures the previous collapsed surface and clips this view.
        DispatchQueue.main.async {
            renderedDockHeight = calculatedHeight
            requestWindowSizeUpdate(
                reason: .modeChanged, animated: true, debounceNanoseconds: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                renderedDockHeight = calculatedHeight
                requestWindowSizeUpdate(
                    reason: .contentSettled, animated: true, debounceNanoseconds: 0)
            }
        }
    }

    var filteredWindowReviewGroups: [WindowReviewGroup] {
        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return windowReviewService.reviewGroups }
        return windowReviewService.reviewGroups.compactMap { group in
            let appMatches = group.name.lowercased().contains(query)
            let windows = appMatches
                ? group.windows
                : group.windows.filter { $0.title.lowercased().contains(query) }
            guard !windows.isEmpty else { return nil }
            return WindowReviewGroup(
                id: group.id, app: group.app, name: group.name,
                icon: group.icon, windows: windows)
        }
    }

    var filteredWindowReviewSafariTabs: [SafariTab] {
        let query = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return safariTabPickerTabs }
        return safariTabPickerTabs.filter {
            $0.title.lowercased().contains(query) || $0.url.lowercased().contains(query)
                || "safari".contains(query)
        }
    }

    var windowReviewNavigationIDs: [String] {
        filteredWindowReviewSafariTabs.map { "tab:\($0.id)" }
            + filteredWindowReviewGroups.flatMap { group in
                group.windows.map { "window:\(group.id):\($0.id)" }
            }
    }

    var windowReviewNavigationRows: [[String]] {
        var rows: [[String]] = []
        let tabs = filteredWindowReviewSafariTabs.map { "tab:\($0.id)" }
        if !tabs.isEmpty { rows.append(tabs) }
        rows.append(contentsOf: filteredWindowReviewGroups.compactMap { group in
            let ids = group.windows.map { "window:\(group.id):\($0.id)" }
            return ids.isEmpty ? nil : ids
        })
        return rows
    }

    func navigateWindowReview(horizontal direction: Int) {
        let rows = windowReviewNavigationRows
        guard !rows.isEmpty else { return }
        let location: (row: Int, column: Int)? = rows.enumerated().compactMap { row, ids in
            ids.firstIndex(where: { $0 == windowReviewFocusedID }).map { (row, $0) }
        }.first
        let row = location?.row ?? (direction > 0 ? 0 : rows.count - 1)
        let start = location?.column ?? (direction > 0 ? -1 : rows[row].count)
        let column = min(max(start + direction, 0), rows[row].count - 1)
        windowReviewFocusedID = rows[row][column]
        isKeyboardNavigation = true
        isSearchFieldFocused = false
    }

    func navigateWindowReview(vertical direction: Int) {
        let rows = windowReviewNavigationRows
        guard !rows.isEmpty else { return }
        let location: (row: Int, column: Int)? = rows.enumerated().compactMap { row, ids in
            ids.firstIndex(where: { $0 == windowReviewFocusedID }).map { (row, $0) }
        }.first
        let startRow = location?.row ?? (direction > 0 ? -1 : rows.count)
        let row = min(max(startRow + direction, 0), rows.count - 1)
        let column = min(location?.column ?? 0, rows[row].count - 1)
        windowReviewFocusedID = rows[row][column]
        isKeyboardNavigation = true
        isSearchFieldFocused = false
    }

    func windowReviewRowID(containing focusID: String?) -> String? {
        guard let focusID else { return nil }
        if focusID.hasPrefix("tab:") { return "window-review-row-tabs" }
        return filteredWindowReviewGroups.first(where: { group in
            group.windows.contains { "window:\(group.id):\($0.id)" == focusID }
        }).map { "window-review-row-\($0.id)" }
    }

    func executeFocusedWindowReviewItem() -> Bool {
        let items = windowSwitcherItems
        guard !items.isEmpty else { return false }
        let focused = windowReviewFocusedID
        // App-level focus (no window picked yet): first Enter drills into the app's windows.
        if let focused, focused.hasPrefix("app:") {
            let app = String(focused.dropFirst(4))
            if let first = windowsForApp(app).first {
                windowReviewFocusedID = first.id
                return true
            }
        }
        guard let item = items.first(where: { $0.id == focused }) ?? items.first else {
            return false
        }
        windowSwitcherActivate(item)
        return true
    }

    func quickLookFocusedWindowReviewItem() -> Bool {
        let ids = windowReviewNavigationIDs
        guard !ids.isEmpty else { return false }
        let focused = windowReviewFocusedID ?? ids.first!
        windowReviewFocusedID = focused
        if focused.hasPrefix("tab:"),
            let tab = filteredWindowReviewSafariTabs.first(where: { "tab:\($0.id)" == focused }),
            let url = URL(string: tab.url) {
            WebQuickLookPanel.shared.toggle(url: url)
            return true
        }
        for group in filteredWindowReviewGroups {
            if let preview = group.windows.first(where: {
                "window:\(group.id):\($0.id)" == focused
            }) {
                windowReviewService.toggleQuickLook(preview, in: group.app)
                return true
            }
        }
        return false
    }

    // MARK: - Compact Window Switcher / Searcher

    /// One row per open window (and, for a browser, per open tab) across ALL apps. The input
    /// searches every window by app name + window title (+ tab title/url), so this is a flat
    /// window switcher, not an app-at-a-time picker.
    struct WindowSwitcherItem: Identifiable {
        let id: String            // "window:pid:winid" or "tab:tabid"
        let appName: String
        let title: String
        let appIcon: NSImage?
        let thumb: CGImage?
        let isTab: Bool
        let minimized: Bool
        let group: WindowReviewGroup?
        let tab: SafariTab?
    }

    func appSwitcherIsBrowser(_ g: WindowReviewGroup) -> Bool {
        (g.app.bundleIdentifier ?? "").lowercased().contains("safari")
    }

    var windowSwitcherItems: [WindowSwitcherItem] {
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func matches(_ fields: [String]) -> Bool {
            q.isEmpty || fields.contains { $0.lowercased().contains(q) }
        }
        var items: [WindowSwitcherItem] = []
        for g in windowReviewService.reviewGroups {
            if appSwitcherIsBrowser(g), !safariTabPickerTabs.isEmpty {
                // Browser → each tab is a switchable item.
                for t in safariTabPickerTabs where matches([g.name, t.title, t.url, t.domain]) {
                    items.append(.init(
                        id: "tab:\(t.id)", appName: g.name,
                        title: t.title.isEmpty ? t.domain : t.title,
                        appIcon: g.icon, thumb: nil, isTab: true, minimized: false,
                        group: g, tab: t))
                }
            } else {
                for w in g.windows where matches([g.name, w.title]) {
                    items.append(.init(
                        id: "window:\(g.id):\(w.id)", appName: g.name,
                        title: w.title.isEmpty ? g.name : w.title,
                        appIcon: g.icon, thumb: w.image, isTab: false, minimized: w.minimized,
                        group: g, tab: nil))
                }
            }
        }
        return items
    }

    /// Unique app names in item order — used for the quick app-jump row.
    var windowSwitcherApps: [(name: String, icon: NSImage?)] {
        var seen = Set<String>()
        var out: [(String, NSImage?)] = []
        for it in windowSwitcherItems where seen.insert(it.appName).inserted {
            out.append((it.appName, it.appIcon))
        }
        return out.map { (name: $0.0, icon: $0.1) }
    }

    /// Non-empty query → the input is searching every window; show a flat results grid.
    var windowSwitcherIsSearching: Bool {
        !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The app currently focused in the row. "app:<name>" focus = app level (compact, its
    /// windows popped below); a "window:" focus resolves to its owning app.
    var windowSwitcherFocusedAppName: String? {
        guard let fid = windowReviewFocusedID else { return windowSwitcherApps.first?.name }
        if fid.hasPrefix("app:") { return String(fid.dropFirst(4)) }
        return windowSwitcherItems.first { $0.id == fid }?.appName
    }

    func windowsForApp(_ name: String) -> [WindowSwitcherItem] {
        windowSwitcherItems.filter { $0.appName == name }
    }

    func windowSwitcherIndex() -> Int {
        windowSwitcherItems.firstIndex { $0.id == windowReviewFocusedID } ?? 0
    }

    func windowSwitcherSelect(_ idx: Int) {
        let items = windowSwitcherItems
        guard !items.isEmpty else { return }
        let i = ((idx % items.count) + items.count) % items.count
        windowReviewFocusedID = items[i].id
        isKeyboardNavigation = true
        isSearchFieldFocused = false
    }

    /// Tab / ←/→ at app level cycle apps; while searching, move through the flat results.
    func appSwitcherCycleApp(_ dir: Int) {
        if windowSwitcherIsSearching {
            windowSwitcherSelect(windowSwitcherIndex() + dir)
            return
        }
        let apps = windowSwitcherApps.map(\.name)
        guard !apps.isEmpty else { return }
        let cur = windowSwitcherFocusedAppName ?? apps[0]
        let ci = apps.firstIndex(of: cur) ?? 0
        let next = apps[((ci + dir) % apps.count + apps.count) % apps.count]
        windowReviewFocusedID = "app:\(next)"  // app-level: windows pop below, none focused yet
        isKeyboardNavigation = true
        isSearchFieldFocused = false
    }

    /// ←/→: while a window is focused, move within that app's windows; else cycle apps.
    func windowSwitcherLeftRight(_ dir: Int) {
        if windowSwitcherIsSearching {
            windowSwitcherSelect(windowSwitcherIndex() + dir)
            return
        }
        if let fid = windowReviewFocusedID, fid.hasPrefix("window:"),
            let app = windowSwitcherFocusedAppName {
            let wins = windowsForApp(app)
            let idx = wins.firstIndex { $0.id == fid } ?? 0
            let n = min(max(idx + dir, 0), wins.count - 1)
            if wins.indices.contains(n) { windowReviewFocusedID = wins[n].id }
            isKeyboardNavigation = true
            isSearchFieldFocused = false
        } else {
            appSwitcherCycleApp(dir)
        }
    }

    /// ↓ drills into the selected app's windows (or next window); ↑ steps back to the app row.
    func windowSwitcherUpDown(_ dir: Int) {
        if windowSwitcherIsSearching {
            windowSwitcherSelect(windowSwitcherIndex() + dir)
            return
        }
        guard let app = windowSwitcherFocusedAppName else { return }
        let wins = windowsForApp(app)
        guard !wins.isEmpty else { return }
        let fid = windowReviewFocusedID
        if fid == nil || fid!.hasPrefix("app:") {
            if dir > 0 { windowReviewFocusedID = wins[0].id }  // down → into windows
        } else {
            let idx = wins.firstIndex { $0.id == fid } ?? 0
            if dir < 0, idx == 0 {
                windowReviewFocusedID = "app:\(app)"  // up from first → back to app row
            } else {
                let n = min(max(idx + dir, 0), wins.count - 1)
                windowReviewFocusedID = wins[n].id
            }
        }
        isKeyboardNavigation = true
        isSearchFieldFocused = false
    }

    func windowSwitcherActivate(_ item: WindowSwitcherItem) {
        AppDelegate.shared?.smartScopeActive = false
        AppDelegate.shared?.hideLauncher()
        if let tab = item.tab {
            SafariTabManager.shared.switchTo(tab)
        } else if let group = item.group,
            let w = group.windows.first(where: { "window:\(group.id):\($0.id)" == item.id }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                windowReviewService.focus(w, in: group.app)
            }
        }
    }

    @ViewBuilder
    var windowReviewScopeView: some View {
        let items = windowSwitcherItems
        let apps = windowSwitcherApps
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 26)).foregroundStyle(.secondary)
                Text(searchState.query.isEmpty ? "No open windows" : "No matching windows")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if windowSwitcherIsSearching {
            // Searching: flat grid of every matching window/tab across all apps.
            let focused = windowReviewFocusedID ?? items.first?.id
            VStack(spacing: 0) {
                windowSwitcherGrid(items, focused: focused)
            }.padding(.vertical, 12)
        } else {
            // Idle: compact — just the app row; the focused app's windows pop below it.
            let focusedApp = windowSwitcherFocusedAppName
            let appWindows = focusedApp.map(windowsForApp) ?? []
            let focused = windowReviewFocusedID
            let windowFocused = focused?.hasPrefix("window:") == true
            // Compact until the user picks an app: windows pop below only after a selection.
            let showWindows = focused != nil && !appWindows.isEmpty
            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(apps, id: \.name) { app in
                            Button { appSwitcherFocusApp(app.name) } label: {
                                appRowIcon(app, selected: focused != nil && app.name == focusedApp)
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 14).padding(.top, 2)
                }

                // Windows of the selected app pop in below the row (compact).
                if showWindows {
                    windowSwitcherGrid(appWindows, focused: windowFocused ? focused : nil)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, 12)
            .animation(.easeOut(duration: 0.16), value: focused)
        }
    }

    @ViewBuilder
    func windowSwitcherGrid(_ items: [WindowSwitcherItem], focused: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 176, maximum: 240), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(items) { item in
                        windowSwitcherCard(item, selected: item.id == focused)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 6)
            }
            .frame(maxHeight: 340)
            .onChange(of: windowReviewFocusedID) { _, id in
                guard let id, id.hasPrefix("window:") || id.hasPrefix("tab:") else { return }
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    func appRowIcon(_ app: (name: String, icon: NSImage?), selected: Bool) -> some View {
        VStack(spacing: 4) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 44, height: 44)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 32))
            }
            Text(app.name)
                .font(.system(size: 9, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1).frame(maxWidth: 70)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            selected ? Color.accentColor.opacity(0.16) : .clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5))
    }

    /// Focus an app at app-level (pops its windows below); clicking again drills into them.
    func appSwitcherFocusApp(_ name: String) {
        if windowSwitcherFocusedAppName == name,
            let first = windowsForApp(name).first,
            windowReviewFocusedID?.hasPrefix("window:") != true {
            windowReviewFocusedID = first.id
        } else {
            windowReviewFocusedID = "app:\(name)"
        }
        isKeyboardNavigation = true
        isSearchFieldFocused = false
    }

    func appSwitcherJumpToApp(_ name: String) {
        if let idx = windowSwitcherItems.firstIndex(where: { $0.appName == name }) {
            windowSwitcherSelect(idx)
        }
    }

    func windowSwitcherCard(_ item: WindowSwitcherItem, selected: Bool) -> some View {
        Button { windowSwitcherActivate(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(item.isTab ? Color.blue.opacity(0.08) : Color.primary.opacity(0.05))
                    if let thumb = item.thumb {
                        Image(decorative: thumb, scale: 1).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .padding(3)
                    } else if let icon = item.appIcon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 40, height: 40)
                    }
                    if item.minimized {
                        Text("Minimized").font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(6)
                    }
                }
                .frame(height: 108)
                HStack(spacing: 5) {
                    if let icon = item.appIcon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 14, height: 14)
                    }
                    Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
            }
            .padding(4)
            .background(
                selected ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var windowReviewScopeViewLegacyGrid: some View {
        let groups = filteredWindowReviewGroups
        let safariTabs = filteredWindowReviewSafariTabs
        if groups.isEmpty && safariTabs.isEmpty {
            EmptyView()
        } else {
            ScrollViewReader { verticalProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                    if !safariTabs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                Image(systemName: "safari").foregroundStyle(.blue)
                                Text("Safari Tabs").font(.system(size: 13, weight: .semibold))
                                Text("\(safariTabs.count)").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }.padding(.horizontal, 14)
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 10) {
                                        ForEach(safariTabs) { tab in windowReviewSafariTabCard(tab) }
                                    }.padding(.horizontal, 14).padding(.bottom, 3)
                                }
                                .onChange(of: windowReviewFocusedID) { _, id in
                                    guard id?.hasPrefix("tab:") == true else { return }
                                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) }
                                }
                            }
                        }.id("window-review-row-tabs")
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                if let icon = group.icon {
                                    Image(nsImage: icon).resizable().frame(width: 19, height: 19)
                                }
                                Text(group.name).font(.system(size: 13, weight: .semibold))
                                Text("\(group.windows.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)

                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 10) {
                                        ForEach(group.windows) { preview in
                                            windowReviewCard(preview, group: group)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 3)
                                }
                                .onChange(of: windowReviewFocusedID) { _, id in
                                    guard id?.hasPrefix("window:\(group.id):") == true else { return }
                                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) }
                                }
                            }
                        }.id("window-review-row-\(group.id)")
                    }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: windowReviewFocusedID) { _, id in
                    guard let rowID = windowReviewRowID(containing: id) else { return }
                    withAnimation(.easeOut(duration: 0.16)) { verticalProxy.scrollTo(rowID, anchor: .center) }
                }
            }
            .frame(maxHeight: 540)
        }
    }

    func windowReviewSafariTabCard(_ tab: SafariTab) -> some View {
        let focusID = "tab:\(tab.id)"
        return Button {
            AppDelegate.shared?.smartScopeActive = false
            AppDelegate.shared?.hideLauncher()
            SafariTabManager.shared.switchTo(tab)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue.opacity(0.09))
                    VStack(spacing: 8) {
                        Image(systemName: tab.icon).font(.system(size: 30)).foregroundStyle(.blue)
                        Text(tab.domain).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(width: 220, height: 132)
                Text(tab.title.isEmpty ? tab.domain : tab.title)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .frame(width: 220, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .padding(3)
        .background(
            windowReviewFocusedID == focusID ? Color.accentColor.opacity(0.20) : .clear,
            in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(
                windowReviewFocusedID == focusID ? Color.accentColor.opacity(0.8) : .clear,
                lineWidth: 1.5))
        .id(focusID)
    }

    func windowReviewCard(_ preview: RunningAppWindowPreview, group: WindowReviewGroup) -> some View {
        let focusID = "window:\(group.id):\(preview.id)"
        return Button {
            AppDelegate.shared?.smartScopeActive = false
            AppDelegate.shared?.hideLauncher()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                windowReviewService.focus(preview, in: group.app)
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                    if let image = preview.image {
                        Image(decorative: image, scale: 1)
                            .resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(4)
                    } else if let icon = group.icon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 54, height: 54)
                    }
                    if preview.minimized {
                        Text("Minimized")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(7)
                    }
                }
                .frame(width: 220, height: 132)
                Text(preview.title)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .frame(width: 220, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .padding(3)
        .background(
            windowReviewFocusedID == focusID ? Color.accentColor.opacity(0.20) : .clear,
            in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(
                windowReviewFocusedID == focusID ? Color.accentColor.opacity(0.8) : .clear,
                lineWidth: 1.5))
        .id(focusID)
    }
}
