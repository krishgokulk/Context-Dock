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

/// The plugin's panel, above its tile. Opened by a tap in the widget, closed by ×, by the
/// tap that made the choice (a `set` action completing), or by the corner folding.
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
                Button { model.pluginCardPinID = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
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
                model?.pluginCardPinID = nil
            }
        }
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
