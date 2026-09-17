// Context-Dock
//
// A plugin in the dock strip. Phase 4's first host: a pinned plugin whose manifest declares
// a `bar` widget draws that widget in the pins region, `slots` icons wide and one icon tall,
// so it sits in the row with the apps and the files rather than as a card over them.
//
// One renderer, many hosts: this is `PluginHostView` with strip traits. What the strip adds
// is where a push goes — a widget's `push:panel` cannot open inside a 48-point tile, so it
// opens as a card above the tile, in the slot the window row and the pin preview use,
// anchored over the tile the way those are anchored over their icon.

import SwiftUI

struct PluginStripTile: View {
    let pin: DockPin
    let manifest: PluginManifest
    @ObservedObject var model: AppChatPromptModel
    @StateObject private var host: PluginHostModel
    @Environment(\.colorScheme) private var scheme

    init(pin: DockPin, manifest: PluginManifest, model: AppChatPromptModel) {
        self.pin = pin
        self.manifest = manifest
        self.model = model
        _host = StateObject(wrappedValue: PluginHostModel(
            manifest: manifest, presentation: .widget, compact: true))
    }

    private var width: CGFloat {
        HostTraits.barWidth(slots: manifest.views.widget?.slots ?? PluginWidgetView.defaultSlots)
    }

    var body: some View {
        PluginHostView(model: host)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(width: width, height: AppChatPromptMetrics.dockIconSize)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onAppear {
                host.onPush = { [weak model] _, request in
                    // The card above the tile shows the panel; the tile stays the tile. The
                    // same chip again puts the card away — a chip is a toggle for its own
                    // picker — while the other chip switches the card to its choice.
                    guard let model else { return true }
                    let action = manifest.actions[request.name]
                    let asked = request.value?.stringValue ?? action?.value
                    let showing = PluginRuntime.shared.stateStore.state(for: manifest)
                    if model.pluginCardPinID == pin.id, let key = action?.key,
                        let asked, showing[key]?.stringValue == asked
                    {
                        model.pluginCardPinID = nil
                    } else {
                        model.pluginCardPinID = pin.id
                    }
                    return true
                }
            }
            .help(manifest.name)
            .accessibilityLabel(manifest.name)
    }
}

/// A plugin in the strip as an icon: its `icon` view, live, in one slot — the Sonos capsule
/// with the artwork and the waveform on it, where a symbol stood before. The second strip
/// host. Same footprint as `DockStripIcon` (content square over the running dot's row), so
/// it lines up with the apps and magnifies with them; the strip wraps it in the hover, tap,
/// drag and menu every other pin has.
struct PluginStripIcon: View {
    /// The content square inside a slot, the size an app icon draws at.
    static let content: CGFloat = AppChatPromptMetrics.dockIconSize - 8
    static let radius: CGFloat = 10

    let manifest: PluginManifest
    let scale: CGFloat
    @StateObject private var host: PluginHostModel

    init(manifest: PluginManifest, scale: CGFloat) {
        self.manifest = manifest
        self.scale = scale
        _host = StateObject(wrappedValue: PluginHostModel(
            manifest: manifest, presentation: .icon, compact: true))
    }

    /// Whether the strip draws this plugin's icon view rather than its symbol: it declares
    /// one, and it is not a bar widget — the bar is the tile, and the tile is what shows.
    static func drawsLive(_ manifest: PluginManifest) -> Bool {
        manifest.views.widget?.family != .bar
            && PluginHostModel.root(of: manifest, for: .icon) != nil
    }

    var body: some View {
        VStack(spacing: 2) {
            PluginHostView(model: host)
                .frame(width: Self.content, height: Self.content)
                .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .scaleEffect(scale, anchor: .bottom)
                .animation(.snappy(duration: 0.18), value: scale)
            Circle().fill(.clear).frame(width: 4, height: 4)
        }
        .frame(
            width: AppChatPromptMetrics.dockIconSize, height: AppChatPromptMetrics.dockIconSize)
        .contentShape(Rectangle())
        .help(manifest.name)
    }
}

/// The plugin's panel, above its tile or icon. Opened by a tap in the widget or by resting
/// on the icon; closed by ×, by the tap that made the choice (a `set` action completing),
/// by the pointer leaving a hover-opened card, or by the corner folding.
struct CornerPluginCard: View {
    let pin: DockPin
    let manifest: PluginManifest
    @ObservedObject var model: AppChatPromptModel
    @StateObject private var host: PluginHostModel

