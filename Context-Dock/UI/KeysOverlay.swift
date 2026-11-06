// KeysOverlay.swift
// Context-Dock
//
// On-demand shortcuts reference overlay (#332) and the single canonical key map (`DockKeyMap`)
// that both the Corner overlay and Settings -> Hotkeys read from so bindings never drift.
//
// Layer rule:
// - Presentation over existing key bindings inside `UnifiedDockSurface` (`CornerDockSurface`).
// - Pure display + dismiss (`⌘/`, `?`, `⎋`, close button, or click outside) — never a launcher
//   or search surface, and never recreates the window or mutates dock size/state.

import AppKit
import SwiftUI

/// The four surface groups shown in the Keys reference overlay (#332).
enum DockKeySurface: String, CaseIterable, Identifiable, Equatable {
    case launch
    case navigation
    case dock
    case chatAndClipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launch: return "Launch & Global"
        case .navigation: return "Scope & Navigation"
        case .dock: return "Global Context & App Pet"
        case .chatAndClipboard: return "Chat & Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .launch: return "bolt.fill"
        case .navigation: return "arrow.up.arrow.down"
        case .dock: return "command"
        case .chatAndClipboard: return "bubble.left.and.bubble.right.fill"
        }
    }

    var tint: Color {
        switch self {
        case .launch: return .teal
        case .navigation: return .blue
        case .dock: return .green
        case .chatAndClipboard: return .purple
        }
    }
}

/// One shortcut entry in `DockKeyMap`.
struct DockKeyBinding: Identifiable, Equatable {
    let id: String
    let surface: DockKeySurface
    let keys: [String]
    let title: String
    let subtitle: String?
    let isActive: Bool

    init(
        id: String,
        surface: DockKeySurface,
        keys: [String],
        title: String,
        subtitle: String? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.surface = surface
        self.keys = keys
        self.title = title
        self.subtitle = subtitle
        self.isActive = isActive
    }

    /// Single-string representation of `keys` for compact rows (e.g. Settings -> Hotkeys).
    var keysDisplay: String {
        keys.joined(separator: keys.contains("Swipe") || keys.contains("Expand") ? " " : "")
    }
}

/// A surface section and its active bindings.
struct DockKeyGroup: Identifiable, Equatable {
    let surface: DockKeySurface
    let bindings: [DockKeyBinding]

    var id: String { surface.id }
}

/// Single source of truth for active keyboard shortcuts across Launch, Navigation,
/// Global Context / App Pet, and Chat / Clipboard (#332).
///
/// Reads live from `AppSettings`, `DockKey`, `DockKeyRules`, `CornerNavigation`, and
/// `ClipboardBoardKey` — plus any dynamically registered bindings — so adding or changing
/// a binding updates the Keys overlay and Settings automatically with no extra edit.
enum DockKeyMap {
    private static var registeredCustomBindings: [DockKeyBinding] = []

    /// Register or update a binding in the canonical key map. If an entry with the same `id`
    /// already exists, it is replaced in-place; otherwise it is appended to its surface group.
    static func register(_ binding: DockKeyBinding) {
        if let idx = registeredCustomBindings.firstIndex(where: { $0.id == binding.id }) {
            registeredCustomBindings[idx] = binding
        } else {
            registeredCustomBindings.append(binding)
        }
    }

    static func unregister(id: String) {
        registeredCustomBindings.removeAll { $0.id == id }
    }

    static func resetRegisteredBindings() {
        registeredCustomBindings.removeAll()
    }

    /// Which surface group corresponds to the Corner's current presentation state.
    static func activeSurface(
        mode: CornerChatMode,
        isClipboardBoardOpen: Bool,
        phase: AppChatPromptPhase
    ) -> DockKeySurface {
        if isClipboardBoardOpen || mode == .general || phase == .chat {
            return .chatAndClipboard
        }
        if phase == .dock {
            return .navigation
        }
        return .dock
    }

