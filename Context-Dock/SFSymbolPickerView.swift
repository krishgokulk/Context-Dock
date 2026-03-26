//
//  SFSymbolPickerView.swift
//  ILauncher
//
//  Glassy SF Symbol browser — search + 5-per-row grid.
//  Usage: SFSymbolPickerButton(selected: $iconName)
//

import SwiftUI

// MARK: - Public entry point ─────────────────────────────────────────────────

/// Drop-in replacement for the symbol text field in edit sheets.
/// Shows the current symbol icon + name; tap to open the picker popover.
struct SFSymbolPickerButton: View {
    @Binding var selected: String
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                // Live preview
                Image(systemName: validSymbol(selected))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))

                Text(selected.isEmpty ? "Choose symbol…" : selected)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(selected.isEmpty ? .secondary : .primary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            SFSymbolPickerView(selected: $selected, isPresented: $showPicker)
        }
    }

    private func validSymbol(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "questionmark.circle"
    }
}

// MARK: - Picker grid ─────────────────────────────────────────────────────────

struct SFSymbolPickerView: View {
    @Binding var selected: String
    @Binding var isPresented: Bool

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return allSymbols }
        return allSymbols.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Search bar ────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                TextField("Search symbols…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            // ── Symbol grid ───────────────────────────────────────────────
            ScrollView {
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No symbols match \"\(query)\"")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(filtered, id: \.self) { sym in
                            SymbolCell(name: sym, isSelected: sym == selected) {
                                selected = sym
                                isPresented = false
                            }
                        }
                    }
                    .padding(10)
                }
            }
            .frame(height: 320)
        }
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { searchFocused = true }
    }
}

// MARK: - Single cell ─────────────────────────────────────────────────────────

private struct SymbolCell: View {
    let name: String
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(systemName: name)
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 32, height: 32)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : (hovered ? Color.primary : Color.secondary))
        .help(name)
        .onHover { hovered = $0 }
    }

    private var background: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.15))
        } else if hovered {
            return AnyShapeStyle(Color.primary.opacity(0.07))
        } else {
            return AnyShapeStyle(Color.clear)
        }
    }
}

// MARK: - Symbol catalogue ────────────────────────────────────────────────────
// ~350 common symbols grouped by category so the default view is useful without searching.

