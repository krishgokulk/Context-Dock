import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct ContextDockBottomListFlip: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.rotationEffect(.degrees(180))
        } else {
            content
        }
    }
}

extension View {
    func contextDockBottomListFlip(_ enabled: Bool) -> some View {
        modifier(ContextDockBottomListFlip(enabled: enabled))
    }
}

extension LauncherView {
    // MARK: - List view (Spotlight / Raycast-style vertical result sheet)

    func dockPillListView(pills: [DockPill]) -> some View {
        let visiblePills = clusterPillsByGroup(Array(pills.prefix(maxListViewDockPills)))
        let list = ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(visiblePills.enumerated()), id: \.element.id) { idx, pill in
                        if pill.isSeparator {
                            if !pill.name.isEmpty {
                                HStack {
                                    Text(pill.name.uppercased())
                                        .font(
                                            .system(size: 10, weight: .semibold, design: .rounded)
                                        )
                                        .foregroundStyle(.tertiary)
                                        .tracking(0.7)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, idx == 0 ? 2 : 8)
                                .padding(.bottom, 1)
                                .id("pill-list-\(pill.id)")
                                .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                            }
                        } else {
                            let currentGroup = dockListGroupTitle(for: pill)
                            let previousGroup: String? = {
                                guard idx > 0 else { return nil }
                                let previous = visiblePills[idx - 1]
                                guard !previous.isSeparator else { return nil }
                                return dockListGroupTitle(for: previous)
                            }()
                            if currentGroup != previousGroup {
                                resultGroupHeader(currentGroup)
                                    .padding(.top, idx == 0 ? 0 : 6)
                                    .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                            }
                            pillListRow(pill: pill, index: idx)
                                .id("pill-list-\(pill.id)")
                                .contextDockBottomListFlip(settings.effectiveDockAtBottom)
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Measure the real rendered content (section headers vary per app) so the
                // panel hugs it instead of relying on a row-count estimate that undercounts
                // multiple headers and clips the last row at the rounded corner.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    updateMeasuredGlobalListHeight(height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextDockBottomListFlip(settings.effectiveDockAtBottom)
            .frame(maxWidth: .infinity, maxHeight: listViewVisibleHeight, alignment: .leading)
            .background {
                if settings.effectiveDockAtBottom {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        // Match the input bar's Glass Darkness so the message/result panel
                        // reads as the same solid glass, not a more-transparent sheet.
                        .fill(Color.black.opacity(settings.glassDarkness * 0.22))
                        .background(GlassBackground(cornerRadius: 18, isDark: isEffectiveDark))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(isEffectiveDark ? 0.12 : 0.20), lineWidth: 0.8)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onChange(of: l2.focusedPillIndex) { newIndex in
                guard l2.pillNavViaKeyboard, let idx = newIndex else { return }
                // Keyboard now walks the same clustered order the list renders —
                // resolve the focused pill from that order and scroll to it by id.
                let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let source = renderedOrderDockPills(for: q)
                guard idx >= 0, idx < source.count else { return }
                let targetID = source[idx].id
                guard visiblePills.contains(where: { $0.id == targetID }) else { return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                    proxy.scrollTo("pill-list-\(targetID)", anchor: .center)
                }
                DispatchQueue.main.async {
                    refreshQuickLookPreviewForCurrentFocusIfVisible()
                }
            }
        }
        // When drilling into a folder, show a Finder-style breadcrumb footer below
        // the contents (⌫ walks back out).
        return VStack(spacing: 0) {
            list
            if isBrowsingFinderFolder {
                Divider().opacity(0.12).padding(.horizontal, 10)
                finderBrowseBreadcrumb
            }
        }
    }

    /// Cluster pills so every pill sharing a group title is contiguous, keeping
    /// the order each group first appears and the relevance order within a group.
    /// Without this, score-interleaved results (app, file, app, file…) render a
    /// repeated "Applications" header instead of one grouped section.
    /// Pills carrying explicit separators define their own sections, so leave
    /// those lists untouched.
    func clusterPillsByGroup(_ pills: [DockPill]) -> [DockPill] {
        guard !pills.contains(where: { $0.isSeparator }) else { return pills }
        var order: [String] = []
        var buckets: [String: [DockPill]] = [:]
        for pill in pills {
            let group = dockListGroupTitle(for: pill)
            if buckets[group] == nil {
                order.append(group)
                buckets[group] = []
            }
            buckets[group]?.append(pill)
        }
        return order.flatMap { buckets[$0] ?? [] }
    }

    func dockListGroupTitle(for pill: DockPill) -> String {
        let kind = pill.rankingKind.lowercased()
        let badge = (pill.badge ?? "").lowercased()
        let context = (pill.menuContext ?? "").lowercased()
        let name = pill.name.lowercased()

        if kind == "setuphint" {
            return "Search"
        }
        // Safari history rows group under their Safari-style date bucket
        // ("Earlier Today", "Today", "Yesterday", "Wednesday, 24 June 2026").
        if kind == "recenturl" {
            if let bucket = pill.menuContext, !bucket.isEmpty { return bucket }
            return "Safari History"
        }
        if kind == "clipboard" {
            return "Clipboard Items"
        }
        if kind == "findermenu" {
            return "Finder Menus"
        }
        if kind == "submenuchild", let context = pill.menuContext, !context.isEmpty {
            return context == "Apple Menu" ? context : "\(context) Menu"
        }
        if kind == "finderselection" || kind == "findercontext" {
            return "Finder Actions"
        }
        if kind == "findergoto" {
            return "Home Folders"
        }
        if kind == "findercurrent" || kind == "findersearch" {
            // Folder drill-in children carry the parent folder name in menuContext —
            // keep them in the "Current Folder" group, right under the matched folder.
            if kind == "findercurrent", let context = pill.menuContext, !context.isEmpty {
                return "Current Folder"
            }
            if pill.icon.localizedCaseInsensitiveContains("folder")
                || badge.contains("folder")
                || name.contains("folder")
            {
                return kind == "findercurrent" ? "Current Folder" : "Home Folders"
            }
            return "Files"
        }
        if kind == "finderrecentapp" {
            return "Applications"
        }
        if kind == "finderrecent" || kind == "spotlightsearch" {
            // Group by type (Folders / Images / Documents / Media / Files) — the ranker clusters
            // the pills so each header appears once, best-matching group first.
            return finderDesktopTypeGroup(pill)
        }
        if kind.contains("finder") || badge.contains("finder") {
            return "Finder"
        }
        if kind.contains("menu") || !context.isEmpty {
            if let root = dockMenuRootTitle(for: pill) {
                return root == "Apple" ? "Apple Menu" : "\(root) Menu"
            }
            if let context = pill.menuContext, !context.isEmpty {
                return context == "Apple Menu" ? context : "\(context) Menu"
            }
            return "Menus"
        }
        if kind.contains("semantic") || kind.contains("payload") {
            return "Actions"
        }
        if kind.contains("applaunch") {
            return "Apps"
        }
        if badge.contains("folder") {
            return "Folders"
        }
        if badge.contains("file") || name.contains(".") {
            return "Files"
        }
        return "Actions"
    }

    func dockMenuRootTitle(for pill: DockPill) -> String? {
        let knownRoots = [
            "Apple", "File", "Edit", "Selection", "View", "Go", "Run", "Terminal",
            "Window", "Help", "History", "Bookmarks", "Navigate", "Product",
            "Debug", "Source Control", "Format", "Tools", "Playback", "Controls",
            "Audio", "Video", "Subtitles",
        ]
        for term in pill.searchTerms {
            let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = knownRoots.first(where: {
                normalizedDockPillText($0) == normalizedDockPillText(cleaned)
            }) {
                return match
            }
        }
        return nil
    }

    // Liquid glass floating suggestion panel — appears below input like the macOS autocomplete popover.
    @ViewBuilder
    func submenuDropdownView(parent: AXMenuItem, children: [AXMenuItem], prefix: String)
        -> some View
    {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // "Sort By" section header
                    Text(parent.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                        let isHov = listViewHoveredIndex == (10000 + idx)
                        let isKeyFocused = l2.focusedPillIndex == idx
                        let isActive = isHov || isKeyFocused

                        Button {
                            let frontPID =
                                AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0
                            let pid = child.sourcePID != 0 ? child.sourcePID : frontPID
                            let path = child.path
                            let sc = child.shortcutChar
                            let mod = child.shortcutModifiers
                            searchState.query = ""
                            lockedSubmenuParent = nil
                            executeDockMenuAction(
                                sourcePID: pid, path: path, shortcutChar: sc, shortcutModifiers: mod
                            )
                        } label: {
                            HStack(spacing: 10) {
                                // Prefix bold: typed part in accentColor, rest in primary
                                if !prefix.isEmpty,
                                    child.title.lowercased().hasPrefix(prefix)
                                {
                                    let boldPart = String(child.title.prefix(prefix.count))
                                    let restPart = String(child.title.dropFirst(prefix.count))
                                    HStack(spacing: 0) {
                                        Text(boldPart)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                        Text(restPart)
                                            .font(.system(size: 14, weight: .regular))
                                            .foregroundStyle(Color(nsColor: .labelColor))
                                    }
                                } else {
                                    Text(child.title)
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundStyle(Color(nsColor: .labelColor))
                                }
                                Spacer()
                                if let sc = child.shortcutDisplay, !sc.isEmpty {
                                    Text(sc)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary.opacity(0.55))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(
                                            .regularMaterial,
                                            in: RoundedRectangle(cornerRadius: 4)
                                        )
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                isActive
                                    ? Color(nsColor: .labelColor).opacity(0.07)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { h in
                            guard acceptsMouseDrivenDockInteraction else { return }
                            listViewHoveredIndex = h ? (10000 + idx) : nil
                        }
                        .padding(.horizontal, 6)
                        .id("submenu-drop-\(idx)")
                    }
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 280)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
            .onChange(of: l2.focusedPillIndex) { newIndex in
                guard let idx = newIndex else { return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                    proxy.scrollTo("submenu-drop-\(idx)", anchor: .center)
                }
            }
        }
        .transition(
            .asymmetric(
                insertion: .opacity.combined(
                    with: .scale(
                        scale: 0.95,
                        anchor: settings.effectiveDockAtBottom ? .bottom : .top)
                ),
                removal: .opacity.combined(
                    with: .scale(
                        scale: 0.95,
                        anchor: settings.effectiveDockAtBottom ? .bottom : .top)
                )
            ))
    }

    @ViewBuilder
    func findTokenChip(_ token: AppFindToken) -> some View {
        let selectedTitle =
            token.selectedMenu?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = token.title
        HStack(spacing: 0) {
            Button {
                clearFindToken(preserveQuery: true)
            } label: {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .padding(.leading, 10)
                    .padding(.trailing, token.hasChildMenu ? 6 : 10)
            }
            .buttonStyle(.plain)
            .help(selectedTitle.isEmpty ? "Remove Find mode" : selectedTitle)

            if token.hasChildMenu {
                Button {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.82)) {
                        showFindTokenMenu.toggle()
                        l2.focusedPillIndex = nil
                        listViewHoveredIndex = nil
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(nsColor: .labelColor).opacity(0.88))
                            .frame(width: 20, height: 20)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    }
                    .padding(.trailing, 4)
                }
                .buttonStyle(.plain)
                .help("Choose Find menu")
            }