    /// All active shortcut groups, read live from `settings` and the canonical rule types.
    static func groups(
        settings: AppSettings = .shared,
        includeInactive: Bool = false
    ) -> [DockKeyGroup] {
        let all = allBindings(settings: settings)
        return DockKeySurface.allCases.compactMap { surface in
            let matches = all.filter {
                $0.surface == surface && (includeInactive || $0.isActive) && !$0.keys.isEmpty
            }
            guard !matches.isEmpty else { return nil }
            return DockKeyGroup(surface: surface, bindings: matches)
        }
    }

    /// Flat list of all bindings (canonical + live `AppSettings` + registered custom bindings).
    static func allBindings(settings: AppSettings = .shared) -> [DockKeyBinding] {
        var base: [DockKeyBinding] = []
        base.append(contentsOf: launchBindings(settings: settings))
        base.append(contentsOf: navigationBindings)
        base.append(contentsOf: dockBindings)
        base.append(contentsOf: chatAndClipboardBindings)

        for custom in registeredCustomBindings {
            if let index = base.firstIndex(where: { $0.id == custom.id }) {
                base[index] = custom
            } else {
                base.append(custom)
            }
        }
        return base
    }

    // MARK: - 1. Launch & Global (Live from AppSettings)

    static func launchBindings(settings: AppSettings = .shared) -> [DockKeyBinding] {
        var list: [DockKeyBinding] = [
            DockKeyBinding(
                id: "launch.doubleCommand",
                surface: .launch,
                keys: ["⌘⌘"],
                title: "Global Context / Context Dock",
                subtitle: "Double-press Command to summon or dismiss",
                isActive: settings.useDoubleCommandGlobalContext
            ),
            DockKeyBinding(
                id: "launch.customGlobalContext",
                surface: .launch,
                keys: settings.hotkeyKeycaps(
                    keyCode: settings.globalContextHotkeyKeyCode,
                    modifiers: settings.globalContextHotkeyModifiers
                ),
                title: "Launch Context-Dock",
                subtitle: "Custom global launch shortcut",
                isActive: settings.globalContextHotkeyEnabled
            ),
            DockKeyBinding(
                id: "launch.doubleOption",
                surface: .launch,
                keys: ["⌥⌥"],
                title: "Centre Screen Launcher",
                subtitle: "Double-press Option for centred Spotlight search",
                isActive: settings.useDoubleOptionLaunch
            ),
            DockKeyBinding(
                id: "launch.clipboardScope",
                surface: .launch,
                keys: settings.hotkeyKeycaps(
                    keyCode: settings.clipboardScopeHotkeyKeyCode,
                    modifiers: settings.clipboardScopeHotkeyModifiers
                ),
                title: "Clipboard Scope",
                subtitle: "Open clipboard history board from anywhere",
                isActive: settings.clipboardScopeHotkeyKeyCode != 0
            ),
            DockKeyBinding(
                id: "launch.appPet",
                surface: .launch,
                keys: settings.hotkeyKeycaps(
                    keyCode: settings.appChatHotkeyKeyCode,
                    modifiers: settings.appChatHotkeyModifiers
                ),
                title: "Frontmost App Pet",
                subtitle: "Summon the frontmost app's Pet in the corner",
                isActive: settings.appChatHotkeyEnabled
            ),
            DockKeyBinding(
                id: "launch.quickNote",
                surface: .launch,
                keys: settings.hotkeyKeycaps(
                    keyCode: settings.quickNoteHotkeyKeyCode,
                    modifiers: settings.quickNoteHotkeyModifiers
                ),
                title: "Quick Note",
                subtitle: "Open a floating pinned note anywhere",
                isActive: settings.quickNoteHotkeyEnabled
            ),
            DockKeyBinding(
                id: "launch.chatWindow",
                surface: .launch,
                keys: settings.hotkeyKeycaps(
                    keyCode: settings.chatWindowHotkeyKeyCode,
                    modifiers: settings.chatWindowHotkeyModifiers
                ),
                title: "Full Chat Window",
                subtitle: "Open General Chat in its dedicated window",
                isActive: settings.chatWindowHotkeyEnabled
            ),
            DockKeyBinding(
                id: "launch.selectionScope",
                surface: .launch,
                keys: settings.hotkeyKeycaps(
                    keyCode: settings.selectionScopeHotkeyKeyCode,
                    modifiers: settings.selectionScopeHotkeyModifiers
                ),
                title: "Selection Scope",
                subtitle: "Open selected files or text in the corner",
                isActive: settings.selectionScopeHotkeyEnabled
            ),
            DockKeyBinding(
                id: "launch.captureText",
                surface: .launch,
                keys: settings.hotkeyKeycaps(
                    keyCode: settings.captureTextHotkeyKeyCode,
                    modifiers: settings.captureTextHotkeyModifiers
                ),
                title: "Capture Text (OCR)",
                subtitle: "Select screen text and copy to Clipboard",
                isActive: settings.captureTextHotkeyKeyCode != 0
            ),
            DockKeyBinding(
                id: "launch.captureArea",
                surface: .launch,
                keys: settings.hotkeyKeycaps(
                    keyCode: settings.captureAreaHotkeyKeyCode,
                    modifiers: settings.captureAreaHotkeyModifiers
                ),
                title: "Capture Area",
                subtitle: "Capture a screen region to Pictures & Clipboard",
                isActive: settings.captureAreaHotkeyKeyCode != 0
            ),
            DockKeyBinding(
                id: "launch.captureScreenshot",
                surface: .launch,
                keys: settings.hotkeyKeycaps(
                    keyCode: settings.captureScreenshotHotkeyKeyCode,
                    modifiers: settings.captureScreenshotHotkeyModifiers
                ),
                title: "Capture Full Screenshot",
                subtitle: "Save full screen to Pictures & Clipboard",
                isActive: settings.captureScreenshotHotkeyKeyCode != 0
            ),
        ]

        return list
    }