    init(pin: DockPin, manifest: PluginManifest, model: AppChatPromptModel) {
        self.pin = pin
        self.manifest = manifest
        self.model = model
        _host = StateObject(wrappedValue: PluginHostModel(
            manifest: manifest, presentation: .panel, compact: true))
    }

    private typealias M = CornerPluginCardMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // A panel that opens with its own header — "Convert from" — names itself; the
                // chrome then carries only the ×, or the card said two names for one thing.
                if !M.panelNamesItself(manifest) {
                    Image(systemName: manifest.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(manifest.name)
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer(minLength: 0)
                // ▢ takes the plugin out of the corner into its own window — the same
                // renderer at window width — and the card, whose job the window now has,
                // goes away with it.
                chromeButton("macwindow", help: "Open as a window") {
                    PluginWindowManager.shared.open(manifest)
                    model.dismissPluginCard()
                }
                chromeButton("xmark", help: "Close") { model.dismissPluginCard() }
            }
            .frame(height: M.headerHeight)
            // What does not fit scrolls. The corner's swipe monitor only claims scrolls over
            // the field itself, so two fingers here reach this view.
            ScrollView(.vertical, showsIndicators: false) {
                PluginHostView(model: host)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(M.inset)
        .frame(width: M.width, height: M.size(for: manifest).height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { inside in model.windowRowHovered(inside) }
        .onAppear {
            host.onActionCompleted = { [weak model] request, succeeded in
                // A choice made is the card's job done. A push or a failure keeps it up: the
                // first is navigation inside it, the second has something to say.
                guard succeeded, manifest.actions[request.name]?.type == "set" else { return }
                model?.dismissPluginCard()
            }
        }
    }

    private func chromeButton(_ symbol: String, help: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Which pin's panel the card above the strip shows. Two ways in: a tap opened it, or the
/// pointer is resting on a plugin that draws as an icon. The tap wins — a card a person
/// opened is not put away by the pointer crossing the next icon — and a bar tile never
/// opens on hover, because the tile is already the plugin's preview and its chips open the
/// card themselves; a hover-opened card would fight the chip that closes it.
enum CornerPluginCardRouting {
    static func cardPin(
        open: UUID?, hovered: UUID?, pins: [DockPin],
        manifest: (String) -> PluginManifest?
    ) -> (pin: DockPin, manifest: PluginManifest)? {
        if let open, let found = resolve(open, pins: pins, manifest: manifest) { return found }
        guard let hovered, let found = resolve(hovered, pins: pins, manifest: manifest),
            found.manifest.views.widget?.family != .bar
        else { return nil }
        return found
    }

    private static func resolve(
        _ id: UUID, pins: [DockPin], manifest: (String) -> PluginManifest?
    ) -> (pin: DockPin, manifest: PluginManifest)? {
        guard let pin = pins.first(where: { $0.id == id }),
            let pluginID = pin.kind.pluginID,
            let manifest = manifest(pluginID),
            manifest.views.panel != nil
        else { return nil }
        return (pin, manifest)
    }
}

/// The card's size is a function of the manifest and the corner's compact traits — never
/// measured — so the slot the corner hit-tests is the card that is drawn.
enum CornerPluginCardMetrics {
    static let width: CGFloat = HostTraits.cornerPanel.width
    static let inset: CGFloat = 12
    static let headerHeight: CGFloat = 24

    /// True when the panel's first leaf is a `header`: it names itself, so the chrome does
    /// not.
    static func panelNamesItself(_ manifest: PluginManifest) -> Bool {
        guard let root = manifest.views.panel?.root else { return false }
        if root.component == "header" { return true }
        return root.children.first?.component == "header"
    }

    static func size(for manifest: PluginManifest) -> CGSize {
        let traits = HostTraits.cornerPanel
        let root = manifest.views.panel?.root
        let binding = PluginBinding(
            data: PluginRuntime.bindable(manifest.state, under: manifest.sample))
        let content = root.map { PluginSizing.treeHeight($0, traits: traits, binding: binding) } ?? 0
        let height = min(traits.maxHeight, 2 * inset + headerHeight + content)
        return CGSize(width: width, height: height)
    }
}
