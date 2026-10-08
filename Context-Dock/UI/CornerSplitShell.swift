// CornerSplitShell.swift
// Context-Dock
//
// The field and the apps as two pieces of glass (owner 2026-10-07, "Part B"): while the field
// is open — Global Context or an app's Context Dock — the search field stands on the left and
// the pinned and running apps, with the clipboard and the Drop Shelf, stand beside it on the
// right, one bottom line under whatever board is up.
//
//     ┌─────────────────────────────┐
//     │ results  ·  preview         │
//     ├──────────────────┬──────────┤
//     │ 🔍 field         │ apps · 📋 │
//     └──────────────────┴──────────┘
//
// The apps are as wide as what they hold; the field takes the rest, so the two and the gap
// between them are the shell's one width. The field's text stack is laid out at the field's
// width and changes it at once, never over frames: resizing the layer that holds the
// TextField per frame is what made SwiftUI rebuild the key-view loop and hang the app (see
// `globalBody`). Only the glass around it animates.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CornerSplitShell {
    /// Between the field and the apps once they have separated. Wider than
    /// `dropletSpacing`, so the two pieces pinch apart rather than staying joined.
    static let gap: CGFloat = 14

    /// The liquid-glass container's merge distance: closer than this the field and the apps
    /// draw as one shape. The apps piece starts against the field and moves out past it,
    /// which is the water-droplet split (owner 2026-10-07: "perfect water droplet split").
    static let dropletSpacing: CGFloat = 10

    /// Whether the shell splits now: while the field is open (typed into or about to be) in
    /// Global or an app's scope, and only when the apps' piece has something to hold — an
    /// empty capsule beside the field is glass for nothing. A conversation keeps its own
    /// composer (`splitsChat`), General is its own surface.
    static func splits(
        isVisible: Bool, isGeneral: Bool, phase: AppChatPromptPhase, stripHasContent: Bool
    ) -> Bool {
        guard isVisible, !isGeneral, phase == .prompt || phase == .suggesting else { return false }
        return stripHasContent
    }

    /// The bottom line's two widths. The apps fit their icons and tools; the field takes what
    /// they and the gap leave. With nothing to show, the field is the whole shell.
    static func widths(shell: CGFloat, apps: Int, pins: Int = 0, tools: Int)
        -> (field: CGFloat, strip: CGFloat)
    {
        guard apps + pins + tools > 0 else { return (shell, 0) }
        let strip = stripWidth(shell: shell, apps: apps, pins: pins, tools: tools)
        return (shell - strip - gap, strip)
    }

    /// Fitted to the icons and tools, never under a capsule's worth, never over half the shell
    /// — past that the icons scroll.
    static func stripWidth(shell: CGFloat, apps: Int, pins: Int = 0, tools: Int) -> CGFloat {
        let fitted = CornerSplitStrip.contentWidth(apps: apps, pins: pins, tools: tools)
        return min(max(fitted, minimumStripWidth), (shell / 2).rounded())
    }

    static let minimumStripWidth: CGFloat = 64

    /// Where the apps piece sits inside the field's slot (the slot's own space, bottom-left
    /// origin): after the field and the gap, along the bottom line at the field's height.
    /// The window watches the pointer against this rather than the piece's SwiftUI hover:
    /// the field's layer runs on under the apps (its layout keeps one width), and the hover
    /// there never reliably reached the icons (owner 2026-10-08: "why still doesn't it go
    /// back to the dock?"). The same pointer test the shell already uses for everything else.
    static func stripRect(
        slot: CGRect, fieldWidth: CGFloat, stripWidth: CGFloat, height: CGFloat
    ) -> CGRect? {
        guard stripWidth > 0 else { return nil }
        return CGRect(
            x: slot.minX + fieldWidth + gap, y: slot.minY,
            width: stripWidth, height: min(height, slot.height))
    }

    /// How long the pointer rests on the apps before the field folds into the dock: long
    /// enough that crossing them on the way somewhere else does not fold it.
    static let foldDwell: TimeInterval = 0.18

    /// In a conversation the composer is inset in the chat card, under the transcript and the
    /// app's panel (`CornerLivePanel`). The apps take the panel's column, inset by the
    /// composer's own 10-point margin so they line up with the panel above them.
    static let chatInset: CGFloat = 10

    static func chatStripWidth(card: CGFloat) -> CGFloat {
        CornerLivePanelLayout.panelWidth(card: card) - chatInset
    }

    /// Whether a conversation's composer splits: only with the app's panel open above, so the
    /// apps have a column to stand under, and only with apps to show (owner 2026-10-07:
    /// "show same for chat as well, if user pinned something").
    static func splitsChat(phase: AppChatPromptPhase, showsLivePanel: Bool, hasApps: Bool) -> Bool {
        phase == .chat && showsLivePanel && hasApps
    }
}

