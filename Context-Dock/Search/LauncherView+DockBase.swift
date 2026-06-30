import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension LauncherView {
    func openAICapabilityApprovalWindow(
        pending: AICapabilityApprovalCenter.PendingApproval
    ) {
        AICapabilityApprovalWindowHost.close()
        let controller = NSHostingController(rootView: AICapabilityApprovalView(pending: pending))
        let window = NSWindow(contentViewController: controller)
        window.title = "AI Action Approval"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.setContentSize(NSSize(width: 500, height: 340))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = AICapabilityApprovalWindowHost.shared
        AICapabilityApprovalWindowHost.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openAIPrivacyApprovalWindow(pending: AIPrivacyApprovalCenter.PendingApproval) {
        AIPrivacyApprovalWindowHost.close()
        let controller = NSHostingController(rootView: AIPrivacyApprovalView(pending: pending))
        let window = NSWindow(contentViewController: controller)
        window.title = "AI Privacy Approval"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.setContentSize(NSSize(width: 500, height: 280))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = AIPrivacyApprovalWindowHost.shared
        AIPrivacyApprovalWindowHost.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openCommandApprovalWindow(pending: TerminalAIBridge.PendingCommand) {
        CommandApprovalWindowHost.close()
        let view = CommandApprovalView(
            command: pending.command,
            classification: pending.classification,
            purpose: pending.purpose,
            onApprove: { approvedCommand in
                TerminalAIBridge.shared.approveCommand(approvedCommand)
            },
            onDeny: {
                TerminalAIBridge.shared.denyCommand()
            }
        )
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: controller)
        win.title = "Terminal Command Approval"
        win.styleMask = [.titled, .closable]
        win.level = .floating
        let isCritical = pending.classification.riskLevel == .critical
        win.setContentSize(NSSize(width: 520, height: isCritical ? 460 : 410))
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        CommandApprovalWindowHost.window = win
        // When the user closes via the X button, treat as deny
        win.delegate = CommandApprovalWindowHost.shared
    }

    func openAdapterApprovalWindow(request: AdapterActionRequest) {
        AdapterApprovalWindowHost.close()

        let size = NSSize(width: 460, height: 252)
        let view = AdapterApprovalPopupView(request: request)
        let controller = NSHostingController(rootView: view)
        let panel = AdapterApprovalPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = controller
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .transient]

        positionAdapterApprovalPanel(panel, size: size)

        AdapterApprovalWindowHost.shared.onClose = request.onDeny
        AdapterApprovalWindowHost.window = panel
        panel.delegate = AdapterApprovalWindowHost.shared
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func positionAdapterApprovalPanel(_ panel: NSPanel, size: NSSize) {
        if let launcherWindow = AppDelegate.shared?.launcherWindow, launcherWindow.isVisible {
            let screenFrame =
                (launcherWindow.screen ?? NSScreen.main)?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(origin: .zero, size: size)
            let margin: CGFloat = 16
            let verticalGap: CGFloat = 18

            var x = launcherWindow.frame.midX - (size.width / 2)
            var y = launcherWindow.frame.maxY + verticalGap

            x = min(max(x, screenFrame.minX + margin), screenFrame.maxX - size.width - margin)

            if y + size.height > screenFrame.maxY - margin {
                y = max(
                    screenFrame.minY + margin,
                    launcherWindow.frame.minY - size.height - verticalGap
                )
            }

            panel.setFrame(
                NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
            return
        }

        panel.center()
    }

    // Helper for sheet binding
    struct SheetItem: Identifiable {
        let id = UUID()
        let pending: TerminalAIBridge.PendingCommand
    }

    struct PendingTerminalCommand {
        let command: String
        let purpose: String
    }

    var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBarSection  // Combined status bar + frontmost toggle
            frontmostAppSection  // Frontmost app context below (collapsible)
            aiExtensionQuickActions  // Quick Actions for AI mode (ABOVE search input!)
            searchBarWithPinnedApps  // Search bar + pinned apps + results/chat (all inside expanding dock)
        }
        .background(Color.clear)  // Ensure no opaque fill above GlassBackground
    }

    // MARK: - Top Bar Section (Status extensions only, no frontmost toggle)
    @ViewBuilder
    var topBarSection: some View {
        // Removed frontmost toggle - shortcuts now show inline below search bar
        EmptyView()
    }

    // MARK: - Frontmost App Section (Below status bar)
    @ViewBuilder
    var frontmostAppSection: some View {
        // Context shortcuts now show inside dock on swipe up, not here
        EmptyView()
    }

    @ViewBuilder
    func appShortcutChip(shortcut: SearchResult) -> some View {
        Button(action: {
            // Execute the shortcut WITH CONTEXT
            executeResult(shortcut)
        }) {
            HStack(spacing: 3) {
                if let icon = shortcut.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                }
                Text(shortcut.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.08))
            .foregroundStyle(.primary)
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help(shortcut.subtitle)  // Show full subtitle on hover
    }

    @ViewBuilder
    var indexingProgressSection: some View {
        if fileIndexManager.progress.isIndexing {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)

                Text("Indexing files...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("\(fileIndexManager.progress.filesIndexed) files")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue)

                Spacer()

                Text("\(Int(fileIndexManager.progress.progressPercentage))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.05))
        }
    }

    // Search bar with integrated pinned apps
    var searchBarWithPinnedApps: some View {
        searchBarSection
            .fixedSize(horizontal: false, vertical: false)
    }

    @ViewBuilder
    var pinnedAppsSection: some View {
        EmptyView()
    }

    // MARK: - Dock Context & Apps Helper Views

    var hasContextToShow: Bool {
        guard settings.enableContextAIExtensions else { return false }

        // Always show for any real frontmost app — live menu bar pills work universally
        if let frontApp = AppDelegate.shared?.previousFrontmostApp,
            frontApp.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            return true
        }

        // Fallback: AX-readable context (URL, text selection, files)
        switch currentContext {
        case .filesSelected(let urls): return !urls.isEmpty
        case .textSelected(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .url(let urlString):
            return !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    @ViewBuilder
    var pinnedAppsRow: some View {
        EmptyView()
    }

    func preparedDockIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon else { return nil }
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: 64, height: 64)
        return copy
    }

    @ViewBuilder
    func appPillButton(
        icon: NSImage?,
        label: String,
        subtitle: String? = nil,
        hoverKey: String,
        focused: Bool = false,
        index: Int? = nil,
        isExpanded: Bool = false,  // fills the vacated search-bar width
        destructiveAction: (() -> Void)? = nil,
        destructivePhase: DockInlineFeedback.Phase? = nil,
        removeAction: (() -> Void)? = nil,
        pinAction: (() -> Void)? = nil,
        previewApp: NSRunningApplication? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let hovered = hoveredDockAppKey == hoverKey || focused
        let sz = CGFloat(settings.dockIconSize)
        let iconSize: CGFloat = isExpanded ? sz * 0.78 : sz * 0.72
        let textSize: CGFloat = min(isExpanded ? 15 : 13, max(12, sz * (isExpanded ? 0.24 : 0.22)))
        let pillHeight: CGFloat = isExpanded ? sz + 8 : sz + 4
        let cornerRadius: CGFloat = max(5, iconSize / 4.2)
        let leadingPad: CGFloat = isExpanded ? max(10, sz * 0.20) : max(10, sz * 0.18)
        let separatorHeight: CGFloat = isExpanded ? max(24, sz * 0.50) : max(24, sz * 0.46)
        let trailingPad: CGFloat =
            isExpanded ? 12 : (destructiveAction != nil || removeAction != nil ? 8 : 12)
        let isDarkMode = systemColorScheme == .dark

        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                HStack(spacing: 0) {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: iconSize, height: iconSize)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                            .padding(.leading, leadingPad)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.system(size: iconSize * 0.72, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: iconSize, height: iconSize)
                            .padding(.leading, leadingPad)
                    }
                    Rectangle()
                        .fill(Color.white.opacity(isExpanded ? 0.16 : 0.12))
                        .frame(width: 1, height: separatorHeight)
                        .padding(.horizontal, isExpanded ? 10 : 8)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(label)
                                .font(
                                    .system(
                                        size: textSize, weight: isExpanded ? .semibold : .medium)
                                )
                                .foregroundStyle(
                                    Color.primary.opacity(isExpanded ? 1.0 : (focused ? 1.0 : 0.9)))
                            if destructiveAction != nil {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: max(9, textSize - 3), weight: .semibold))
                                    .foregroundStyle(.secondary.opacity(isExpanded ? 0.75 : 0.62))
                            }
                        }
                        .lineLimit(1)
                        if isExpanded, let sub = subtitle {
                            Text(sub)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(
                                    sub == "Running"
                                        ? Color.green.opacity(0.85)
                                        : Color.secondary.opacity(0.65)
                                )
                                .lineLimit(1)
                        }
                    }
                    .padding(.trailing, isExpanded ? 4 : trailingPad)
                    .mask(alignment: .leading) {
                        // Smooth gradient fade on the trailing edge for expanded pills
                        if isExpanded {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.75),
                                    .init(color: .clear, location: 1.0),
                                ],
                                startPoint: .leading, endPoint: .trailing)
                        } else {
                            Color.black
                        }
                    }
                    if isExpanded {
                        Spacer(minLength: 0)
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.55))
                        .padding(.trailing, 12)
                    }
                }
                .frame(maxWidth: isExpanded ? .infinity : nil)
                .frame(height: pillHeight)
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(
                            isDarkMode
                                ? Color.black.opacity(isExpanded ? 0.10 : 0.06)
                                : Color.white.opacity(isExpanded ? 0.22 : 0.14)
                        )
                        Capsule().fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(
                                        isExpanded
                                            ? 0.18 : (focused ? 0.16 : (hovered ? 0.12 : 0.07))),
                                    .white.opacity(isExpanded ? 0.035 : (focused ? 0.04 : 0.015)),
                                ],
                                startPoint: .top, endPoint: .bottom)
                        )
                        Capsule().strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(isExpanded ? 0.34 : (hovered ? 0.28 : 0.16)),
                                    .white.opacity(0.035),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: isExpanded ? 1.0 : (focused ? 1.0 : 0.75))
                    }
                }
                .shadow(
                    color: .black.opacity(
                        isExpanded ? 0.20 : (focused ? 0.16 : (hovered ? 0.10 : 0.06))),
                    radius: isExpanded ? 10 : (focused ? 8 : 5),
                    y: isExpanded ? 5 : 3
                )
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isExpanded)
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: focused)
            }
            .buttonStyle(.plain)
            .zIndex(isExpanded ? 20 : (focused ? 10 : (hovered ? 5 : 0)))

            if (hovered || destructivePhase != nil), !isExpanded, let quit = destructiveAction {
                Button(action: quit) {
                    Group {
                        if destructivePhase == .progress {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.56)
                                .frame(width: max(14, sz * 0.24), height: max(14, sz * 0.24))
                        } else if destructivePhase == .success {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: max(14, sz * 0.24), weight: .semibold))
                                .foregroundStyle(.white, Color.green.opacity(0.78))
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: max(14, sz * 0.24), weight: .semibold))
                                .foregroundStyle(.white, Color.black.opacity(0.65))
                        }
                    }
                }
                .buttonStyle(.plain)
                .offset(x: max(4, sz * 0.08), y: -max(4, sz * 0.08))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if hovered, !isExpanded, let remove = removeAction {
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: max(14, sz * 0.24), weight: .semibold))
                        .foregroundStyle(.white, Color.black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .offset(x: max(4, sz * 0.08), y: -max(4, sz * 0.08))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

        }
        .onHover { hovering in
            guard acceptsMouseDrivenDockInteraction else { return }
            withAnimation(.spring(response: 0.15, dampingFraction: 0.80)) {
                hoveredDockAppKey = hovering ? hoverKey : nil
                if let index { hoveredAppPillIndex = hovering ? index : nil }
                if hovering, let previewApp {
                    RunningAppPreviewService.shared.scheduleShow(for: previewApp, icon: icon)
                } else if !hovering {
                    RunningAppPreviewService.shared.scheduleHide()
                }
            }
        }
        .help(label)
    }

    func appIconButton(
        icon: NSImage?,
        label: String,
        isRunning: Bool,
        runningApp: NSRunningApplication? = nil,
        hoverKey: String? = nil,
        onCloseRunningApp: (() -> Void)? = nil,
        closePhase: DockInlineFeedback.Phase? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let sz = CGFloat(settings.dockIconSize)
        let outerSz = sz + 4
        let cornerRadius = sz / 4.4
        let dotSize = max(5, sz * 0.159)
        return ZStack(alignment: .topTrailing) {
            Button(action: action) {
                ZStack(alignment: .bottomTrailing) {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: sz, height: sz)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    } else {
                        Image(systemName: "app")
                            .font(.system(size: sz * 0.636, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: sz, height: sz)
                    }

                    if isRunning {
                        Circle()
                            .fill(.green)
                            .frame(width: dotSize, height: dotSize)
                            .overlay(
                                Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5)
                            )
                            .offset(x: 2, y: 2)
                    }
                }
                .frame(width: outerSz, height: outerSz)
            }
            .buttonStyle(.plain)

            if let hoverKey, let onCloseRunningApp, isRunning {
                Button(action: onCloseRunningApp) {
                    Group {
                        if closePhase == .progress {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.55)
                                .frame(width: 16, height: 16)
                        } else if closePhase == .success {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white, Color.green.opacity(0.78))
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white, Color.black.opacity(0.72))
                        }
                    }
                    .background(Color.black.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity((hoveredDockAppKey == hoverKey || closePhase != nil) ? 1 : 0)
                .offset(x: 4, y: -4)
                .help("Quit \(label)")
            }
        }
        .frame(width: outerSz, height: outerSz)
        .onHover { hovering in
            guard acceptsMouseDrivenDockInteraction else { return }
            guard let hoverKey else { return }
            if hovering {
                hoveredDockAppKey = hoverKey
                if let runningApp {
                    RunningAppPreviewService.shared.scheduleShow(for: runningApp, icon: icon)
                }
            } else if hoveredDockAppKey == hoverKey {
                hoveredDockAppKey = nil
                RunningAppPreviewService.shared.scheduleHide()
            }
        }
        .help(label)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: sz)
    }

    @ViewBuilder
    func compactSuggestionPillButton(pill: DockPill, index: Int) -> some View {
        let accent = accentColor(for: pill.accentColorName)
        Button {
            executeDockPill(pill)
            l2.focusedPillIndex = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pill.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(pill.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                let status = pill.menuStatusBadge?.trimmingCharacters(in: .whitespacesAndNewlines)
                let badge = pill.badge?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let badge, !badge.isEmpty {
                    compactPillBadge(badge)
                }
                if let status, !status.isEmpty, status != badge {
                    compactPillBadge(status)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(accent.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(pill.name)
        .onHover { hovering in
            guard acceptsMouseDrivenDockInteraction else { return }
            if !l2.pillNavViaKeyboard {
                l2.focusedPillIndex = hovering ? index : nil
            }
        }
    }

    @ViewBuilder
    func compactPillBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.secondary.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    var contextChipsInDock: some View {
        // Combine frontmost app shortcuts and context-aware shortcuts
        let allContextShortcuts: [SearchResult] = {
            var shortcuts: [SearchResult] = []

            // Add context-aware shortcuts
            if !searchState.query.isEmpty && !searchState.grouped.suggestedShortcuts.isEmpty {
                shortcuts.append(contentsOf: searchState.grouped.suggestedShortcuts)
            } else if searchState.query.isEmpty && hasContextToShow {
                let contextMatched = allShortcuts.filter { shortcut in
                    guard let metadata = shortcutMetadataCache[shortcut.title] else { return false }
                    return metadata.matches(context: currentContext)
                }
                shortcuts.append(contentsOf: contextMatched)
            }

            // Remove duplicates by id
            var seen = Set<String>()
            return shortcuts.filter { shortcut in
                guard !seen.contains(shortcut.id) else { return false }
                seen.insert(shortcut.id)
                return true
            }
        }()

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allContextShortcuts) { shortcut in
                    Button(action: {
                        executeResult(shortcut)
                    }) {
                        HStack(spacing: 6) {
                            if let icon = shortcut.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                            }
                            Text(shortcut.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)
                    .help(shortcut.subtitle)
                }
            }
        }
    }

    // Check if AI extensions are available to show
    var hasAIExtensionsToShow: Bool {
        return aiMode.isActive && settings.enableContextAIExtensions
            && !aiExtensionSuggestions.isEmpty
    }

    var hasL2ExtensionsToShow: Bool {
        return settings.enableContextAIExtensions && !l2.contextExtensions.isEmpty
    }

    var isL2ContextActive: Bool {
        // L2 is active whenever the context dock is showing, we're not in pure AI mode,
        // and we're not in L3 browser layer. L3 must stay independent from L2.
        showContextInDock && !aiMode.isActive && !showMediaLayer
    }

    func dismissMediaLayer() {
        if showMediaLayer {
            showMediaLayer = false
        }
    }

    @ViewBuilder
    var aiExtensionsInDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(aiExtensionSuggestions) { suggestion in
                    AIExtensionChipButton(
                        suggestion: suggestion,
                        context: currentContext,
                        chatMessages: aiModeMessagesBinding
                    )
                }
            }
        }
    }

    // ── L2 Panel Quick Action Pills ─────────────────────────────────────────
    /// Quick actions from all user-created panels, shown as floating pills in L2 mode.
    /// Groups by panel key and shows up to 6 most recently used.
    var l2PanelQuickActions: [AppShortcut] {
        let allKeys = AppPanelChatStore.shared.allPanelKeys()
        let frontApp = frontmost.name.lowercased()
        // Prioritise panels matching the current frontmost app, then rest
        var keys = allKeys.filter {
            $0.localizedCaseInsensitiveContains(frontApp) && !frontApp.isEmpty
        }
        keys += allKeys.filter {
            !($0.localizedCaseInsensitiveContains(frontApp) && !frontApp.isEmpty)
        }
        // Gather shortcuts for these panel keys (max 8)
        var result: [AppShortcut] = []
        for key in keys {
            let shortcuts = settings.shortcuts(for: key)
            result.append(contentsOf: shortcuts)
            if result.count >= 8 { break }
        }
        return Array(result.prefix(8))
    }

    @ViewBuilder
    var l2QuickActionPills: some View {
        let pills = l2PanelQuickActions
        if !pills.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pills) { sc in
                        Button {
                            executeAppShortcut(sc)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: sc.iconName)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(sc.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    /// L2Extensions from L2ExtensionManager that match the current frontmost app.
    var frontmostAppL2Extensions: [L2Extension] {
        let appName: String
        let bundleID: String
        if !frontmost.name.isEmpty {
            appName = frontmost.name
            bundleID = frontmost.bundleID
        } else if let ws = NSWorkspace.shared.frontmostApplication,
            let name = ws.localizedName,
            !(ws.bundleIdentifier ?? "").contains("ILauncher")
        {
            appName = name
            bundleID = ws.bundleIdentifier ?? ""
        } else {
            return []
        }
        return l2Extensions(forAppName: appName, bundleID: bundleID)
    }

    func l2Extensions(forAppName appName: String, bundleID: String) -> [L2Extension] {
        let appLower = appName.lowercased()
        let bundleLower = bundleID.lowercased()
        return L2ExtensionManager.shared.extensions.filter { ext in
            guard !ext.contextApps.isEmpty else { return false }
            // Check ALL contextApps entries (app name OR bundle ID match)
            return ext.contextApps.contains { ctx in
                let ctxLower = ctx.lowercased()
                return ctxLower == appLower
                    || ctxLower.contains(appLower)
                    || appLower.contains(ctxLower)
                    || (!bundleLower.isEmpty
                        && (ctxLower == bundleLower || ctxLower.contains(bundleLower)))
            }
        }
    }

    func scopedContextExtensions(query: String, appName: String?, bundleId: String?)
        -> [ExtensionDiscoveryResult]
    {
        guard settings.enableContextAIExtensions else { return [] }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let includeSelectionContext =
            !isL2ContextActive && AppDelegate.shared?.isDockContextMode != true

        let contextFiles: [URL] = {
            guard includeSelectionContext else { return [] }
            switch currentContext {
            case .filesSelected(let urls): return urls
            default:
                return axContext.selectedFilePaths.map { URL(fileURLWithPath: $0) }
            }
        }()
        let selectedText: String? = {
            guard includeSelectionContext else { return nil }
            switch currentContext {
            case .textSelected(let t): return t.isEmpty ? nil : t
            default: return nil
            }
        }()

        let resolvedAppName: String? = {
            if let appName, !appName.isEmpty { return appName }
            if let bundleId,
                let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == bundleId
                })
            {
                return app.localizedName
            }
            return nil
        }()

        guard resolvedAppName != nil || !contextFiles.isEmpty || selectedText != nil else {
            return []
        }

        let results = LayeredExtensionManager.shared.discoverExtensions(
            for: trimmedQuery,
            selectedFiles: contextFiles,
            selectedText: selectedText,
            frontmostApp: resolvedAppName,
            layer: .l2_context
        )

        return Array(results.prefix(6))
    }

}
