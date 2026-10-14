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


// MARK: - D Logo Button


// MARK: - Glass Background

/// NSVisualEffectView wrapped in SwiftUI — provides true wallpaper-blur glass effect.
/// Rounded corners are applied at the AppKit layer so they clip the blur itself.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    /// Explicit dark flag passed from SwiftUI environment — enables reactive system-appearance updates.
    /// When nil, falls back to settings + NSApp.effectiveAppearance (non-reactive in system mode).
    var isDark: Bool? = nil
    @ObservedObject private var settings = AppSettings.shared

    func makeNSView(context: Context) -> NSView {
        // macOS 26 Liquid Glass — the same material as Spotlight. Pure glass at 0% darkness.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.wantsLayer = true
            configureGlass(glass)
            return glass
        }
        let ve = NSVisualEffectView()
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        configure(ve)
        return ve
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            configureGlass(glass)
            return
        }
        if let ve = view as? NSVisualEffectView {
            ve.blendingMode = .behindWindow
            configure(ve)
        }
    }

    @available(macOS 26.0, *)
    private func configureGlass(_ glass: NSGlassEffectView) {
        glass.cornerRadius = cornerRadius
        let dark = resolvedIsDark
        glass.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        // `glassDarkness` is stored as 0...1. Use it as extra lens strength:
        // light mode stays neutral silver glass, dark mode gets smoked glass.
        let d = max(0, min(1, settings.glassDarkness))
        if dark {
            glass.tintColor = NSColor.black.withAlphaComponent(0.18 + d * 0.34)
        } else {
            glass.tintColor = NSColor(calibratedWhite: 0.86, alpha: 0.10 + d * 0.12)
        }
    }

    private func configure(_ ve: NSVisualEffectView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        ve.layer?.cornerRadius = cornerRadius
        ve.layer?.masksToBounds = true
        guard let rootLayer = ve.layer else { return }

        let dark = resolvedIsDark

        // ── Material: white liquid glass in light, smoked glass in dark ──
        ve.material = dark ? .hudWindow : .popover
        ve.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

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
            ? CGColor(red: 0.02, green: 0.024, blue: 0.03, alpha: 0.34)
            : CGColor(red: 0.78, green: 0.80, blue: 0.80, alpha: 0.28)

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
            CGColor(red: 1, green: 1, blue: 1, alpha: dark ? 0.05 : 0.18),
            CGColor(red: 1, green: 1, blue: 1, alpha: dark ? 0.006 : 0.035),
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
            ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.18)
            : CGColor(red: 1, green: 1, blue: 1, alpha: 0.42)
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


struct InlineCompletionApplier: NSViewRepresentable {
    let typedText: String
    let completionText: String?
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard isActive,
            let completionText,
            !typedText.isEmpty,
            completionText.count > typedText.count,
            completionText.lowercased().hasPrefix(typedText.lowercased())
        else { return }

        DispatchQueue.main.async {
            guard let window = view.window ?? NSApp.keyWindow,
                let textView = window.firstResponder as? NSTextView
            else { return }

            let typedLength = (typedText as NSString).length
            let completionLength = (completionText as NSString).length
            guard completionLength > typedLength else { return }

            let current = textView.string
            let selected = textView.selectedRange()
            let desiredSelection = NSRange(location: typedLength, length: completionLength - typedLength)
            if current == completionText, selected == desiredSelection { return }
            guard current == typedText || current == completionText else { return }

            textView.string = completionText
            textView.setSelectedRange(desiredSelection)
        }
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