/// The right column's foot: pinned apps first, then whatever else is running, then the
/// clipboard and the Drop Shelf — the same apps, in the same order, as the resting strip.
struct CornerSplitStrip: View {
    @ObservedObject var model: AppChatPromptModel
    let width: CGFloat
    /// Inside the chat card, beside the composer: drawn the way the composer is — an inset
    /// rounded field — rather than as a glass capsule of its own floating in the shell.
    var inset: Bool = false
    @ObservedObject private var pins = DockPinStore.shared
    @ObservedObject private var clipboard = ClipboardPanelController.shared.model
    @ObservedObject private var shelf = DropShelfController.shared.presentation
    @ObservedObject private var shelfStore = DropShelfController.shared.store

    /// The resting dock's own icon size, so an icon is the same size in the dock and beside
    /// the field (owner 2026-10-08: "stay the same size, bigger, in both").
    static let iconSize: CGFloat = AppChatPromptMetrics.dockIconSize
    /// Beside a conversation's composer the row is the composer's height, so smaller there.
    static let chatIconSize: CGFloat = 28

    private var icon: CGFloat { inset ? Self.chatIconSize : Self.iconSize }
    static let spacing: CGFloat = 8
    static let toolSize: CGFloat = 26
    static let horizontalPadding: CGFloat = 14

    /// The width that holds the icons and tools without scrolling: the padding, each group's
    /// icons and their gaps, and a hairline between groups — apps | pinned extensions | tools.
    static func contentWidth(apps: Int, pins: Int = 0, tools: Int) -> CGFloat {
        let groups = [
            (max(apps, 0), iconSize), (max(pins, 0), iconSize), (max(tools, 0), toolSize),
        ].filter { $0.0 > 0 }
        var width = horizontalPadding * 2
        for (count, size) in groups {
            width += CGFloat(count) * size + CGFloat(count - 1) * spacing
        }
        if apps > 0 { width += 4 }  // the apps' scroll inset
        width += CGFloat(max(groups.count - 1, 0)) * (spacing + 1 + spacing)
        return width
    }

    /// Which tools close the strip, by the resting dock's own rules: the clipboard for a few
    /// seconds after a copy or while its board is open (`showsDockIcon`), the Drop Shelf only
    /// while it holds something or a drag is in flight (`DropShelfVisibility`).
    static func tools(for model: AppChatPromptModel) -> (clipboard: Bool, shelf: Bool) {
        (ClipboardPanelController.shared.model.showsDockIcon, model.showsShelf)
    }

    static func toolCount(for model: AppChatPromptModel) -> Int {
        let tools = tools(for: model)
        return (tools.clipboard ? 1 : 0) + (tools.shelf ? 1 : 0)
    }

    /// The resting strip's own composition, so an app is in the same place in both.
    static func composition(for model: AppChatPromptModel) -> DockStripComposition {
        // Every scope's field stands apart from what is beside it (owner 2026-10-07): an app
        // bar's own pins and tabs, otherwise the remaining running apps (`stripIcons` leaves
        // the scoped app out), and Global's pinned extensions.
        DockStripPlan.make(
            running: model.stripIcons, pins: model.stripPins, tools: 0,
            fieldIcons: 0
        ).composition
    }

    static func apps(for model: AppChatPromptModel) -> [DockAppSlot] {
        composition(for: model).apps
    }

    /// The pins that are not apps — extensions, commands, files — after the apps and a
    /// hairline, as the resting dock keeps them (owner 2026-10-07).
    static func pins(for model: AppChatPromptModel) -> [DockPin] {
        composition(for: model).otherPins
    }

