import AppKit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI

struct PinnedAppDropDelegate: DropDelegate {
    let item: PinnedApp
    @Binding var pinnedApps: [PinnedApp]
    let settings: AppSettings

    func performDrop(info: DropInfo) -> Bool {
        return true
    }

    func dropEntered(info: DropInfo) {
        // Get the dragged item ID
        guard let itemProvider = info.itemProviders(for: [.text]).first else { return }

        itemProvider.loadItem(forTypeIdentifier: "public.text", options: nil) { (data, error) in
            guard let data = data as? Data,
                let draggedIdString = String(data: data, encoding: .utf8),
                let draggedId = UUID(uuidString: draggedIdString)
            else { return }

            DispatchQueue.main.async {
                // Find the indices
                guard let fromIndex = self.pinnedApps.firstIndex(where: { $0.id == draggedId }),
                    let toIndex = self.pinnedApps.firstIndex(where: { $0.id == self.item.id }),
                    fromIndex != toIndex
                else { return }

                // Perform the reorder with animation
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    let movedItem = self.pinnedApps.remove(at: fromIndex)
                    self.pinnedApps.insert(movedItem, at: toIndex)
                }

                print(
                    "📌 Reordered pinned items: moved '\(self.pinnedApps[toIndex].name)' from index \(fromIndex) to \(toIndex)"
                )
            }
        }
    }
}

// MARK: - Two Finger Swipe Gesture Helper
struct TwoFingerSwipeGestureView: NSViewRepresentable {
    let onSwipeUp: () -> Void
    let onSwipeDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = SwipeDetectorView()
        view.onSwipeUp = onSwipeUp
        view.onSwipeDown = onSwipeDown
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? SwipeDetectorView {
            view.onSwipeUp = onSwipeUp
            view.onSwipeDown = onSwipeDown
        }
    }

    class SwipeDetectorView: NSView {
        var onSwipeUp: (() -> Void)?
        var onSwipeDown: (() -> Void)?

        private var accumulatedDeltaY: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // Make this view able to receive scroll events but NOT block clicks
            self.wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { false }

        // Don't block mouse clicks - pass them through
        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }

        override func scrollWheel(with event: NSEvent) {
            let deltaX = abs(event.scrollingDeltaX)
            let deltaY = abs(event.scrollingDeltaY)

            // ALWAYS pass through horizontal scroll immediately (for pinned apps scrolling)
            // Only intercept vertical swipes for switching modes
            if deltaX > deltaY {
                super.scrollWheel(with: event)
                return
            }

            // Only handle vertical swipes
            // Reset accumulator on new gesture
            if event.phase == .began {
                accumulatedDeltaY = 0
            }

            // Accumulate delta during gesture
            if event.phase == .changed || event.phase == .began {
                accumulatedDeltaY += event.scrollingDeltaY
            }

            // Check accumulated delta when gesture ends
            if event.phase == .ended {
                if abs(accumulatedDeltaY) > 30 {
                    if accumulatedDeltaY > 0 {
                        onSwipeDown?()
                    } else {
                        onSwipeUp?()
                    }
                    return
                }
            }

            // Pass through if not handled
            super.scrollWheel(with: event)
        }
    }
}

// Preview commented out due to init parameter changes
// #Preview {
//     LauncherView(onClose: {})
//         .frame(width: 600)
//         .padding()
// }

// MARK: - Right-click interceptor (NSViewRepresentable)

/// Transparent overlay that captures both left-click and right-click, calling separate closures.
/// Left-click fires on mouseUp (matching native button feel). Right-click fires on rightMouseDown.
/// Using a single NSView for both prevents the overlay from silently eating left-clicks.
struct RightClickInterceptor: NSViewRepresentable {
    var onLeftClick: (() -> Void)? = nil
    var onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> RCIHostView {
        let v = RCIHostView()
        v.onLeftClick = onLeftClick
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ v: RCIHostView, context: Context) {
        v.onLeftClick = onLeftClick
        v.onRightClick = onRightClick
    }