private let allSymbols: [String] = {
    let catalogue: [[String]] = [
        // Files & Folders
        ["folder", "folder.fill", "folder.badge.plus", "folder.badge.minus", "folder.badge.gearshape",
         "doc", "doc.fill", "doc.text", "doc.text.fill", "doc.richtext", "doc.on.doc",
         "doc.on.clipboard", "doc.badge.plus", "doc.badge.gearshape", "internaldrive",
         "externaldrive", "archivebox", "archivebox.fill", "tray", "tray.fill", "tray.2",
         "tray.full", "tray.and.arrow.down", "tray.and.arrow.up", "square.and.arrow.down",
         "square.and.arrow.up", "arrow.down.doc", "arrow.up.doc", "scissors", "paperclip"],
        // Editing
        ["pencil", "pencil.circle", "pencil.circle.fill", "square.and.pencil", "pencil.tip",
         "highlighter", "eraser", "trash", "trash.fill", "trash.circle", "trash.circle.fill",
         "minus", "plus", "plus.circle", "plus.circle.fill", "minus.circle", "xmark",
         "xmark.circle", "xmark.circle.fill", "checkmark", "checkmark.circle",
         "checkmark.circle.fill", "checkmark.seal", "multiply", "arrow.uturn.backward",
         "arrow.uturn.forward", "arrow.counterclockwise", "arrow.clockwise"],
        // Communication
        ["envelope", "envelope.fill", "envelope.open", "envelope.badge", "envelope.open.badge",
         "message", "message.fill", "message.badge", "bubble.left", "bubble.right",
         "bubble.left.and.bubble.right", "phone", "phone.fill", "phone.badge.plus",
         "phone.and.waveform", "video", "video.fill", "video.badge.plus", "facetime",
         "megaphone", "megaphone.fill", "bell", "bell.fill", "bell.badge", "bell.slash",
         "bell.circle", "antenna.radiowaves.left.and.right"],
        // Navigation & Arrows
        ["arrow.up", "arrow.down", "arrow.left", "arrow.right", "arrow.up.right",
         "arrow.down.left", "arrow.up.left", "arrow.down.right", "arrow.left.arrow.right",
         "arrow.up.arrow.down", "arrow.forward", "arrow.backward", "chevron.up",
         "chevron.down", "chevron.left", "chevron.right", "chevron.left.2",
         "chevron.right.2", "chevron.up.chevron.down", "return", "escape", "command",
         "option", "shift", "control", "delete.left"],
        // People & Contacts
        ["person", "person.fill", "person.circle", "person.circle.fill", "person.2",
         "person.2.fill", "person.3", "person.badge.plus", "person.badge.minus",
         "person.crop.circle", "person.crop.circle.fill", "person.crop.rectangle",
         "person.text.rectangle", "figure.walk", "figure.seated.seatbelt",
         "hand.raised", "hand.raised.fill", "hands.clap", "figure.wave"],
        // Media & Entertainment
        ["play", "play.fill", "play.circle", "play.circle.fill", "play.rectangle",
         "pause", "pause.fill", "pause.circle", "stop", "stop.fill", "stop.circle",
         "forward", "backward", "forward.fill", "backward.fill", "shuffle",
         "repeat", "repeat.1", "music.note", "music.note.list", "music.quarternote.3",
         "music.mic", "headphones", "speaker", "speaker.fill", "speaker.wave.1",
         "speaker.wave.2", "speaker.wave.3", "speaker.slash", "tv", "tv.fill",
         "film", "film.fill", "photo", "photo.fill", "photo.on.rectangle",
         "photo.stack", "camera", "camera.fill", "camera.circle", "video.circle"],
        // System & Settings
        ["gear", "gearshape", "gearshape.fill", "gearshape.2", "slider.horizontal.3",
         "slider.vertical.3", "toggles", "switch.2", "cpu", "memorychip",
         "display", "desktopcomputer", "laptopcomputer", "keyboard", "printer",
         "scanner", "wifi", "wifi.slash", "network", "globe", "globe.americas",
         "antenna.radiowaves.left.and.right", "bolt", "bolt.fill", "bolt.circle",
         "bolt.slash", "battery.100", "battery.75", "battery.50", "battery.25",
         "battery.0", "powerplug", "powersleep", "power"],
        // Security & Privacy
        ["lock", "lock.fill", "lock.circle", "lock.open", "lock.open.fill",
         "lock.shield", "lock.shield.fill", "key", "key.fill", "person.badge.shield.checkmark",
         "shield", "shield.fill", "shield.checkered", "checkmark.shield", "xmark.shield",
         "eye", "eye.fill", "eye.slash", "eye.slash.fill", "hand.raised.slash",
         "exclamationmark.shield", "exclamationmark.triangle", "exclamationmark.triangle.fill"],
        // Apps & Productivity
        ["calendar", "calendar.badge.plus", "calendar.badge.minus", "calendar.badge.clock",
         "calendar.badge.exclamationmark", "clock", "clock.fill", "alarm", "alarm.fill",
         "timer", "stopwatch", "stopwatch.fill", "hourglass", "list.bullet",
         "list.bullet.clipboard", "list.clipboard", "checklist", "checklist.checked",
         "note", "note.text", "square.and.pencil", "doc.plaintext", "rectangle.and.pencil.and.ellipsis",
         "map", "map.fill", "location", "location.fill", "location.circle",
         "magnifyingglass", "magnifyingglass.circle", "loupe"],
        // Finance & Shopping
        ["cart", "cart.fill", "cart.badge.plus", "basket", "bag", "bag.fill",
         "bag.badge.plus", "creditcard", "creditcard.fill", "banknote", "dollarsign.circle",
         "eurosign.circle", "sterlingsign.circle", "yensign.circle", "bitcoinsign.circle",
         "chart.bar", "chart.bar.fill", "chart.line.uptrend.xyaxis", "chart.pie",
         "chart.pie.fill", "arrow.up.right", "arrow.down.right", "percent"],
        // Symbols & Misc
        ["star", "star.fill", "star.circle", "star.circle.fill", "star.slash",
         "heart", "heart.fill", "heart.circle", "heart.slash", "bookmark",
         "bookmark.fill", "bookmark.circle", "tag", "tag.fill", "tag.circle",
         "flag", "flag.fill", "flag.circle", "rosette", "seal", "seal.fill",
         "crown", "crown.fill", "trophy", "trophy.fill", "medal", "gift", "gift.fill",
         "sparkles", "wand.and.stars", "wand.and.rays", "party.popper",
         "balloon", "cloud", "cloud.fill", "sun.max", "sun.max.fill", "moon",
         "moon.fill", "moon.stars", "snowflake", "flame", "flame.fill",
         "drop", "drop.fill", "leaf", "leaf.fill", "tree"],
        // Coding & Terminal
        ["terminal", "terminal.fill", "chevron.left.forwardslash.chevron.right",
         "curlybraces", "curlybraces.square", "applescript", "hammer", "hammer.fill",
         "wrench", "wrench.fill", "wrench.and.screwdriver", "wrench.and.screwdriver.fill",
         "ladybug", "ladybug.fill", "ant", "ant.fill", "cpu", "memorychip",
         "server.rack", "externaldrive.badge.wifi", "network.badge.shield.half.filled"],
        // Sharing & Export
        ["square.and.arrow.up", "square.and.arrow.down", "square.and.arrow.up.on.square",
         "arrowshape.turn.up.right", "arrowshape.turn.up.left", "paperplane",
         "paperplane.fill", "paperplane.circle", "link", "link.circle",
         "link.badge.plus", "icloud", "icloud.fill", "icloud.and.arrow.up",
         "icloud.and.arrow.down", "airdrop", "shareplay"],
    ]
    return catalogue.flatMap { $0 }
}()
