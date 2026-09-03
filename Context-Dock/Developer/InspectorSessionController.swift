#if DEBUG
import AppKit
import Foundation

/// The one owner of Inspect Mode.
///
/// Everything expensive lives behind `isEnabled`: the event monitors, the registry's change
/// emission, the overlay windows and the detail panel. While Inspect Mode is off this object
/// holds nothing and costs nothing — which is the entire reason adding a developer tool does
/// not quietly undo the pre-release audit's finding about always-on mouse-moved delivery.
///
/// It also never touches `acceptsMouseMovedEvents` on a product window. Pointer position comes
/// from this object's own monitors via `NSEvent.mouseLocation`, so no product window's event
/// behaviour changes when Inspect Mode is enabled.
@MainActor
final class InspectorSessionController {
    static let shared = InspectorSessionController()

    private let state = InspectorSessionState()
    private let registry: InspectRegistry
    private let bindings: InspectRootBindings

    private var overlays: [InspectWindowID: InspectorOverlayController] = [:]
    private var monitors: [Any] = []
    private var detailPanel: InspectorDetailPanelController?

    var isEnabled: Bool { state.isEnabled }

    init(
        registry: InspectRegistry = .shared,
        bindings: InspectRootBindings = .shared
    ) {
        self.registry = registry
        self.bindings = bindings
    }

    func toggle() {
        state.isEnabled ? disable() : enable()
    }

    func enable() {
        guard state.enable() else { return }
        registry.emitsChanges = true
        installMonitors()
        reconcile()
    }

    func disable() {
        guard state.disable() else { return }
        registry.emitsChanges = false
        removeMonitors()
        for overlay in overlays.values { overlay.tearDown() }
        overlays.removeAll()
        detailPanel?.close()
        detailPanel = nil
    }

    /// Screen point → the window under it → that window's root space → the registry.
    ///
    /// This is the only place a hit is decided, and it uses the P0 converter verbatim. There is
    /// no fallback path that approximates with SwiftUI `.global` or screen arithmetic: without
    /// a live window/root binding there is simply no hit.
    func resolveHit(atScreenPoint screenPoint: CGPoint) -> InspectRegistration? {
        for windowID in registry.windowIDs() {
            guard let binding = bindings.binding(for: windowID), binding.window.isVisible else {
                continue
            }

            let rootPoint = InspectCoordinateConverter.windowRootPoint(
                fromScreenPoint: screenPoint,
                window: binding.window,
                rootView: binding.rootView
            )
            if let hit = registry.hitTest(rootPoint: rootPoint, in: windowID) {
                return hit
            }
        }
        return nil
    }

    // MARK: - Monitors

    private func installMonitors() {
        removeMonitors()

        let localMoved = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleHover()
            return event
        }
        let globalMoved = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.handleHover()
        }
        // Only the Option-click Inspect Mode actually handles is swallowed. Every other click
        // is returned unchanged, so product surfaces behave exactly as they did before.
        let clicked = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.modifierFlags.contains(.option) else { return event }
            return self.handleOptionClick() ? nil : event
        }
        let keyed = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }  // Escape
            return self.handleEscape() ? nil : event
        }

        monitors = [localMoved, globalMoved, clicked, keyed].compactMap { $0 }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    // MARK: - Event handling

    private func handleHover() {
        let hit = resolveHit(atScreenPoint: NSEvent.mouseLocation)
        guard state.hover(hit?.key) else { return }
        redraw()
    }

    /// Returns whether the click was consumed. An Option-click inside Inspect Mode always is —
    /// including one outside every region, which is how a lock is released without the click
    /// also reaching a product control underneath.
    private func handleOptionClick() -> Bool {
        let hit = resolveHit(atScreenPoint: NSEvent.mouseLocation)
        if state.lock(hit?.key) {
            if hit == nil {
                detailPanel?.close()
                detailPanel = nil
            }
            redraw()
        }
        return true
    }

    private func handleEscape() -> Bool {
        switch state.escape() {
        case .ignored:
            return false
        case .clearedLock:
            detailPanel?.close()
            detailPanel = nil
            redraw()
            return true
        case .disabled:
            // `escape()` already flipped the flag, so finish the teardown directly rather than
            // through `disable()`, whose idempotence guard would refuse a second time.
            registry.emitsChanges = false
            removeMonitors()
            for overlay in overlays.values { overlay.tearDown() }
            overlays.removeAll()
            detailPanel?.close()
            detailPanel = nil
            return true
        }
    }

    // MARK: - Reconciliation and drawing

    private func reconcile() {
        guard state.isEnabled else { return }

        let liveKeys = Set(
            registry.windowIDs().flatMap { registry.registrations(in: $0).map(\.key) }
        )
        state.reconcile(liveKeys: liveKeys)

        let eligible = eligibleWindowIDs()

        for (windowID, overlay) in overlays where !eligible.contains(windowID) {
            overlay.tearDown()
            overlays.removeValue(forKey: windowID)
        }
        for windowID in eligible where overlays[windowID] == nil {
            guard let binding = bindings.binding(for: windowID) else { continue }
            overlays[windowID] = InspectorOverlayController(
                windowID: windowID, owner: binding.window, rootView: binding.rootView
            )
        }

        redraw()
    }

    /// A window can appear or vanish between two pointer moves. Reconciling on demand keeps
    /// overlays honest without a timer or a subscription; `revision` stays the seam a later
    /// phase may use.
    private func reconcileIfNeeded() {
        guard eligibleWindowIDs() != Set(overlays.keys) else { return }
        reconcile()
    }

    private func eligibleWindowIDs() -> Set<InspectWindowID> {
        Set(registry.windowIDs().filter { bindings.binding(for: $0) != nil })
    }

    private func redraw() {
        reconcileIfNeeded()

        let activeKey = state.lockedKey ?? state.hoveredKey
        let active = activeKey.flatMap { registry.registration(for: $0) }
        let isLocked = state.lockedKey != nil

        for (windowID, overlay) in overlays {
            overlay.followOwnerFrame()
            guard let active, active.key.windowID == windowID else {
                overlay.show(highlight: nil)
                continue
            }
            let ordinal = registry.ordinal(for: active.key)
            overlay.show(
                highlight: InspectorHighlight(
                    frameInWindowRoot: active.frameInWindowRoot,
                    label: ordinal.map { "\(active.key.id.rawValue) #\($0)" } ?? active.key.id.rawValue,
                    isLocked: isLocked
                )
            )
        }

        if let active, isLocked {
            presentDetailPanel(for: active)
        }
    }

    private func presentDetailPanel(for registration: InspectRegistration) {
        let panel = detailPanel ?? InspectorDetailPanelController()
        detailPanel = panel
        panel.present(
            registration: registration,
            ordinal: registry.ordinal(for: registration.key),
            isExactRegion: isExactRegion(registration)
        )
    }

    /// P0 records no descendant coverage, so this is a statement about registry precision —
    /// "nothing more specific is registered inside this" — and never a claim about which
    /// SwiftUI leaf is under the pixel.
    private func isExactRegion(_ registration: InspectRegistration) -> Bool {
        let siblings = registry.registrations(in: registration.key.windowID)
        return !siblings.contains { other in
            other.key != registration.key
                && registration.frameInWindowRoot.contains(other.frameInWindowRoot)
        }
    }
}
#endif