    // MARK: - 2. Scope & Navigation (SurfaceFocusRules & CornerNavigation)

    static var navigationBindings: [DockKeyBinding] {
        [
            DockKeyBinding(
                id: "nav.commandTap",
                surface: .navigation,
                keys: ["⌘"],
                title: "Toggle Scope (Global ↔ Frontmost App)",
                subtitle: "Tap Command alone to zoom out to Global or back into the frontmost app"
            ),
            DockKeyBinding(
                id: "nav.layerKeys",
                surface: .navigation,
                keys: [DockKey.up.symbol, DockKey.down.symbol],
                title: "Switch Surface Layer",
                subtitle: "Zoom between Global Context and Frontmost App on an empty field"
            ),
            DockKeyBinding(
                id: "nav.verticalSwipe",
                surface: .navigation,
                keys: ["↕", "Swipe"],
                title: "Trackpad Layer Swipe",
                subtitle: "Swipe up or down over the field to switch layers"
            ),
            DockKeyBinding(
                id: "nav.horizontalKeys",
                surface: .navigation,
                keys: [DockKey.left.symbol, DockKey.right.symbol],
                title: "Walk Running Apps & General Chat",
                subtitle: "→ steps through running apps; ← steps back or opens General Chat"
            ),
            DockKeyBinding(
                id: "nav.horizontalSwipe",
                surface: .navigation,
                keys: ["↔", "Swipe"],
                title: "Trackpad Sideways Swipe",
                subtitle: "Swipe right-to-left to walk running apps; left-to-right for General Chat"
            ),
            DockKeyBinding(
                id: "nav.emptyBackspace",
                surface: .navigation,
                keys: [DockKey.backspace.symbol],
                title: "Step Out of Scope",
                subtitle: "On an empty field: Folder → Selection → Chat → App Scope → Global"
            ),
        ]
    }

    // MARK: - 3. Global Context & App Pet (DockKeyRules)