    class RCIHostView: NSView {
        var onLeftClick: (() -> Void)?
        var onRightClick: ((CGPoint) -> Void)?

        override func mouseUp(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            if bounds.contains(pt) { onLeftClick?() }
        }

        override func rightMouseDown(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            onRightClick?(CGPoint(x: pt.x, y: bounds.height - pt.y))
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - D Logo Button

/// Notification/profile button. Supports three logo styles (D logo, Apple, system photo).
/// Right-click shows a pill-style logo switcher. Hover shows a 3D tilt + neon glow for the D logo.
struct DLogoButton<PopoverContent: View>: View {
    let action: () -> Void
    let isPresented: Binding<Bool>
    let hasUnread: Bool
    let profileImage: NSImage?
    @ViewBuilder let popoverContent: () -> PopoverContent

    @ObservedObject private var settings = AppSettings.shared
    @State private var isHovering = false
    @State private var showLogoMenu = false

    private var isDLogo: Bool { settings.dockLogoStyle == "d_logo" }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            logoContent
                .frame(width: 36, height: 36)
                .opacity(hasUnread ? 1.0 : 0.82)
                .overlay {
                    // Single NSView handles left click (opens notification panel)
                    // and right click (opens logo switcher) — avoids the overlay blocking issue.
                    RightClickInterceptor(
                        onLeftClick: action,
                        onRightClick: { _ in
                            withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                                showLogoMenu.toggle()
                            }
                        }
                    )
                }

            if showLogoMenu {
                logoSwitcherPillMenu
                    .offset(x: 8, y: 44)
                    .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .topTrailing)))
                    .zIndex(100)
            }
        }
        .scaleEffect(isHovering && isDLogo ? 1.13 : 1.0)
        .rotation3DEffect(
            .degrees(isHovering && isDLogo ? 18 : 0),
            axis: (x: 0.6, y: 1.0, z: 0.0),
            perspective: 0.45
        )
        .shadow(
            color: isDLogo
                ? Color(red: 0.50, green: 0.15, blue: 1.0).opacity(isHovering ? 0.85 : 0.40)
                : .clear,
            radius: isHovering ? 14 : 7
        )
        .animation(.spring(response: 0.26, dampingFraction: 0.60), value: isHovering)
        .onHover { isHovering = $0 }
        .popover(isPresented: isPresented, arrowEdge: .top) { popoverContent() }
    }

    @ViewBuilder
    private var logoSwitcherPillMenu: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 300, height: 300)
                .offset(x: -150, y: -44)
                .onTapGesture {
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                        showLogoMenu = false
                    }
                }

            VStack(spacing: 4) {
                logoPillButton(
                    icon: settings.dockLogoStyle == "d_logo" ? "checkmark.circle.fill" : "circle",
                    title: "D Logo",
                    selected: settings.dockLogoStyle == "d_logo"
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        settings.dockLogoStyle = "d_logo"
                    }
                }
                logoPillButton(
                    icon: settings.dockLogoStyle == "apple" ? "checkmark.circle.fill" : "circle",
                    title: "Apple Logo",
                    selected: settings.dockLogoStyle == "apple"
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        settings.dockLogoStyle = "apple"
                    }
                }
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 5)
            .frame(width: 200)
        }
    }

    @ViewBuilder
    private func logoPillButton(
        icon: String, title: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                showLogoMenu = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.75))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.06))
                Capsule()
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.12),
                        lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var logoContent: some View {
        switch settings.dockLogoStyle {
        case "apple":
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom))
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.65), .white.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                Capsule().strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5).blur(radius: 3)
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.90))
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.pulse.byLayer, options: .repeat(.continuous))
            }
        default:  // "d_logo"
            dLogoView
        }
    }

    @ViewBuilder
    private var dLogoView: some View {
        ContextDockNodeGlyph(
            size: 34,
            animated: isHovering || hasUnread,
            color: .black
        )
    }
}