            if !selectedTitle.isEmpty {
                Text(selectedTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.trailing, 9)
            }
        }
        .frame(height: 30)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(showFindTokenMenu ? 0.32 : 0.18), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: selectedTitle)
    }

    @ViewBuilder
    func findTokenDropdownView(_ token: AppFindToken) -> some View {
        let children = token.parentMenu.map(leafFindChildren(for:)) ?? []
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Find in \(token.targetAppName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                    let isHov = listViewHoveredIndex == (12000 + idx)
                    let selected = token.selectedMenu?.id == child.id
                    Button {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.82)) {
                            if var updatedToken = lockedFindToken {
                                updatedToken.selectedMenu = child
                                lockedFindToken = updatedToken
                            }
                            showFindTokenMenu = false
                            listViewHoveredIndex = nil
                        }
                        DispatchQueue.main.async { isSearchFieldFocused = true }
                    } label: {
                        HStack(spacing: 10) {
                            Image(
                                systemName: selected
                                    ? "checkmark.circle.fill" : menuSymbol(for: child)
                            )
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .frame(width: 20)
                            Text(child.title)
                                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                                .foregroundStyle(Color(nsColor: .labelColor))
                                .lineLimit(1)
                            Spacer()
                            if let shortcut = child.shortcutDisplay, !shortcut.isEmpty {
                                Text(shortcut)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary.opacity(0.55))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        .regularMaterial,
                                        in: RoundedRectangle(cornerRadius: 4)
                                    )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            (isHov || selected)
                                ? Color(nsColor: .labelColor).opacity(selected ? 0.10 : 0.07)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        guard acceptsMouseDrivenDockInteraction else { return }
                        listViewHoveredIndex = hovering ? (12000 + idx) : nil
                    }
                    .padding(.horizontal, 6)
                }
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 280)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(
                    with: .scale(
                        scale: 0.95,
                        anchor: settings.effectiveDockAtBottom ? .bottom : .top)
                ),
                removal: .opacity.combined(
                    with: .scale(
                        scale: 0.95,
                        anchor: settings.effectiveDockAtBottom ? .bottom : .top)
                )
            ))
    }

    @ViewBuilder
    func resultGroupHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary.opacity(0.72))
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    @ViewBuilder
    func resultGroupHeader(_ title: String, icon: NSImage?) -> some View {
        HStack(spacing: 9) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 3, x: 0, y: 1)
            }
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.82))
                .textCase(.uppercase)
            Spacer()
            scopePinControl
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Two values with a symbol between them. A conversion is a transformation, and
    /// a title+subtitle line can't show that — the input and the result read as one
    /// becoming the other only when they sit either side of a centre mark.
    @ViewBuilder
    func compareRowBody(pill: DockPill, left: String, accent: SwiftUI.Color) -> some View {
        // A card, not a row. Two equal halves split by a rule with the operator
        // sitting on it, so input and result carry the same weight and the eye reads
        // across rather than down — the shape every calculator uses for a conversion.
        HStack(spacing: 0) {
            comparePane(value: left, caption: pill.name, alignment: .leading,
                        isResult: false, drillQuery: pill.compareLeftQuery,
                        commandID: pill.compareCommandID)
            comparePane(value: pill.compareRight ?? "", caption: pill.badge,
                        alignment: .trailing, isResult: true,
                        drillQuery: pill.compareRightQuery,
                        commandID: pill.compareCommandID)
        }
        .frame(height: 104)
        .overlay {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
        }
        .overlay {
            Image(systemName: pill.compareIcon ?? "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func comparePane(value: String, caption: String?,
                             alignment: HorizontalAlignment, isResult: Bool,
                             drillQuery: String? = nil,
                             commandID: UUID? = nil) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Text(value)
                .font(.system(size: 21, weight: isResult ? .bold : .semibold, design: .rounded))
                .foregroundStyle(isResult ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let caption, !caption.isEmpty {
                // A caption with a drill query is a control, not a label: it opens a
                // dropdown rather than typing the extension's private token into the
                // input, which is what the first version did.
                if let drillQuery, let commandID {
                    CompareCaptionPill(
                        caption: caption, drillQuery: drillQuery, commandID: commandID,
                        onPicked: {
                            scheduleDockPillRebuild(
                                query: searchState.query, delayNanoseconds: 0,
                                refreshContext: false)
                        })
                } else {
                    Text(caption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
    }

    /// Pin lives on the scope header, not in the row list: it acts on the whole
    /// extension, and as a row it both displaced real results and made an empty
    /// panel look like it had content.
    @ViewBuilder
    private var scopePinControl: some View {
        if let command = activeCustomListScopeCommand {
            let pinned = ScopedListPanelManager.shared.isPinned(command.id)
            Button {
                ScopedListPanelManager.shared.toggle(command)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pinned ? AnyShapeStyle(Color.yellow)
                                            : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pinned
                  ? "Unpin — closes the floating panel"
                  : "Pin as a floating panel, like Quick Note")
        }
    }

    @ViewBuilder
    func dockCapsuleSelectionBackground(
        isKeyboardFocused: Bool,
        isHovered: Bool,
        usesMatchedGeometry: Bool = true
    ) -> some View {
        ZStack {
            if isKeyboardFocused {
                if usesMatchedGeometry {
                    Capsule(style: .continuous)
                        .fill(Color.clear)
                        .background(GlassBackground(cornerRadius: 999, isDark: isEffectiveDark))
                        .clipShape(Capsule(style: .continuous))
                        .matchedGeometryEffect(
                            id: dockResultFocusEffectID,
                            in: compactScopeFocusNamespace,
                            properties: .frame,
                            isSource: false
                        )
                } else {
                    Capsule(style: .continuous)
                        .fill(Color.clear)
                        .background(GlassBackground(cornerRadius: 999, isDark: isEffectiveDark))
                        .clipShape(Capsule(style: .continuous))
                }
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isEffectiveDark ? 0.10 : 0.16),
                                Color.white.opacity(isEffectiveDark ? 0.035 : 0.07),
                                Color.black.opacity(isEffectiveDark ? 0.018 : 0.006),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isEffectiveDark ? 0.38 : 0.48),
                                Color.white.opacity(isEffectiveDark ? 0.11 : 0.18),
                                Color.white.opacity(isEffectiveDark ? 0.035 : 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(isEffectiveDark ? 0.30 : 0.22), lineWidth: 0.9)
                    .blur(radius: 1.6)
            } else if isHovered {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isEffectiveDark ? 0.045 : 0.035))
            }
        }
    }

    /// Index of the first selectable (non-separator) action pill, for Spotlight-style default
    /// selection in the context-dock ACTIONS list.
    var firstSelectableDockPillIndex: Int {
        Array(contextDockViewModel.visiblePills.prefix(maxListViewDockPills))
            .firstIndex(where: { !$0.isSeparator }) ?? -1
    }

    @ViewBuilder
    func pillListRow(pill: DockPill, index: Int) -> some View {
        let accent = accentColor(for: pill.accentColorName)
        // Spotlight-style default: highlight the first action pill while typing when nothing is
        // explicitly focused/hovered. Render-only — l2.focusedPillIndex stays nil so Enter keeps
        // its context-dock semantics and the input never collapses to pill-nav mode.
        // Running-app menu scope renders through the grouped list, so its row `index`
        // (groupBase + pillIdx) never equals firstSelectableDockPillIndex, which is computed
        // from contextDockViewModel.visiblePills (empty in scoped-menu mode). Match the first
        // scoped-menu pill by IDENTITY instead — otherwise the auto-selected first row loses
        // isActive and its trailing shortcut/⏎ execute chip never renders.
        let isRunningAppMenuScopeDefaultFirstRow: Bool = {
            guard isActiveGlobalRunningAppMenuScope(),
                l2.focusedPillIndex == nil,
                listViewHoveredIndex == nil
            else { return false }
            let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let menus = visibleGlobalGroupedListNavigationState(for: q).menuPills
            return menus.first(where: { !$0.isSeparator })?.id == pill.id
        }()
        let isDefaultFirstRow =
            (l2.focusedPillIndex == nil
                && listViewHoveredIndex == nil
                && index == firstSelectableDockPillIndex
                && !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // When the global app list already shows a default-first row (apps render
                // above these menu rows), it owns the selection — don't ALSO highlight the
                // first menu row, or two rows show the focus ring at once.
                && !globalAppListOwnsDefaultFirstSelection)
            || isRunningAppMenuScopeDefaultFirstRow
        // Keyboard focus by IDENTITY, not row index: the keyboard navigates the raw
        // pill array while this list renders a re-clustered copy — index equality
        // diverges the moment clustering reorders, breaking highlight + autoscroll.
        let keyboardFocusedPillID: String? = l2.focusedPillIndex.flatMap { idx in
            let source: [DockPill] = {
                if shouldUsePureGlobalAppSearch || isActiveGlobalRunningAppMenuScope() {
                    let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    return visibleGlobalGroupedListNavigationState(for: q).menuPills
                }
                // Same clustered order the list renders AND the keyboard walks.
                let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return renderedOrderDockPills(for: q)
            }()
            let sourceIndex: Int = {
                if shouldUsePureGlobalAppSearch || isActiveGlobalRunningAppMenuScope() {
                    let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let state = visibleGlobalGroupedListNavigationState(for: q)
                    return idx - state.appResults.count
                }
                return idx
            }()
            guard sourceIndex >= 0, sourceIndex < source.count else { return nil }
            return source[sourceIndex].id
        }
        let isKeyboardFocused = keyboardFocusedPillID == pill.id || isDefaultFirstRow
        let isHov = listViewHoveredIndex == index
        let isActive = isKeyboardFocused || isHov
        let isDisabled = !pill.isEnabled && !isStaleAvailabilityMenuPill(pill)
        let interactiveCommand = interactiveSystemCommand(for: pill)
        let subtitle =
            (pill.menuContext?.isEmpty == false) ? pill.menuContext! : (pill.badge ?? "Run")
        let shortcutLabel = pill.keyboardShortcutLabel?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let sourceIcon =
            pill.rankingKind == "clipboard" ? sourceAppIcon(bundleId: pill.sourceBundleId) : nil

        Button {
            guard !isDisabled else { return }
            let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            listViewHoveredIndex = nil
            executeDockPill(pill)
            searchState.query = ""
            // Teach intent: user picked a menu action for this query
            if !q.isEmpty { AppUsageLearner.shared.recordQueryIntent(query: q, wasMenu: true) }
        } label: {
            if let left = pill.compareLeft ?? pill.compareRight, pill.compareRight != nil {
                compareRowBody(pill: pill, left: left, accent: accent)
            } else {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    if let img = pill.menuItemImage {
                        FileThumbnailImage(
                            filePath: pill.quickLookURL?.path ?? pill.resolvedURL?.path,
                            fallbackImage: img,
                            systemName: pill.icon,
                            tint: accent,
                            size: 28,
                            cornerRadius: 5,
                            isApplication: pill.rankingKind == "appLaunch"
                        )
                        .opacity(isDisabled ? 0.35 : 1.0)
                    } else {
                        FileThumbnailImage(
                            filePath: pill.quickLookURL?.path ?? pill.resolvedURL?.path,
                            fallbackImage: nil,
                            systemName: pill.icon,
                            tint: isDisabled
                                ? accent.opacity(0.30)
                                : (isActive ? accent : accent.opacity(0.80)),
                            size: 28,
                            cornerRadius: 5,
                            isApplication: false
                        )
                    }
                }
                .frame(width: 34, height: 34)

                // Name + context
                VStack(alignment: .leading, spacing: 2) {
                    Text(pill.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isDisabled ? .tertiary : .primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let sourceIcon {
                            Image(nsImage: sourceIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 18)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if isDisabled {
                            Text("Unavailable")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else if let status = pill.menuStatusBadge,
                            pill.rankingKind == "menu" || pill.rankingKind == "submenuParent"
                        {
                            Text(status)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }

                Spacer(minLength: 0)

                // Source app + return badge
                HStack(spacing: 5) {
                    if let shortcutLabel, !shortcutLabel.isEmpty,
                        pill.rankingKind == "menu" || pill.rankingKind == "submenuParent"
                            || pill.rankingKind == "submenuChild"
                    {
                        Text(shortcutLabel)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(isActive ? 0.72 : 0.54))
                            .padding(.horizontal, isActive ? 6 : 0)
                            .padding(.vertical, isActive ? 3 : 0)
                            .background(Color.secondary.opacity(isActive ? 0.08 : 0.0))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    if isActive, interactiveCommand == nil {
                        if !pill.sourceAppName.isEmpty {
                            Text(pill.sourceAppName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary.opacity(0.55))
                                .lineLimit(1)
                        }
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.45))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.09))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .frame(height: 52)
            .padding(.horizontal, 10)
            .background {
                dockCapsuleSelectionBackground(
                    isKeyboardFocused: isKeyboardFocused,
                    isHovered: isHov
                )
            }
            .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        // Live control sits above the button so the slider/toggle receives
        // mouse events instead of triggering the row action.
        .overlay(alignment: .trailing) {
            if let interactiveCommand {
                SystemCommandAccessoryView(command: interactiveCommand)
                    .padding(.trailing, 16)
            }
        }
        .modifier(OptionalDragProviderModifier(provider: pill.dragProvider))
        .opacity(isDisabled ? 0.45 : 1.0)
        .onHover { hovering in
            guard acceptsMouseDrivenDockInteraction else { return }
            listViewHoveredIndex = hovering ? index : nil
            if hovering { l2.pillNavViaKeyboard = false }
        }
    }

    /// Resolves the SystemCommand behind a pill when it should render a live
    /// control (slider/toggle) instead of plain run-on-enter behavior.
    func interactiveSystemCommand(for pill: DockPill) -> SystemCommand? {
        guard pill.rankingKind == "systemCommand" else { return nil }
        let parts = pill.trackingIdentifier.split(separator: ":")
        guard parts.count >= 3, parts[0] == "system", parts.last == "interactive",
            let id = UUID(uuidString: String(parts[1])),
            let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == id }),
            command.isEnabled,
            command.interactionType != .none
        else { return nil }
        return command
    }

    /// Resolves the interactive SystemCommand behind a global search result so its
    /// live control (Bluetooth/Wi-Fi toggle, Volume slider) can render inline in the
    /// results sheet instead of requiring the user to scope in.
    func interactiveSystemCommand(forResult result: SearchResult) -> SystemCommand? {
        guard result.subtitle.hasPrefix("syscmd://"),
            let id = UUID(uuidString: String(result.subtitle.dropFirst("syscmd://".count))),
            let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == id }),
            command.isEnabled,
            command.interactionType != .none
        else { return nil }
        return command
    }

    @ViewBuilder
    func groupedMenuPillRow(group: MenuPillGroup, index: Int) -> some View {
        let primary = group.primaryPill
        let accent = accentColor(for: primary.accentColorName)
        let keyboardFocusedPillID: String? = l2.focusedPillIndex.flatMap { idx in
            if shouldUsePureGlobalAppSearch || isActiveGlobalRunningAppMenuScope() {
                let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let state = visibleGlobalGroupedListNavigationState(for: q)
                let menuIndex = idx - state.appResults.count
                guard menuIndex >= 0, menuIndex < state.menuPills.count else { return nil }
                return state.menuPills[menuIndex].id
            }
            return nil
        }
        let isKeyboardFocused = l2.focusedPillIndex == index || keyboardFocusedPillID == primary.id
        let isHov = listViewHoveredIndex == index
        let isActive = isKeyboardFocused || isHov
        let subtitle =
            (primary.menuContext?.isEmpty == false) ? primary.menuContext! : (primary.badge ?? "")

        HStack(spacing: 10) {
            // Icon
            ZStack {
                if let img = primary.menuItemImage {
                    FileThumbnailImage(
                        filePath: primary.quickLookURL?.path ?? primary.resolvedURL?.path,
                        fallbackImage: img,
                        systemName: primary.icon,
                        tint: accent,
                        size: 28,
                        cornerRadius: 5,
                        isApplication: false
                    )
                } else {
                    FileThumbnailImage(
                        filePath: primary.quickLookURL?.path ?? primary.resolvedURL?.path,
                        fallbackImage: nil,
                        systemName: primary.icon,
                        tint: isActive ? accent : accent.opacity(0.80),
                        size: 28,
                        cornerRadius: 5,
                        isApplication: false
                    )
                }
            }
            .frame(width: 34, height: 34)

            // Action name + parent menu
            VStack(alignment: .leading, spacing: 2) {
                Text(primary.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // App chips — one per source app, tappable
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(group.allPills) { pill in
                        Button {
                            let q = searchState.query.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).lowercased()
                            l2.focusedPillIndex = nil
                            l2.pillNavViaKeyboard = false
                            listViewHoveredIndex = nil
                            executeDockPill(pill)
                            searchState.query = ""
                            if !q.isEmpty {
                                AppUsageLearner.shared.recordQueryIntent(query: q, wasMenu: true)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if !pill.sourceBundleId.isEmpty,
                                    let appURL = NSWorkspace.shared.urlForApplication(
                                        withBundleIdentifier: pill.sourceBundleId)
                                {
                                    let appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
                                    Image(nsImage: appIcon)
                                        .resizable().aspectRatio(contentMode: .fit)
                                        .frame(width: 20, height: 20)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                Text(pill.sourceAppName.isEmpty ? pill.name : pill.sourceAppName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .lineLimit(1)
                                if let sc = pill.badge, !sc.isEmpty {
                                    Text(sc)
                                        .font(.system(size: 10, weight: .light))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(isActive ? 0.12 : 0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 260)
        }
        .frame(height: 52)
        .padding(.horizontal, 10)
        .background {
            dockCapsuleSelectionBackground(
                isKeyboardFocused: isKeyboardFocused,
                isHovered: isHov
            )
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard acceptsMouseDrivenDockInteraction else { return }
            listViewHoveredIndex = hovering ? index : nil
            if hovering { l2.pillNavViaKeyboard = false }
        }
        .onTapGesture {
            // Tap on the row (not a chip) executes the primary pill
            let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            l2.focusedPillIndex = nil
            l2.pillNavViaKeyboard = false
            listViewHoveredIndex = nil
            executeDockPill(primary)
            searchState.query = ""
            if !q.isEmpty { AppUsageLearner.shared.recordQueryIntent(query: q, wasMenu: true) }
        }
    }

    @ViewBuilder
    var pinnedAppsListView: some View {
        EmptyView()
        .frame(maxHeight: 320)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.16), .white.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.34), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.24), radius: 24, x: 0, y: 10)
        .transition(.opacity)
    }

    /// True when the Global Context app-result list is showing its Spotlight-style
    /// default-first row (apps present above any menu rows, nothing explicitly
    /// focused). The menu rows must defer their own default-first to avoid two focus
    /// rings showing at once.
    var globalAppListOwnsDefaultFirstSelection: Bool {
        guard isGlobalContextActive,
            focusedAppPillIndex == nil,
            hoveredAppPillIndex == nil
        else { return false }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        return !currentOrImmediateGlobalAppMatches(for: q).isEmpty
    }

    @ViewBuilder
    func appListRow(
        icon: NSImage?,
        name: String,
        subtitle: String,
        index: Int,
        isCommandIcon: Bool = false,
        defaultsToFirstSelection: Bool = false,
        interactiveCommand: SystemCommand? = nil,
        quitAction: (() -> Void)? = nil,
        quitPhase: DockInlineFeedback.Phase? = nil,
        previewApp: NSRunningApplication? = nil,
        action: @escaping () -> Void
    ) -> some View {
        // Spotlight-style default selection: in a typed-query RESULT list, the first row reads as
        // selected with nothing explicitly focused/hovered so the list never looks "unfocused".
        // Purely a render default — focusedAppPillIndex stays nil (no input collapse / pill-nav
        // side effects), and Enter already runs the top result via the input-ghost preview.
        // Gated to result lists only (not the dock's pinned-apps list) and only while typing.
        let isDefaultFirstRow =
            defaultsToFirstSelection
            && index == 0
            && focusedAppPillIndex == nil
            && hoveredAppPillIndex == nil
            // A menu row is explicitly focused → don't ALSO default-ring the first app
            // (that's the second focus ring).
            && l2.focusedPillIndex == nil
            && listViewHoveredIndex == nil
            && !searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isKeyboardFocused = focusedAppPillIndex == index || isDefaultFirstRow
        let isHov = hoveredAppPillIndex == index
        let isActive = isKeyboardFocused || isHov

        Button(action: action) {
            HStack(spacing: 10) {
                // App icon
                Group {
                    if let img = icon {
                        if isCommandIcon {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(isActive ? 0.12 : 0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                                    )
                                Image(nsImage: img)
                                    .resizable()
                                    .renderingMode(.template)
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .foregroundStyle(.primary.opacity(isActive ? 0.95 : 0.82))
                                    .frame(width: 24, height: 24)
                            }
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 42, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 42, height: 42)
                    }
                }
                .frame(width: 48, height: 48)
                .scaleEffect(isActive ? 1.02 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isActive)

                // Name + subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // An inline live control (Bluetooth/Wi-Fi toggle, Volume slider) owns
                // the trailing edge — reserve room for the overlay and drop the ⏎ chip.
                // A slider needs far more width than a toggle switch.
                if let interactiveCommand {
                    Color.clear.frame(
                        width: interactiveCommand.interactionType == .slider ? 200 : 52,
                        height: 1
                    )
                } else if isActive {
                    HStack(spacing: 6) {
                        if let quitAction {
                            Button(role: .destructive) {
                                quitAction()
                            } label: {
                                let quitTint: SwiftUI.Color = quitPhase == .success ? .green : .red
                                HStack(spacing: 5) {
                                    if quitPhase == .progress {
                                        ProgressView()
                                            .controlSize(.small)
                                            .scaleEffect(0.52)
                                            .frame(width: 13, height: 13)
                                    } else if quitPhase == .success {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                    } else {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    Text("Quit")
                                        .font(.system(size: 11, weight: .semibold))
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(quitTint.opacity(0.92))
                                .padding(.leading, 7)
                                .padding(.trailing, 6)
                                .padding(.vertical, 4)
                                .background {
                                    Capsule(style: .continuous)
                                        .fill(quitTint.opacity(0.16))
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(quitTint.opacity(0.34), lineWidth: 0.7)
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.45))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.09))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .frame(height: 52)
            .padding(.horizontal, 10)
            .background {
                dockCapsuleSelectionBackground(
                    isKeyboardFocused: isKeyboardFocused,
                    isHovered: isHov
                )
                .animation(.easeOut(duration: 0.10), value: isKeyboardFocused)
                .animation(.easeOut(duration: 0.10), value: isHov)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Live control sits above the button so the toggle/slider receives the
        // mouse event instead of triggering the row action (which would scope).
        .overlay(alignment: .trailing) {
            if let interactiveCommand {
                SystemCommandAccessoryView(command: interactiveCommand)
                    .padding(.trailing, 16)
            }
        }
        .onHover { hovering in
            guard acceptsMouseDrivenDockInteraction else { return }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.75)) {
                hoveredAppPillIndex = hovering ? index : nil
            }
        }
    }

    var isExplicitAppScope: Bool {
        resolveDockScope(
            for: searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ).isExplicitAppScope
    }

    /// The exact pill order the List View renders (clustered by group). Keyboard
    /// navigation MUST walk this order — navigating the raw score-interleaved array
    /// while the list renders a re-clustered copy makes ↑/↓ jump between sections.
    /// Horizontal pill row renders the raw order, so it returns the raw list there.
    func renderedOrderDockPills(for query: String) -> [DockPill] {
        let cached = contextDockViewModel.visiblePills
        let base = cached.isEmpty ? currentVisibleDockPills(for: query) : cached
        guard usesVerticalListDockLayout else { return base }
        return clusterPillsByGroup(Array(base.prefix(maxListViewDockPills)))
    }

    var shouldShowL2UnifiedDockRow: Bool {
        guard showContextInDock, !aiMode.isActive else { return false }
        if isContextDockChatRoutingLocked { return false }
        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isCompactSmartScope {
            return false
        }
        if isGlobalContextActive {
            let hasExtensionScope =
                currentGlobalScopedBundleID?.hasPrefix("syscmd://") == true
                || currentGlobalScopedBundleID?.hasPrefix("cli://") == true
            if q.isEmpty, !hasExtensionScope {
                return false
            }
            if shouldUsePureGlobalAppSearch {
                return true
            }
            if currentGlobalScopedBundleID != nil {
                if pendingDockPillQuery == q || isResolvingDockPills(for: q) {
                    return true
                }
                return stableVisibleDockPills(for: q).contains { !$0.isSeparator }
            }
            let visiblePills = currentVisibleDockPills(for: q)
            if pendingDockPillQuery == q || isResolvingDockPills(for: q) {
                return true
            }
            return visiblePills.contains { !$0.isSeparator }
        }
        if hasSelectionScopeSurface {
            return true
        }
        guard !q.isEmpty else { return false }
        // Finder desktop search must keep its shared sheet alive while its cache and
        // Spotlight passes exchange snapshots. The rendered list supplies either files,
        // setup guidance, or a no-results row, so an empty intermediate array is not a
        // reason to hide the surface.
        if isFinderDesktopOnlyMode { return true }
        if !isGlobalContextActive {
            // Keep the row while the debounced pill build is in flight (no flicker), but
            // once the query resolves to ZERO results collapse back to the compact input
            // capsule — never park an empty results container under the search bar.
            if pendingDockPillQuery == q || isResolvingDockPills(for: q) {
                return true
            }
            if pendingDockPreviewPills.contains(where: { !$0.isSeparator }) {
                return true
            }
            return currentVisibleDockPills(for: q).contains { !$0.isSeparator }
        }
        if pendingDockPillQuery == q, pendingDockPreviewPills.contains(where: { !$0.isSeparator }) {
            return true
        }
        let visiblePills = contextDockViewModel.visiblePills
        return visiblePills.contains { !$0.isSeparator }
    }

    /// Single pill button with focus highlight for keyboard navigation.
    @ViewBuilder
    func unifiedPillButton(
        pill: DockPill, index: Int, isExpanded: Bool = false, isCompact: Bool = false
    ) -> some View {
        if pill.isSeparator {
            // Render as a thin vertical divider with optional app-name label
            HStack(spacing: 3) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1, height: 16)
                if !pill.name.isEmpty {
                    Text(pill.name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        } else {
            let accent = accentColor(for: pill.accentColorName)
            let focused = l2.focusedPillIndex == index
            let iconSize: CGFloat = isExpanded ? 24 : (isCompact ? 10 : 14)
            let textSize: CGFloat = isExpanded ? 14 : (isCompact ? 10 : 12)
            let hPad: CGFloat = isExpanded ? 12 : (isCompact ? 8 : 12)
            let vPad: CGFloat = isExpanded ? 0 : (isCompact ? 4 : 7)
            Button {
                executeDockPill(pill)
                searchState.query = ""
                l2.focusedPillIndex = nil
            } label: {
                HStack(spacing: isExpanded ? 0 : (isCompact ? 4 : 6)) {
                    if let img = pill.menuItemImage {
                        FileThumbnailImage(
                            filePath: pill.quickLookURL?.path ?? pill.resolvedURL?.path,
                            fallbackImage: img,
                            systemName: pill.icon,
                            tint: accent,
                            size: iconSize,
                            cornerRadius: isExpanded ? 5 : 3,
                            isApplication: false
                        )
                        .opacity(focused ? 1.0 : 0.88)
                    } else {
                        FileThumbnailImage(
                            filePath: pill.quickLookURL?.path ?? pill.resolvedURL?.path,
                            fallbackImage: nil,
                            systemName: pill.icon,
                            tint: focused ? accent : accent.opacity(0.88),
                            size: isExpanded ? iconSize : (isCompact ? 10 : 14),
                            cornerRadius: isExpanded ? 5 : 3,
                            isApplication: false
                        )
                    }
                    if isExpanded {
                        Rectangle()
                            .fill(Color.white.opacity(0.16))
                            .frame(width: 1, height: 28)
                            .padding(.horizontal, 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pill.name)
                                .font(.system(size: textSize, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            if let ctx = pill.menuContext {
                                Text(ctx)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary.opacity(0.65))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.55))
                    } else {
                        Text(pill.name)
                            .font(.system(size: textSize, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(focused ? 1.0 : 0.88))
                            .lineLimit(1)
                        // Badge (shortcut): only in normal scroll row
                        if let badge = pill.badge, l2.focusedPillIndex == nil {
                            Text(badge)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: isExpanded ? .infinity : nil)
                .frame(height: isExpanded ? 44 : nil)
                .padding(.horizontal, hPad).padding(.vertical, vPad)
                // Match context dock input field: ultraThinMaterial + white gradient border
                .background {
                    if focused {
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                    startPoint: .top, endPoint: .bottom)
                            )
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.65), .white.opacity(0.06)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1.5)
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                                .blur(radius: 3)
                        }
                    } else {
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.14), .white.opacity(0.02)],
                                    startPoint: .top, endPoint: .bottom)
                            )
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.32), .white.opacity(0.06)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 0.75)
                        }
                    }
                }
                .shadow(
                    color: focused ? .white.opacity(0.22) : .clear,
                    radius: focused ? 10 : 0, y: focused ? -1 : 0
                )
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: focused)
            }
            .buttonStyle(.plain)
            .help(pill.name)
            .onHover { hovering in
                guard acceptsMouseDrivenDockInteraction else { return }
                if !l2.pillNavViaKeyboard {
                    l2.focusedPillIndex = hovering ? index : nil
                    if hovering {
                        refreshQuickLookPreviewForCurrentFocusIfVisible()
                    }
                }
                hoveredDockPillIndex = hovering ? index : nil
            }
            // Right-click context menu — shows Favourite / Unfavourite for menu item pills
            .contextMenu {
                if !pill.menuItemName.isEmpty, !pill.sourceBundleId.isEmpty {
                    Button {
                        settings.toggleFavouriteMenuPill(
                            pill.menuItemName, for: pill.sourceBundleId)
                    } label: {
                        Label(
                            pill.isFavourited ? "Remove from Favourites" : "Add to Favourites",
                            systemImage: pill.isFavourited ? "star.slash" : "star"
                        )
                    }
                }
            }
        }  // end else (non-separator)
    }

    /// Resolve an optional color name string into a SwiftUI Color.
    func accentColor(for name: String?) -> SwiftUI.Color {
        switch name?.lowercased() {
        case "blue": return .blue
        case "red": return .red
        case "green": return .green
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "indigo": return .indigo
        case "teal": return .teal
        case "pink": return .pink
        case "gray", "grey": return .secondary
        default: return Color.accentColor
        }
    }

    /// Best-effort icon for a menu item. AXImage covers most items; Services items need name lookup.
    func resolvedMenuIcon(for item: AXMenuItem) -> NSImage? {
        if let appIcon = resolvedApplicationMenuIcon(for: item) { return appIcon }
        if let shareIcon = resolvedShareMenuIcon(for: item) { return shareIcon }
        if let img = item.image { return img }
        let isService = item.path.contains(where: { $0 == "Services" })
        guard isService else { return nil }
        let cacheKey = item.path.joined(separator: " > ")
        return MenuIconMemoryCache.shared.image(for: cacheKey) {
            resolveUncachedServiceMenuIcon(for: item)
        }
    }

    func resolvedApplicationMenuIcon(for item: AXMenuItem) -> NSImage? {
        let normalizedPath = item.path.map(normalizedDockPillText)
        // Match "Open With" AND Safari's "Open Page With" (any "open … with" parent),
        // plus any row whose own title ends in ".app" — so every app row in those
        // dynamic menus shows its real app icon, not a generic doc icon.
        let isOpenWithContext =
            normalizedPath.contains { $0.contains("open") && $0.contains("with") }
            || normalizedDockPillText(item.title).hasSuffix(".app")
            || item.title.contains(".app")
        guard isOpenWithContext else { return nil }
        // Open With titles arrive decorated: "Music.app (default)", "IINA.app",
        // "Books.app". Strip the trailing "(default)"/parenthetical and the ".app"
        // suffix so the name resolves to a real app icon (not a generic doc icon).
        let rawTitle = item.title
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(
                of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return nil }
        let appName =
            rawTitle.hasSuffix(".app")
            ? String(rawTitle.dropLast(4)) : rawTitle
        return MenuIconMemoryCache.shared.image(for: "open-with:\(appName)", cacheMisses: false) {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                ($0.localizedName ?? "").caseInsensitiveCompare(appName) == .orderedSame
                    && !$0.isTerminated
            }) {
                // Prefer the static bundle icon over NSRunningApplication.icon —
                // some apps (DuckDuckGo) set a generic runtime icon that isn't the
                // real app icon.
                if let bundleURL = app.bundleURL {
                    return preparedDockIcon(NSWorkspace.shared.icon(forFile: bundleURL.path))
                }
                return preparedDockIcon(app.icon)
            }
            for dir in [
                "/Applications", "/System/Applications",
                "/System/Applications/Utilities", "\(NSHomeDirectory())/Applications",
            ] {
                let path = "\(dir)/\(appName).app"
                if FileManager.default.fileExists(atPath: path) {
                    return preparedDockIcon(NSWorkspace.shared.icon(forFile: path))
                }
            }
            // Last resort: let LaunchServices find it anywhere by display name.
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: appName)
            {
                return preparedDockIcon(NSWorkspace.shared.icon(forFile: url.path))
            }
            return nil
        }
    }

    func resolvedShareMenuIcon(for item: AXMenuItem) -> NSImage? {
        let normalizedPath = item.path.map(normalizedDockPillText)
        guard normalizedPath.contains("share") else { return nil }
        return shareDestinationIcon(forTitle: item.title)
    }

    /// Resolve a share-destination icon purely from its title (Notes, Mail, AirDrop,
    /// app extensions). Use when the caller already KNOWS the row is a share child —
    /// the AX path of a flattened submenu child often drops the "Share" segment, so
    /// the path-guarded `resolvedShareMenuIcon` would miss it.
    func shareDestinationIcon(forTitle title: String) -> NSImage? {
        let rawTitle = title
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return nil }

        return MenuIconMemoryCache.shared.image(for: "share:\(rawTitle)", cacheMisses: false) {
            // Cheap, deterministic lookups first (installed-app catalog + aliases) so
            // the common destinations resolve fast and cache as a hit. The expensive
            // NSSharingService enumeration is the last resort for unknown extensions.
            let normalizedTitle = normalizedDockPillText(rawTitle)
            let aliases: [(String, String)] = [
                ("add to photos", "Photos"),
                ("photos", "Photos"),
                ("mail", "Mail"),
                ("messages", "Messages"),
                ("notes", "Notes"),
                ("reminders", "Reminders"),
                ("freeform", "Freeform"),
                ("maps", "Maps"),
                ("shortcuts", "Shortcuts"),
            ]
            if let alias = aliases.first(where: { normalizedTitle.contains($0.0) }),
                let icon = resolvedInstalledAppIcon(named: alias.1)
            {
                return icon
            }
            if normalizedTitle.contains("airdrop") {
                return NSImage(
                    systemSymbolName: "antenna.radiowaves.left.and.right",
                    accessibilityDescription: "AirDrop")
            }
            // The real NSSharingService image is the exact icon the native menu shows
            // (QR code, Downie, Bridges, share-extensions). Use it BEFORE the loose
            // installed-app lookup, which falsely matched "Create QR Code" → "Code".
            if let serviceIcon = resolvedSharingServiceIcon(named: rawTitle) {
                return serviceIcon
            }
            // SF-symbol fallbacks for service-only destinations with no app/icon.
            let symbolFallbacks: [(String, String)] = [
                ("qr code", "qrcode"),
                ("copy link", "link"),
                ("copy", "doc.on.doc"),
                ("reading list", "eyeglasses"),
            ]
            if let s = symbolFallbacks.first(where: { normalizedTitle.contains($0.0) }),
                let img = NSImage(systemSymbolName: s.1, accessibilityDescription: nil)
            {
                return img
            }
            if let direct = resolvedInstalledAppIcon(named: rawTitle) {
                return direct
            }
            return nil
        }
    }

    func resolvedSharingServiceIcon(named title: String) -> NSImage? {
        let context = effectiveShareAXContext()
        var items = ShareIntentRouter.shared.shareItems(for: context)
        if items.isEmpty, let app = AppDelegate.shared?.previousFrontmostApp,
            let bid = app.bundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        {
            items = [url]
        }
        guard !items.isEmpty else { return nil }

        let normalizedTitle = normalizedShareDestinationText(title)
        guard !normalizedTitle.isEmpty else { return nil }
        let services = NSSharingService.sharingServices(forItems: items)
        let match = services.first { service in
            let serviceTitle = normalizedShareDestinationText(service.title)
            return serviceTitle == normalizedTitle
                || serviceTitle.contains(normalizedTitle)
                || normalizedTitle.contains(serviceTitle)
        }
        return match?.image
    }

    func resolvedInstalledAppIcon(named appName: String) -> NSImage? {
        let cleaned = cleanShareDestinationAppName(appName)
        guard !cleaned.isEmpty else { return nil }
        let normalizedCleaned = normalizedDockPillText(cleaned)

        if let match = allApplications.first(where: {
            let title = normalizedDockPillText($0.title)
            return title == normalizedCleaned
                || title.contains(normalizedCleaned)
                || normalizedCleaned.contains(title)
        }), let path = match.filePath {
            return preparedDockIcon(NSWorkspace.shared.icon(forFile: path))
        }

        let rawBundleName =
            appName
            .replacingOccurrences(of: ".app", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").caseInsensitiveCompare(cleaned) == .orderedSame
                && !$0.isTerminated
        }) {
            return preparedDockIcon(app.icon)
        }

        if let match = allApplications.first(where: {
            normalizedDockPillText($0.title) == normalizedDockPillText(cleaned)
        }), let path = match.filePath {
            return preparedDockIcon(NSWorkspace.shared.icon(forFile: path))
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cleaned) {
            return preparedDockIcon(NSWorkspace.shared.icon(forFile: url.path))
        }

        let candidates = [
            "/Applications/\(cleaned).app",
            "/Applications/\(rawBundleName).app",
            "/System/Applications/\(cleaned).app",
            "/System/Applications/\(rawBundleName).app",
            "/System/Applications/Utilities/\(cleaned).app",
            "/System/Applications/Utilities/\(rawBundleName).app",
            "\(NSHomeDirectory())/Applications/\(cleaned).app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return preparedDockIcon(NSWorkspace.shared.icon(forFile: path))
        }

        if let discovered = InstalledApplicationsCatalog.discoverInstalledApps().first(where: {
            let name = normalizedDockPillText($0.name)
            return name == normalizedCleaned
                || name.contains(normalizedCleaned)
                || normalizedCleaned.contains(name)
        }) {
            return preparedDockIcon(
                discovered.icon ?? NSWorkspace.shared.icon(forFile: discovered.url.path))
        }
        return nil
    }

    func cleanShareDestinationAppName(_ value: String) -> String {
        value
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(
                of: "\\b(share|sharing|extension|service)\\b", with: "", options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func normalizedShareDestinationText(_ value: String) -> String {
        cleanShareDestinationAppName(value)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolveUncachedServiceMenuIcon(for item: AXMenuItem) -> NSImage? {
        let name = item.title.lowercased()
        // 1. Running app whose display name matches
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased() == name && !($0.isTerminated)
        }) {
            return app.icon
        }
        // 2. Walk common app directories
        let dirs = ["/Applications", "/System/Applications", "\(NSHomeDirectory())/Applications"]
        for dir in dirs {
            let appPath = "\(dir)/\(item.title).app"
            if FileManager.default.fileExists(atPath: appPath) {
                return NSWorkspace.shared.icon(forFile: appPath)
            }
        }
        // 3. Workflow bundle in ~/Library/Services (Automator quick actions)
        let workflowPath = "\(NSHomeDirectory())/Library/Services/\(item.title).workflow"
        if FileManager.default.fileExists(atPath: workflowPath) {
            return NSWorkspace.shared.icon(forFile: workflowPath)
        }
        // 4. Shortcuts-provided service. The public Shortcuts CLI does not expose
        // the user's exact glyph/color, so use a deterministic per-shortcut symbol
        // instead of making every service look like Shortcuts.app.
        if let icon = NSImage(
            systemSymbolName: ShortcutsCatalog.iconName(for: item.title),
            accessibilityDescription: item.title
        ) {
            return icon
        }
        return nil
    }

    func menuSymbol(for item: AXMenuItem) -> String {
        if item.sourceAppName == "System Settings" || frontmost.bundleID == "com.apple.systempreferences" {
            return SFSymbolResolver.systemSettingsPaneSymbol(title: item.title)
        }
        if item.path.contains(where: { $0 == "Services" }) {
            return ShortcutsCatalog.iconName(for: item.title)
        }
        return SFSymbolResolver.menuSymbol(
            title: item.title,
            path: item.path,
            isAppleMenu: item.isAppleMenu
        )
    }

    func resolvedBundleId(for pid: pid_t, fallbackBundleId: String) -> String {
        if pid != 0,
            let bundleId = NSWorkspace.shared.runningApplications.first(
                where: { $0.processIdentifier == pid && !$0.isTerminated }
            )?.bundleIdentifier,
            !bundleId.isEmpty
        {
            return bundleId
        }
        return fallbackBundleId
    }

    /// Smart pills generated from the live AX context snapshot.
    /// These complement user-configured pills with zero-config, always-relevant actions.
    @ViewBuilder
    var axSmartPills: some View {
        let ax = axContext
        if !ax.isEmpty {
            // Separator before smart pills
            Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1, height: 20)

            // Copy URL — shown when a browser URL is detected
            if let url = ax.currentURL {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "link").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.teal)
                        Text("Copy URL").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.teal.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain).help(url)
                .transition(.scale(scale: 0.8).combined(with: .opacity))

                // Ask About Page — send URL to AI
                Button {
                    guard !isExplicitAppScopeLocked else { return }
                    let prompt = "What is this page about? URL: \(url)"
                    searchState.query = prompt
                    aiMode.isActive = true
                    showContextInDock = false
                    submitAIQuery()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.indigo)
                        Text("Ask About Page").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.indigo.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain).help("Ask AI about this page")
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            // Copy Selection — shown when text is selected in the frontmost app
            if let sel = ax.selectedText, !sel.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sel, forType: .string)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "text.cursor").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("Copy Selection").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.orange.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain).help(sel.count > 60 ? String(sel.prefix(60)) + "…" : sel)
                .transition(.scale(scale: 0.8).combined(with: .opacity))

                // Ask About Selection
                Button {
                    guard !isExplicitAppScopeLocked else { return }
                    let text = sel.count > 500 ? String(sel.prefix(500)) : sel
                    searchState.query = "Explain: \(text)"
                    aiMode.isActive = true
                    showContextInDock = false
                    submitAIQuery()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.indigo)
                        Text("Ask About Selection").font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.indigo.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }

    // MARK: - App Shortcuts Dock Row — shown when a smart query (calendar/notes…) or folder is active
    @ViewBuilder
    var appShortcutsInDock: some View {
        let key = searchState.activeSmartQueryKey ?? folderSmartKey
        // contextPanelActions() already includes user shortcuts when searchState.contextApp != nil,
        // so only pull shortcuts directly for built-in key panels (no searchState.contextApp)
        let contextActions = contextPanelActions()
        let hasSearchCtx = searchState.contextApp != nil
        let extraShortcuts: [AppShortcut] =
            hasSearchCtx
            ? []
            : {
                // Merge quick-actions and context-dock shortcuts, deduplicated by name
                var seen = Set<String>()
                let quick = settings.shortcuts(for: key)
                let dock = settings.contextDockShortcuts(for: key)
                for s in quick { seen.insert(s.name) }
                return quick + dock.filter { seen.insert($0.name).inserted }
            }()

        // Context: is there a selected file or text right now?
        let hasFileSelection: Bool =
            folderPreviewSelectedFile != nil
            || (searchState.selectedIndex.map {
                $0 < searchState.results.count && searchState.results[$0].filePath != nil
            } ?? false)
            || !axContext.selectedFilePaths.isEmpty
            || {
                switch currentContext {
                case .filesSelected(let urls): return !urls.isEmpty
                default: return false
                }
            }()
        let hasTextSelection: Bool =
            !(axContext.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ?? true)
            || {
                switch currentContext {
                case .textSelected(let text):
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                default:
                    return false
                }
            }()

        // Filter context-sensitive shortcuts: hide shell/$1 actions when nothing is selected
        let visibleShortcuts = extraShortcuts.filter { sc in
            guard sc.actionType == .shellCommand || sc.actionType == .appleScript else {
                return true
            }
            let v = sc.actionValue
            let needsFile =
                v.contains("$1") || v.contains("$2") || v.contains("$SELECTED_FILES")
                || v.contains("$SELECTED_FILE")
            let needsText = v.contains("$SELECTED_TEXT")
            if needsFile && !hasFileSelection { return false }
            if needsText && !hasTextSelection { return false }
            return true
        }

        let showHint = contextActions.isEmpty && visibleShortcuts.isEmpty

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(contextActions) { action in
                    dockPillButton(icon: action.icon, label: action.label, action: action.action)
                }
                ForEach(visibleShortcuts) { sc in
                    dockPillButton(icon: sc.iconName, label: sc.name) { executeAppShortcut(sc) }
                }
                if showHint {
                    Text("No quick actions — add some in Settings › App Shortcuts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    /// Floating pill-shaped dock button used for all quick actions.
    @ViewBuilder
    func dockPillButton(icon: String, label: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// Key used when a folder is open but no app smart query is active
    var folderSmartKey: String {
        if let path = folderPreviewPath {
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if name == "downloads" { return "downloads" }
        }
        return ""
    }

    func executeAppShortcut(_ sc: AppShortcut) {
        // ── Gather context ───────────────────────────────────────────────
        // Selected file(s): folder preview selection first, then highlighted search result
        var selectedFilePaths: [String] = []
        if let previewFile = folderPreviewSelectedFile, !previewFile.isEmpty {
            selectedFilePaths = [previewFile]
        } else if let idx = searchState.selectedIndex, idx < searchState.results.count,
            let path = searchState.results[idx].filePath, !path.isEmpty
        {
            selectedFilePaths = [path]
        }
        // Also pick up any multi-selection from Finder if no in-app selection
        if selectedFilePaths.isEmpty {
            selectedFilePaths = ContextDetector.shared.getFinderSelectedFiles().map { $0.path }
        }

        // Use the app that was frontmost BEFORE ILauncher activated — never ILauncher itself.
        let prevApp = AppDelegate.shared?.previousFrontmostApp

        // Selected text: accessibility API on the pre-ILauncher frontmost app
        let selectedText: String = {
            guard let app = prevApp else { return "" }
            return ContextDetector.shared.getSelectedText(from: app) ?? ""
        }()

        // ── Substitution helper ──────────────────────────────────────────
        func inject(_ value: String) -> String {
            var result = value
            // $1..$N — individual file paths
            for (i, path) in selectedFilePaths.enumerated() {
                let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                result = result.replacingOccurrences(of: "$\(i + 1)", with: escaped)
            }
            // $SELECTED_FILES — space-separated list of all paths (shell-quoted)
            let allEscaped = selectedFilePaths.map {
                "'\($0.replacingOccurrences(of: "'", with: "\\'"))'"
            }.joined(separator: " ")
            result = result.replacingOccurrences(of: "$SELECTED_FILES", with: allEscaped)
            // $SELECTED_TEXT — text selected in frontmost app
            let textEscaped = selectedText.replacingOccurrences(of: "'", with: "'\\''")
            result = result.replacingOccurrences(of: "$SELECTED_TEXT", with: textEscaped)
            // $FRONTMOST_APP — name of the app that was active before ILauncher opened
            let frontmostName = prevApp?.localizedName ?? ""
            result = result.replacingOccurrences(of: "$FRONTMOST_APP", with: frontmostName)
            // $FRONTMOST_BUNDLE — bundle identifier of the pre-ILauncher app
            let frontmostBundle = prevApp?.bundleIdentifier ?? ""
            result = result.replacingOccurrences(of: "$FRONTMOST_BUNDLE", with: frontmostBundle)
            // AX-read context variables ─────────────────────────────────────────
            // $CURRENT_URL — URL currently open in the frontmost browser/app window
            let axURL = axContext.currentURL ?? ""
            result = result.replacingOccurrences(of: "$CURRENT_URL", with: axURL)
            // $WINDOW_TITLE — title of the frontmost window
            let axTitle = axContext.windowTitle ?? ""
            result = result.replacingOccurrences(of: "$WINDOW_TITLE", with: axTitle)
            // $AX_SELECTED_TEXT — selected text read via AX API (more reliable than clipboard)
            let axSel = axContext.selectedText ?? ""
            result = result.replacingOccurrences(of: "$AX_SELECTED_TEXT", with: axSel)
            return result
        }

        switch sc.actionType {
        case .openURL:
            if let url = URL(string: inject(sc.actionValue)) { NSWorkspace.shared.open(url) }
        case .openFile:
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: sc.actionValue),
                configuration: NSWorkspace.OpenConfiguration())
        case .shellCommand:
            let cmd = inject(sc.actionValue)
            let ck = activeConsoleKey
            // Always create panel terminal if needed, open drawer, run command in real PTY
            let panelTerm = panelTerminal(for: ck)
            panelShowConsoleMap[ck] = true
            panelTerm.sendCommand(cmd)
            // Give the terminal focus so output is visible and interactive
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                panelTerm.terminalView.window?.makeFirstResponder(panelTerm.terminalView)
            }
        case .appleScript:
            if let script = NSAppleScript(source: inject(sc.actionValue)) {
                script.executeAndReturnError(nil)
            }
        case .jxa:
            // JXA runs via osascript -l JavaScript, passing selected file + text as argv
            let scriptCode = sc.actionValue
            let ck = activeConsoleKey
            let file1 = selectedFilePaths.first ?? ""
            let selText = selectedText
            Task.detached {
                // Write script to a temp file so we can pass it cleanly
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ilauncher_jxa_\(UUID().uuidString).js")
                try? scriptCode.write(to: tmp, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                var args = ["-l", "JavaScript", tmp.path]
                if !file1.isEmpty { args.append(file1) }
                if !selText.isEmpty { args.append(selText) }
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                try? proc.run()
                proc.waitUntilExit()
                let out =
                    String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    ?? ""
                // Show JXA output in the panel terminal drawer
                await MainActor.run {
                    self.panelShowConsoleMap[ck] = true
                    for line in out.components(separatedBy: "\n") where !line.isEmpty {
                        self.panelConsoleLinesMap[ck, default: []].append(
                            (line: line, isCommand: false))
                    }
                }
            }
        case .scriptFile:
            // Delegate to AXTriggerRuleEngine which handles all script file execution + notifications
            let envVars: [String: String] = [
                "CD_APP_NAME": frontmost.name,
                "CD_BUNDLE_ID": frontmost.bundleID,
                "CD_WINDOW_TITLE": axContext.windowTitle ?? "",
                "CD_SELECTED_TEXT": axContext.selectedText ?? selectedText,
                "CD_URL": axContext.currentURL ?? AXContextReader.shared.current.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url ?? "",
                "CD_FILE": axContext.selectedFilePaths.first ?? selectedFilePaths.first ?? "",
                "CD_CLIPBOARD": NSPasteboard.general.string(forType: .string) ?? "",
            ]
            AXTriggerRuleEngine.shared.run(
                type: .scriptFile, value: sc.actionValue, envVars: envVars)
        case .menuItem:
            let envVars: [String: String] = [
                "CD_APP_NAME": frontmost.name,
                "CD_BUNDLE_ID": frontmost.bundleID,
                "CD_WINDOW_TITLE": axContext.windowTitle ?? "",
                "CD_SELECTED_TEXT": axContext.selectedText ?? selectedText,
                "CD_URL": axContext.currentURL ?? AXContextReader.shared.current.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url ?? "",
                "CD_FILE": axContext.selectedFilePaths.first ?? selectedFilePaths.first ?? "",
                "CD_CLIPBOARD": NSPasteboard.general.string(forType: .string) ?? "",
            ]
            AXTriggerRuleEngine.shared.run(type: .menuItem, value: sc.actionValue, envVars: envVars)
        case .shortcut:
            let envVars: [String: String] = [
                "CD_APP_NAME": frontmost.name,
                "CD_BUNDLE_ID": frontmost.bundleID,
                "CD_WINDOW_TITLE": axContext.windowTitle ?? "",
                "CD_SELECTED_TEXT": axContext.selectedText ?? selectedText,
                "CD_URL": axContext.currentURL ?? AXContextReader.shared.current.currentURL ?? SafariBrowserBridge.shared.currentContext()?.url ?? "",
                "CD_FILE": axContext.selectedFilePaths.first ?? selectedFilePaths.first ?? "",
                "CD_CLIPBOARD": NSPasteboard.general.string(forType: .string) ?? "",
            ]
            AXTriggerRuleEngine.shared.run(type: .shortcut, value: sc.actionValue, envVars: envVars)
        }
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func appPillScriptExtensions(for appKey: String, query: String) -> [AppToolExtension] {
        settings.pillScriptExtensions(for: appKey, query: query, maxCount: query.isEmpty ? 6 : 4)
    }

    func executeAppToolExtension(_ ext: AppToolExtension, launchQuery: String = "") {
        guard ext.kind == .script,
            let lang = ext.scriptLanguage,
            !ext.toolPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        let queryText = launchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedFile: String = {
            if let previewFile = folderPreviewSelectedFile, !previewFile.isEmpty {
                return previewFile
            }
            if let idx = searchState.selectedIndex, idx < searchState.results.count,
                let path = searchState.results[idx].filePath, !path.isEmpty
            {
                return path
            }
            if let finderSelected = ContextDetector.shared.getFinderSelectedFiles().first?.path,
                !finderSelected.isEmpty
            {
                return finderSelected
            }
            if let axSelected = axContext.selectedFilePaths.first, !axSelected.isEmpty {
                return axSelected
            }
            return ""
        }()

        let fallbackQuery =
            axContext.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveQuery = queryText.isEmpty ? fallbackQuery : queryText
        let command = [
            lang.runCommand(scriptPath: ext.toolPath),
            shellQuote(selectedFile),
            shellQuote(effectiveQuery),
        ].joined(separator: " ")

        let ck = activeConsoleKey
        let panelTerm = panelTerminal(for: ck)
        panelShowConsoleMap[ck] = true
        panelTerm.sendCommand(command)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            panelTerm.terminalView.window?.makeFirstResponder(panelTerm.terminalView)
        }
    }

    // MARK: - File-Type Extensions Dock Row — shown when a file result is highlighted
    var selectedResultHasFileTypeExtensions: Bool {
        // True if we have context-based extensions for the selected file/result
        // (context extensions already handle file-type matching via their trigger system)
        guard let idx = searchState.selectedIndex, idx < searchState.results.count else {
            return !l2.contextExtensions.isEmpty
                && !l2.contextExtensions.filter {
                    switch $0.matchReason {
                    case .fileTypeMatch: return true
                    default: return false
                    }
                }.isEmpty
        }
        let result = searchState.results[idx]
        return (result.type == .file || result.type == .document) && !l2.contextExtensions.isEmpty
    }

    /// Shortcuts relevant to the currently highlighted search result's file type
    var fileTypeShortcutsForSelection: [AppShortcut] {
        // File selected inside folder preview takes priority
        if let selectedFile = folderPreviewSelectedFile, !selectedFile.isEmpty {
            let ext = URL(fileURLWithPath: selectedFile).pathExtension.lowercased()
            return fileTypeShortcuts(for: ext)
        }
        guard let idx = searchState.selectedIndex,
            idx < searchState.results.count
        else { return [] }
        let result = searchState.results[idx]
        guard result.type == .file || result.type == .document else { return [] }
        let ext =
            (result.filePath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }) ?? ""
        return fileTypeShortcuts(for: ext)
    }

    /// Name of the currently selected file in the folder preview (for display)
    var selectedFolderFileName: String? {
        guard let path = folderPreviewSelectedFile, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    func fileTypeShortcuts(for ext: String) -> [AppShortcut] {
        // Map common file extensions to app shortcut keys
        // Users can define their own shortcuts for these keys in Settings › App Shortcuts
        let key: String
        switch ext {
        case "pdf": key = "pdf"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff": key = "image"
        case "mp4", "mov", "avi", "mkv", "m4v": key = "video"
        case "mp3", "aac", "flac", "wav", "m4a": key = "audio"
        case "zip", "rar", "7z", "tar", "gz": key = "archive"
        case "doc", "docx", "pages": key = "document"
        case "xls", "xlsx", "numbers", "csv": key = "spreadsheet"
        case "ppt", "pptx", "key": key = "presentation"
        case "swift", "py", "js", "ts", "rb", "go", "rs", "kt": key = "code"
        default: return []
        }
        return settings.shortcuts(for: key)
    }

    /// Unified context-based dock row shown when a file/result is selected.
    /// Uses the scoring system from LayeredExtensionManager — no hardcoded AppShortcut file-type mapping.
    @ViewBuilder
    var fileTypeExtensionsInDock: some View {
        if l2.contextExtensions.isEmpty {
            pinnedAppsRow
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // File name chip (folder preview only)
                    if let fileName = selectedFolderFileName {
                        let ext = URL(fileURLWithPath: folderPreviewSelectedFile ?? "")
                            .pathExtension.lowercased()
                        HStack(spacing: 5) {
                            Image(systemName: fileIcon(for: ext))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(fileName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: 120)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.secondary.opacity(0.12), in: Capsule())
                    }

                    // Context-based action pills — auto-scored by file type, app, selection
                    ForEach(l2.contextExtensions, id: \.ilExtension.id) { result in
                        L2ExtensionChipButton(
                            extensionResult: result,
                            currentContext: currentContext,
                            onExecute: executeL2Extension
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

}