    static var dockBindings: [DockKeyBinding] {
        [
            DockKeyBinding(
                id: "dock.return",
                surface: .dock,
                keys: [DockKey.returnKey.symbol],
                title: "Run Result or Ask App Pet",
                subtitle: "Execute the focused menu/action row or send your prompt"
            ),
            DockKeyBinding(
                id: "dock.tab",
                surface: .dock,
                keys: [DockKey.tab.symbol],
                title: "Step In / Focus App Pills",
                subtitle: "Autocomplete top match, step into focused app, or walk running-app pills"
            ),
            DockKeyBinding(
                id: "dock.menuReread",
                surface: .dock,
                keys: DockKeyRules.menuRereadKeycaps,
                title: "Refresh Context Menus",
                subtitle: "Re-scan the frontmost app's live menu bar on demand"
            ),
            DockKeyBinding(
                id: "dock.quickLook",
                surface: .dock,
                keys: ["⌘", "Y"],
                title: "Quick Look Preview",
                subtitle: "Preview the highlighted file or result row"
            ),
            DockKeyBinding(
                id: "dock.quitFocusedApp",
                surface: .dock,
                keys: ["⌘", DockKey.backspace.symbol],
                title: "Quit Focused App",
                subtitle: "Quit the running application highlighted in the result list"
            ),
            DockKeyBinding(
                id: "dock.openWithFinderSelection",
                surface: .dock,
                keys: ["⇧", DockKey.returnKey.symbol],
                title: "Open Finder Selection With App",
                subtitle: "Hand the current Finder selection to the highlighted app"
            ),
            DockKeyBinding(
                id: "dock.pin",
                surface: .dock,
                keys: ["⌘", "P"],
                title: "Pin Row or Keep Surface Open",
                subtitle: "Pin the highlighted row to the bar, or pin the surface open"
            ),
            DockKeyBinding(
                id: "dock.settings",
                surface: .dock,
                keys: ["⌘", ","],
                title: "Open Settings",
                subtitle: "Open DoraX Settings from any surface"
            ),
            DockKeyBinding(
                id: "dock.keysOverlay",
                surface: .dock,
                keys: DockKeyRules.keysOverlayKeycaps,
                title: "Keyboard Shortcuts Reference",
                subtitle: "Show or hide this live shortcuts overlay (also ⌘? or ? on resting dock)"
            ),
            DockKeyBinding(
                id: "dock.escape",
                surface: .dock,
                keys: [DockKey.escape.symbol],
                title: "Clear Focus, Collapse, or Dismiss",
                subtitle: "Unwind one step at a time without losing your draft"
            ),
        ]
    }

    // MARK: - 4. Chat & Clipboard (CornerRailRules & ClipboardBoardKey)

    static var chatAndClipboardBindings: [DockKeyBinding] {
        var list: [DockKeyBinding] = [
            DockKeyBinding(
                id: "chat.expand",
                surface: .chatAndClipboard,
                keys: ["↗", "Expand"],
                title: "Expand to Full Chat Window",
                subtitle: "Open the active App Pet, Combined, or General chat in the full window"
            ),
            DockKeyBinding(
                id: "chat.clearConversation",
                surface: .chatAndClipboard,
                keys: ["⌘", "K"],
                title: "New / Clear Conversation",
                subtitle: "Start a fresh turn in the current App Pet conversation"
            ),
            DockKeyBinding(
                id: "chat.slashCommands",
                surface: .chatAndClipboard,
                keys: ["/"],
                title: "Slash Commands & Modes",
                subtitle: "Switch App Pet modes (/mods) or borrow an app ability in General Chat"
            ),
            DockKeyBinding(
                id: "chat.sideThread",
                surface: .chatAndClipboard,
                keys: ["⌥", "S"],
                title: "Branch Side Thread",
                subtitle: "Branch a temporary tangent from the current turn (/side)"
            ),
            DockKeyBinding(
                id: "chat.conversationsBoard",
                surface: .chatAndClipboard,
                keys: ["⌥", "H"],
                title: "Past Conversations Board",
                subtitle: "Browse and reopen past conversations across all scopes (/conversations)"
            ),
        ]
        list.append(contentsOf: ClipboardBoardKey.canonicalBindings)
        return list
    }
}

// MARK: - Overlay Geometry