// MARK: - Glass Background

/// NSVisualEffectView wrapped in SwiftUI — provides true wallpaper-blur glass effect.
/// Rounded corners are applied at the AppKit layer so they clip the blur itself.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    /// Explicit dark flag passed from SwiftUI environment — enables reactive system-appearance updates.
    /// When nil, falls back to settings + NSApp.effectiveAppearance (non-reactive in system mode).
    var isDark: Bool? = nil
    @ObservedObject private var settings = AppSettings.shared

    func makeNSView(context: Context) -> NSVisualEffectView {
        let ve = NSVisualEffectView()
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        configure(ve)
        return ve
    }

    func updateNSView(_ ve: NSVisualEffectView, context: Context) {
        ve.blendingMode = .behindWindow
        configure(ve)
    }

    private func configure(_ ve: NSVisualEffectView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        ve.alphaValue = settings.launcherWindowOpacity
        ve.layer?.cornerRadius = cornerRadius
        ve.layer?.masksToBounds = true
        guard let rootLayer = ve.layer else { return }

        let dark = resolvedIsDark

        // ── Material: thin frosted glass (hudWindow) in dark, popover in light ──
        // hudWindow matches SwiftUI .ultraThinMaterial in dark mode — translucent, not heavy.
        ve.material = dark ? .hudWindow : .popover
        switch settings.appearanceMode {
        case "light": ve.appearance = NSAppearance(named: .aqua)
        case "dark": ve.appearance = NSAppearance(named: .darkAqua)
        default: ve.appearance = nil
        }

        // ── Base fill: subtle, lets the blur show through (like ultraThinMaterial) ──
        let base = existingLayer(named: "baseFill", in: rootLayer) {
            let layer = CALayer()
            layer.name = "baseFill"
            rootLayer.insertSublayer(layer, at: 0)
            return layer
        }
        base.cornerRadius = cornerRadius
        base.frame = ve.bounds
        base.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        base.backgroundColor =
            dark
            ? CGColor(red: 0.035, green: 0.04, blue: 0.055, alpha: 0.76)  // dark glass tint
            : CGColor(red: 0.92, green: 0.925, blue: 0.94, alpha: 0.86)  // light: denser + dimmer for contrast

        // ── Gradient overlay: top-bright → bottom-faded, matches input field style ──
        let grad = existingGradientLayer(named: "gradientOverlay", in: rootLayer) {
            let layer = CAGradientLayer()
            layer.name = "gradientOverlay"
            rootLayer.addSublayer(layer)
            return layer
        }
        grad.isHidden = ve.bounds.height <= 0
        grad.cornerRadius = cornerRadius
        grad.frame = ve.bounds
        grad.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        grad.colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: dark ? 0.045 : 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: dark ? 0.005 : 0.01),
        ]
        grad.startPoint = CGPoint(x: 0.5, y: 0)  // top
        grad.endPoint = CGPoint(x: 0.5, y: 1)  // bottom

        // ── Border ring ──
        let border = existingLayer(named: "borderRing", in: rootLayer) {
            let layer = CALayer()
            layer.name = "borderRing"
            rootLayer.addSublayer(layer)
            return layer
        }
        border.cornerRadius = cornerRadius
        border.frame = ve.bounds
        border.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        border.borderColor =
            dark
            ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.14)
            : CGColor(red: 0, green: 0, blue: 0, alpha: 0.08)
        border.borderWidth = 1.0
    }

    private func existingLayer(named name: String, in rootLayer: CALayer, create: () -> CALayer)
        -> CALayer
    {
        if let layer = rootLayer.sublayers?.first(where: { $0.name == name }) {
            return layer
        }
        return create()
    }

    private func existingGradientLayer(
        named name: String,
        in rootLayer: CALayer,
        create: () -> CAGradientLayer
    ) -> CAGradientLayer {
        if let layer = rootLayer.sublayers?.first(where: { $0.name == name }) as? CAGradientLayer {
            return layer
        }
        rootLayer.sublayers?.filter { $0.name == name }.forEach { $0.removeFromSuperlayer() }
        return create()
    }

    private var resolvedIsDark: Bool {
        if let isDark { return isDark }
        if settings.appearanceMode == "light" { return false }
        if settings.appearanceMode == "dark" { return true }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// Thin wrapper that reads @Environment(\.colorScheme) and passes isDark to GlassBackground,
/// making it reactive to system appearance changes without requiring a manual isDark parameter.
private struct AdaptiveGlassBackground: View {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        GlassBackground(cornerRadius: cornerRadius, isDark: colorScheme == .dark)
    }
}

