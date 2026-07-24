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

    func navigateWindowReview(direction: Int) {
        let ids = windowReviewNavigationIDs
        guard !ids.isEmpty else { return }
        let current = windowReviewFocusedID.flatMap { ids.firstIndex(of: $0) }
        let next = min(max((current ?? (direction > 0 ? -1 : ids.count)) + direction, 0), ids.count - 1)
        windowReviewFocusedID = ids[next]
        isKeyboardNavigation = true
        isSearchFieldFocused = false
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

    @ViewBuilder
    var windowReviewScopeView: some View {
        let groups = filteredWindowReviewGroups
        let safariTabs = filteredWindowReviewSafariTabs
        if groups.isEmpty && safariTabs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text(searchState.query.isEmpty ? "No open windows" : "No matching windows")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
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
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 10) {
                                    ForEach(safariTabs) { tab in windowReviewSafariTabCard(tab) }
                                }.padding(.horizontal, 14).padding(.bottom, 3)
                            }
                        }
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

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 10) {
                                    ForEach(group.windows) { preview in
                                        windowReviewCard(preview, group: group)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.bottom, 3)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
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
    }
}