enum KeysOverlayMetrics {
    static let height: CGFloat = 380
    static let headerHeight: CGFloat = 40
    static let footerHeight: CGFloat = 34
    /// Clearance above the 56pt input/dock bar (`56 + CornerDockLayout.gap`), placing the
    /// overlay directly in the board slot without moving or resizing the underlying surface.
    static let barClearance: CGFloat = AppChatPromptMetrics.inputHeight + CornerDockLayout.gap

    static var size: CGSize {
        CGSize(width: DockShellWidth.current, height: height)
    }

    /// Exact hit-test rect in `CornerDockHostView`'s bottom-left coordinate space, before
    /// `mirroredIfTopDown` flips it for centred / notch top-down mode.
    static func bottomSlotRect(
        anchor: CornerDockAnchor,
        panelWidth: CGFloat
    ) -> CGRect {
        let overlaySize = size
        let pad = CornerDockLayout.pad
        let x: CGFloat
        switch anchor {
        case .right:
            x = panelWidth - pad - overlaySize.width
        case .left:
            x = pad
        case .center, .notch:
            x = (panelWidth - overlaySize.width) / 2
        }
        return CGRect(
            x: x,
            y: pad + barClearance,
            width: overlaySize.width,
            height: overlaySize.height
        )
    }
}

// MARK: - Overlay Card View

/// On-demand shortcuts reference overlay rendered over the current Corner surface (#332).
/// Display + dismiss only — never a search bar or launcher, and never mutates dock state.
struct KeysOverlayCard: View {
    @ObservedObject var chatPresentation = CornerChatPresentation.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var clipboardModel = ClipboardPanelController.shared.model

    private var groups: [DockKeyGroup] {
        DockKeyMap.groups(settings: settings)
    }

    private var currentSurface: DockKeySurface {
        DockKeyMap.activeSurface(
            mode: chatPresentation.mode,
            isClipboardBoardOpen: clipboardModel.isBoardOpen,
            phase: chatPresentation.appChat.phase
        )
    }

    var body: some View {
        let cardSize = KeysOverlayMetrics.size
        VStack(spacing: 0) {
            header
            hairline
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        sectionView(group)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            hairline
            footer
        }
        .frame(width: cardSize.width, height: cardSize.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(BoardGlass())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard Shortcuts Reference")
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))

            Text("Keyboard Shortcuts")
                .font(.system(size: 13, weight: .semibold))

            Text("Live Key Map")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: Capsule())

            Spacer(minLength: 8)

            Button {
                chatPresentation.dismissKeysOverlay()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close shortcuts overlay (Esc or ⌘/)")
            .accessibilityLabel("Close shortcuts overlay")
        }
        .padding(.horizontal, 14)
        .frame(height: KeysOverlayMetrics.headerHeight)
    }

    private func sectionView(_ group: DockKeyGroup) -> some View {
        let isCurrent = group.surface == currentSurface
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.surface.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(group.surface.tint)
                Text(group.surface.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                if isCurrent {
                    Text("Active Surface")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(group.surface.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(group.surface.tint.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 1) {
                ForEach(group.bindings) { binding in
                    bindingRow(binding)
                }
            }
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isCurrent ? group.surface.tint.opacity(0.28) : Color.white.opacity(0.07),
                        lineWidth: 1
                    )
            )
        }
    }

    private func bindingRow(_ binding: DockKeyBinding) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(binding.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle = binding.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            BoardFooter.keycaps(binding.keys)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Synced with Settings → Hotkeys")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            BoardFooter.pill {
                BoardFooter.action("Toggle", keys: DockKeyRules.keysOverlayKeycaps, dimmed: true)
                BoardFooter.divider
                BoardFooter.action("Dismiss", keys: [DockKey.escape.symbol], dimmed: true)
            }
            BoardFooter.pill {
                BoardFooter.button("gearshape", keys: ["⌘", ","], help: "Open Hotkeys Settings (⌘,)") {
                    chatPresentation.dismissKeysOverlay()
                    AppDelegate.shared?.showSettings()
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: KeysOverlayMetrics.footerHeight)
    }
}