struct FocusRingSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    // Run exactly once — re-running every render reassigns isBordered/drawsBackground
    // on the live NSTextField which causes it to resign first responder on macOS.
    func updateNSView(_ view: NSView, context: Context) {
        guard !context.coordinator.didSuppress else { return }
        context.coordinator.didSuppress = true
        DispatchQueue.main.async {
            var root = view.superview
            for _ in 0..<6 {
                guard let current = root else { break }
                suppressFocusRings(in: current)
                root = current.superview
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var didSuppress = false
    }

    private func suppressFocusRings(in view: NSView) {
        if view.focusRingType != .none { view.focusRingType = .none }
        if let textField = view as? NSTextField {
            if textField.focusRingType != .none { textField.focusRingType = .none }
            if textField.isBordered { textField.isBordered = false }
            if textField.drawsBackground { textField.drawsBackground = false }
        }
        view.subviews.forEach { suppressFocusRings(in: $0) }
    }
}

extension View {
    /// Wraps a view in the full glass-pill container: NSVisualEffectView blur + gradient + border stroke.
    func glassContainer(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(AdaptiveGlassBackground(cornerRadius: cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - View helpers

extension View {
    /// Applies a transform only when an optional value is non-nil.
    @ViewBuilder
    func ifLet<T, V: View>(_ value: T?, transform: (Self, T) -> V) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - App launch usage tracker (for ghost-text completion ranking)

final class AppLaunchTracker {
    static let shared = AppLaunchTracker()
    private let key = "appLaunchCounts"

    private var counts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    func record(bundleId: String) {
        var c = counts
        c[bundleId, default: 0] += 1
        counts = c
    }

    func count(for bundleId: String) -> Int {
        counts[bundleId] ?? 0
    }
}

// MARK: - App icon dominant color extraction

extension NSImage {
    /// Returns the dominant (average) color of the image by sampling to 1×1.
    var dominantSwiftUIColor: SwiftUI.Color {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return SwiftUI.Color.accentColor
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel = [UInt8](repeating: 0, count: 4)
        guard
            let ctx = CGContext(
                data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return SwiftUI.Color.accentColor }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = CGFloat(pixel[0]) / 255
        let g = CGFloat(pixel[1]) / 255
        let b = CGFloat(pixel[2]) / 255
        let nsColor =
            NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
            .usingColorSpace(.deviceRGB) ?? NSColor(red: r, green: g, blue: b, alpha: 1)
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        var alp: CGFloat = 0
        nsColor.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alp)
        // Keep the sampled app color subtle; opacity is applied by the caller.
        let softened = NSColor(
            hue: hue,
            saturation: min(sat * 0.75, 0.55),
            brightness: min(max(bri, 0.35), 0.85),
            alpha: 1
        )
        return SwiftUI.Color(softened)
    }
}

// MARK: - NSSharingServicePicker dismiss coordinator

/// Lightweight Obj-C object that acts as NSSharingServicePickerDelegate.
/// Calls `onDismiss` after the user picks a service or cancels the picker.
final class SharePickerCoordinator: NSObject, NSSharingServicePickerDelegate {
    static var key = 0  // used as objc_setAssociatedObject key
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    func sharingServicePicker(
        _ picker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        DispatchQueue.main.async { self.onDismiss() }
    }
}