    var body: some View {
        // Its own height as a capsule in the shell; the composer's, beside it in the chat card.
        let height: CGFloat? = inset ? nil : AppChatPromptMetrics.fieldHeight(global: true)
        let tools = Self.tools(for: model)
        let composition = Self.composition(for: model)
        let apps = composition.apps
        let pins = composition.otherPins
        HStack(spacing: Self.spacing) {
            if !apps.isEmpty || !pins.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(apps) { slot in
                            appButton(slot)
                        }
                        if !apps.isEmpty, !pins.isEmpty { hairline }
                        ForEach(pins) { pin in
                            pinButton(pin)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                if tools.clipboard || tools.shelf { hairline }
            }
            if tools.clipboard {
                toolButton("doc.on.clipboard", title: "Clipboard", tinted: clipboard.isBoardOpen) {
                    ClipboardPanelController.shared.toggle()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            if tools.shelf {
                DropShelfIcon(presentation: shelf, store: shelfStore, style: .control)
                    .frame(width: Self.toolSize, height: Self.toolSize)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.smooth(duration: 0.2), value: tools.clipboard)
        .animation(.smooth(duration: 0.2), value: tools.shelf)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(width: width, height: height)
        .frame(maxHeight: inset ? .infinity : nil)
        .modifier(StripChrome(inset: inset))
        // A file or folder dropped on the apps beside the field is pinned, as on the resting
        // dock (owner 2026-10-08: "allow the user to place files and folders on the dock").
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Self.pinDroppedFiles(providers)
        }
    }

    /// Pins each dropped file or folder to the dock, the resting strip's own way
    /// (`DockPinKind(fileURL:)`, `DockPinStore.pin`).
    static func pinDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil),
                    let kind = DockPinKind(fileURL: url)
                else { return }
                Task { @MainActor in
                    DockPinStore.shared.pin(kind, title: url.lastPathComponent)
                }
            }
            accepted = true
        }
        return accepted
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 1, height: icon * 0.6)
    }

    /// A pinned extension, command or file: its icon, and the resting dock's click.
    private func pinButton(_ pin: DockPin) -> some View {
        let document = pin.documentID.flatMap { GlobalSearchService.shared.document(withID: $0) }
        return Button {
            model.openStripPin(pin, document: document)
        } label: {
            VStack(spacing: 1) {
                Group {
                    if let image = pin.kind.icon ?? document?.icon {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: pin.kind.fallbackSymbol)
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: icon, height: icon)
                Circle().fill(Color.clear).frame(width: 3, height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pin.title)
        .accessibilityLabel(pin.title)
    }

    private func appButton(_ slot: DockAppSlot) -> some View {
        Button {
            open(slot)
        } label: {
            VStack(spacing: 1) {
                Group {
                    if let image = slot.running?.icon ?? slot.pin?.kind.icon {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: icon, height: icon)
                .opacity((slot.pin.map { $0.kind.isAvailable } ?? true) ? 1 : 0.4)
                Circle()
                    .fill(Color.primary.opacity(slot.isRunning ? 0.55 : 0))
                    .frame(width: 3, height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(slot.title)
        .accessibilityLabel(slot.title)
    }

    /// What a click on the resting strip's icon does, minus the hover previews: an app bar's
    /// pin or tab runs, a pinned app's pin runs, a running app in Global is minimised or
    /// brought forward (`DockAppClick`), anything else launches.
    private func open(_ slot: DockAppSlot) {
        // An app's bar (its pins and tabs) opens them the way the bar inside the field did.
        if model.showsTabBar, let icon = slot.running {
            model.openBarIcon(icon)
        } else if let pin = model.appPin(forIconID: slot.bundleID) {
            model.openAppPin(pin)
        } else if model.isGlobalScope, slot.isRunning {
            // Global's running apps are the window manager's (owner 2026-10-07): the app in
            // front has its front window minimised, any other comes forward.
            DockAppClick.click(bundleID: slot.bundleID, name: slot.title)
        } else if let icon = slot.running {
            model.openGlobalMatchIcon(icon)
        } else if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: slot.bundleID)
        {
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func toolButton(
        _ symbol: String, title: String, tinted: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tinted ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    tinted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08),
                    in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The strip's container: a glass capsule of its own in the shell, or the composer's inset
/// rounded field inside the chat card.
private struct StripChrome: ViewModifier {
    let inset: Bool

    func body(content: Content) -> some View {
        if inset {
            content
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                }
        } else {
            content
                .clipShape(Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
    }
}

