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
        let ids = windowReviewNavigationIDs
        guard !ids.isEmpty else { return false }
        let focused = windowReviewFocusedID ?? ids.first!
        if focused.hasPrefix("tab:"),
            let tab = filteredWindowReviewSafariTabs.first(where: { "tab:\($0.id)" == focused }) {
            AppDelegate.shared?.smartScopeActive = false
            AppDelegate.shared?.hideLauncher()
            SafariTabManager.shared.switchTo(tab)
            return true
        }
        for group in filteredWindowReviewGroups {
            if let preview = group.windows.first(where: {
                "window:\(group.id):\($0.id)" == focused
            }) {
                AppDelegate.shared?.smartScopeActive = false
                AppDelegate.shared?.hideLauncher()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    windowReviewService.focus(preview, in: group.app)
                }
                return true
            }
        }
        return false
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

    // MARK: - Compact App Switcher (alt-tab layout)

    /// All running apps (unfiltered). The app row always shows every app so typing in the input
    /// filters the selected app's TABS/windows instead of hiding apps from the row.
    var appSwitcherAllGroups: [WindowReviewGroup] { windowReviewService.reviewGroups }

    func appSwitcherIsBrowser(_ g: WindowReviewGroup) -> Bool {
        (g.app.bundleIdentifier ?? "").lowercased().contains("safari")
    }

    /// Query-filtered tabs for a browser group (Safari). Typing in the input filters these.
    func appSwitcherTabs(for g: WindowReviewGroup) -> [SafariTab] {
        appSwitcherIsBrowser(g) ? filteredWindowReviewSafariTabs : []
    }

    func appSwitcherSelectedGroupIndex() -> Int {
        let groups = appSwitcherAllGroups
        guard let fid = windowReviewFocusedID else { return 0 }
        if fid.hasPrefix("tab:") {
            return groups.firstIndex(where: appSwitcherIsBrowser) ?? 0
        }
        return groups.firstIndex { g in
            g.windows.contains { "window:\(g.id):\($0.id)" == fid }
        } ?? 0
    }

    /// Index of the focused content item (tab for a browser, else window) in the group.
    func appSwitcherSelectedContentIndex(in g: WindowReviewGroup) -> Int {
        guard let fid = windowReviewFocusedID else { return 0 }
        let tabs = appSwitcherTabs(for: g)
        if !tabs.isEmpty { return tabs.firstIndex { "tab:\($0.id)" == fid } ?? 0 }
        return g.windows.firstIndex { "window:\(g.id):\($0.id)" == fid } ?? 0
    }

    func selectAppSwitcher(appIndex: Int, contentIndex: Int) {
        let groups = appSwitcherAllGroups
        guard !groups.isEmpty else { return }
        let ai = ((appIndex % groups.count) + groups.count) % groups.count
        let g = groups[ai]
        let tabs = appSwitcherTabs(for: g)
        if !tabs.isEmpty {
            let ti = ((contentIndex % tabs.count) + tabs.count) % tabs.count
            windowReviewFocusedID = "tab:\(tabs[ti].id)"
        } else if !g.windows.isEmpty {
            let wi = ((contentIndex % g.windows.count) + g.windows.count) % g.windows.count
            windowReviewFocusedID = "window:\(g.id):\(g.windows[wi].id)"
        } else {
            return
        }
        isKeyboardNavigation = true
        isSearchFieldFocused = false
    }

    func appSwitcherCycleApp(_ dir: Int) {
        guard !appSwitcherAllGroups.isEmpty else { return }
        selectAppSwitcher(appIndex: appSwitcherSelectedGroupIndex() + dir, contentIndex: 0)
    }

    func appSwitcherCycleWindow(_ dir: Int) {
        let groups = appSwitcherAllGroups
        guard !groups.isEmpty else { return }
        let ai = appSwitcherSelectedGroupIndex()
        selectAppSwitcher(
            appIndex: ai,
            contentIndex: appSwitcherSelectedContentIndex(in: groups[ai]) + dir)
    }

    @ViewBuilder
    var windowReviewScopeView: some View {
        let groups = appSwitcherAllGroups
        if groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text(searchState.query.isEmpty ? "No open windows" : "No matching windows")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            let ai = min(appSwitcherSelectedGroupIndex(), groups.count - 1)
            let group = groups[ai]
            let tabs = appSwitcherTabs(for: group)
            let ci = appSwitcherSelectedContentIndex(in: group)
            VStack(spacing: 14) {
                // App row — directly below the input (the alt-tab strip).
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(groups.enumerated()), id: \.element.id) { idx, g in
                                appSwitcherAppIcon(g, selected: idx == ai)
                                    .id("app:\(g.id)")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: windowReviewFocusedID) { _, _ in
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo("app:\(group.id)", anchor: .center)
                        }
                    }
                }

                if !tabs.isEmpty {
                    // Browser: big preview of the focused tab + a tabs strip the input filters.
                    let tab = tabs.indices.contains(ci) ? tabs[ci] : tabs[0]
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.blue.opacity(0.08))
                        VStack(spacing: 10) {
                            Image(systemName: tab.icon).font(.system(size: 46)).foregroundStyle(.blue)
                            Text(tab.domain).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 168).padding(.horizontal, 14)

                    Text("\(group.name) — \(tab.title.isEmpty ? tab.domain : tab.title)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 14)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { idx, t in
                                appSwitcherTabThumb(t, selected: idx == ci)
                            }
                        }.padding(.horizontal, 14)
                    }
                } else {
                    // App windows: big preview of the focused window + a strip when >1.
                    let wi = min(ci, max(group.windows.count - 1, 0))
                    let preview = group.windows.indices.contains(wi) ? group.windows[wi] : nil
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                        if let image = preview?.image {
                            Image(decorative: image, scale: 1)
                                .resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .padding(8)
                        } else if let icon = group.icon {
                            Image(nsImage: icon).resizable().scaledToFit()
                                .frame(width: 90, height: 90)
                        }
                        if preview?.minimized == true {
                            Text("Minimized")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                .padding(10)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 168).padding(.horizontal, 14)

                    Text("\(group.name)\(preview.map { " — \($0.title)" } ?? "")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 14)

                    if group.windows.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(group.windows.enumerated()), id: \.element.id) { idx, w in
                                    appSwitcherWindowThumb(w, group: group, selected: idx == wi)
                                }
                            }.padding(.horizontal, 14)
                        }
                    }
                }
            }
            .padding(.vertical, 14)
        }
    }

    func appSwitcherTabThumb(_ tab: SafariTab, selected: Bool) -> some View {
        Button {
            AppDelegate.shared?.smartScopeActive = false
            AppDelegate.shared?.hideLauncher()
            SafariTabManager.shared.switchTo(tab)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.blue.opacity(0.08))
                VStack(spacing: 5) {
                    Image(systemName: tab.icon).font(.system(size: 22)).foregroundStyle(.blue)
                    Text(tab.title.isEmpty ? tab.domain : tab.title)
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        .lineLimit(1).frame(maxWidth: 120)
                }
            }
            .frame(width: 132, height: 82)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.85) : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    func appSwitcherAppIcon(_ group: WindowReviewGroup, selected: Bool) -> some View {
        Button {
            selectAppSwitcher(
                appIndex: appSwitcherAllGroups.firstIndex { $0.id == group.id } ?? 0,
                contentIndex: 0)
        } label: {
            VStack(spacing: 5) {
                if let icon = group.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 52, height: 52)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 40))
                }
                Text(group.name)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1).frame(maxWidth: 76)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(
                selected ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    func appSwitcherWindowThumb(
        _ w: RunningAppWindowPreview, group: WindowReviewGroup, selected: Bool
    ) -> some View {
        Button {
            selectAppSwitcher(
                appIndex: appSwitcherAllGroups.firstIndex { $0.id == group.id } ?? 0,
                contentIndex: group.windows.firstIndex { $0.id == w.id } ?? 0)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                if let image = w.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(3)
                }
            }
            .frame(width: 132, height: 82)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.85) : Color.clear, lineWidth: 2))
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
