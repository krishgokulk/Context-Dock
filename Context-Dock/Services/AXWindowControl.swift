import AppKit
import ApplicationServices
import Foundation
import SwiftUI

/// The CoreGraphics window id for an accessibility element. Private, unavoidable: there is no
/// public way to tell which AX window is the one ScreenCaptureKit listed, and without it a
/// window can be drawn and highlighted but never moved.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>)
    -> AXError

/// Why a drop did nothing. Debug builds only, and it is written for one reason: an AX write
/// that fails returns an error nobody sees, so "I dropped it and nothing happened" has no
/// evidence attached. Off in Release; the file is local and holds window ids and app names.
enum SnapDebug {
    #if DEBUG
    private static let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Context-Dock/snap-drop.log")

    static func log(_ line: String) {
        guard let url else { return }
        let stamped = "\(Date().formatted(date: .omitted, time: .standard))  \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? stamped.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    #else
    static func log(_ line: String) {}
    #endif
}

/// Where a window lands when its thumbnail is dropped on the screen.
///
/// Top-left-origin coordinates throughout, as AX reports them. Edges tile — left quarter of
/// the screen to the left half, right quarter to the right half, the top band to the whole
/// screen — and anywhere else moves the window so its top-left sits under the pointer, kept
/// on the screen it was dropped on.
enum WindowPlacement {
    static let edgeFraction: CGFloat = 0.25
    static let topFraction: CGFloat = 0.15

    enum Zone: Equatable {
        case top, left, right, free
    }

    static func zone(for drop: CGPoint, screen: CGRect) -> Zone {
        if drop.y < screen.minY + screen.height * topFraction { return .top }
        if drop.x < screen.minX + screen.width * edgeFraction { return .left }
        if drop.x > screen.maxX - screen.width * edgeFraction { return .right }
        return .free
    }

    /// The area a zone stands for, for drawing it while the drag is in flight.
    static func zoneFrame(_ zone: Zone, screen: CGRect) -> CGRect? {
        switch zone {
        case .top: return screen
        case .left:
            return CGRect(
                x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .right:
            return CGRect(
                x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
        case .free: return nil
        }
    }

    static func frame(drop: CGPoint, screen: CGRect, size: CGSize) -> CGRect {
        if let tiled = zoneFrame(zone(for: drop, screen: screen), screen: screen) { return tiled }
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let x = min(max(drop.x, screen.minX), screen.maxX - width)
        let y = min(max(drop.y, screen.minY), screen.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The few things the strip does to another app's window, by the window id ScreenCaptureKit
/// reports. Each finds the AX element carrying that number and acts on it; nothing here
/// guesses at "the frontmost window".
enum AXWindowControl {
    static func element(windowID: CGWindowID, bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        return element(windowID: windowID, pid: app.processIdentifier)
    }

    static func element(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
            == .success,
            let windows = value as? [AXUIElement]
        else {
            SnapDebug.log("element: app \(pid) returned no AXWindows")
            return nil
        }

        // 1. The CoreGraphics window number for an AX element, which is what every window
        //    manager uses. `_AXWindowNumber` (below) is not published by every app, and when
        //    it is missing the old code silently matched nothing — every move became a no-op
        //    while the overlay still drew correctly, because the highlight never needs an
        //    element.
        if let match = windows.first(where: { axWindowID($0) == windowID }) {
            return match
        }
        // 2. The attribute form, for anything the private call refuses.
        if let match = windows.first(where: { element in
            var number: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "_AXWindowNumber" as CFString, &number)
                == .success, let n = number as? Int
            else { return false }
            return CGWindowID(n) == windowID
        }) {
            return match
        }
        // 3. Last resort: the window whose frame is the one CoreGraphics reports for this id.
        //    Two windows of one app can share a frame, so this is only reached when neither
        //    identifier worked at all.
        guard let bounds = cgFrame(windowID: windowID) else {
            SnapDebug.log("element: no id match and no CG bounds for \(windowID)")
            return nil
        }
        let match = windows.first { element in
            guard let frame = frame(of: element) else { return false }
            return abs(frame.minX - bounds.minX) <= 2 && abs(frame.minY - bounds.minY) <= 2
                && abs(frame.width - bounds.width) <= 2 && abs(frame.height - bounds.height) <= 2
        }
        SnapDebug.log("element: fell back to frame match for \(windowID) — \(match == nil ? "missed" : "hit")")
        return match
    }

    /// The CoreGraphics window id behind an AX element. Private, and the way this is done
    /// everywhere; absent it there is no reliable identity between what ScreenCaptureKit
    /// lists and what Accessibility can move.
    private static func axWindowID(_ element: AXUIElement) -> CGWindowID? {
        var id = CGWindowID(0)
        guard _AXUIElementGetWindow(element, &id) == .success else { return nil }
        return id
    }

    private static func cgFrame(windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
                as? [[String: Any]],
            let info = list.first,
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
            let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"]
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
            == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue,
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    static func raise(windowID: CGWindowID, bundleID: String) -> Bool {
        guard let element = element(windowID: windowID, bundleID: bundleID) else { return false }
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        return raised
    }

    /// The window's own close button, pressed — what ⌘W would do to it. The app decides what
    /// closing means (a document may ask to save); nothing here forces it.
    @discardableResult
    static func close(windowID: CGWindowID, bundleID: String) -> Bool {
        guard let element = element(windowID: windowID, bundleID: bundleID) else { return false }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button)
            == .success,
            let closeButton = button
        else { return false }
        return AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
            == .success
    }

    static func frame(windowID: CGWindowID, bundleID: String) -> CGRect? {
        guard let element = element(windowID: windowID, bundleID: bundleID) else { return nil }
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
            == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
                == .success,
            let positionValue, let sizeValue,
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Move and resize, in that order; a maximise that resized first would push the window off
    /// the screen before it moved back.
    @discardableResult
    static func place(windowID: CGWindowID, bundleID: String, frame: CGRect) -> Bool {
        guard let element = element(windowID: windowID, bundleID: bundleID) else {
            SnapDebug.log("place: NO ELEMENT for window \(windowID) of \(bundleID)")
            return false
        }
        return write(element: element, frame: frame, label: "\(bundleID) w\(windowID)")
    }

    /// The two writes, with their errors kept. A window that refuses to move returns an
    /// `AXError` nobody sees; without it, a refusal and a missing element are both just
    /// "nothing happened".
    @discardableResult
    static func write(element: AXUIElement, frame: CGRect, label: String) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }
        let moveError = AXUIElementSetAttributeValue(
            element, kAXPositionAttribute as CFString, positionValue)
        let sizeError = AXUIElementSetAttributeValue(
            element, kAXSizeAttribute as CFString, sizeValue)
        let after = self.frame(of: element).map { "\($0)" } ?? "unreadable"
        SnapDebug.log(
            "place: \(label) -> \(frame) move=\(moveError.rawValue) size=\(sizeError.rawValue) after=\(after)")
        return moveError == .success && sizeError == .success
    }

    /// AppKit's bottom-left screen point, as the top-left AX point plus the screen it is on
    /// (in AX coordinates too, and its visible area — the menu bar and the Dock are not
    /// places a window can be tiled into).
    static func axPointAndScreen(fromAppKit point: NSPoint) -> (point: CGPoint, screen: CGRect)? {
        guard let primary = NSScreen.screens.first else { return nil }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? primary
        let primaryHeight = primary.frame.height
        let visible = screen.visibleFrame
        let axScreen = CGRect(
            x: visible.minX, y: primaryHeight - visible.maxY,
            width: visible.width, height: visible.height)
        let axPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        return (axPoint, axScreen)
    }

    /// Move and resize any window by id and owner pid — for the windows adjusted around a
    /// snapped one, which belong to whatever app happens to own them.
    @discardableResult
    static func place(windowID: CGWindowID, pid: pid_t, frame: CGRect) -> Bool {
        guard let element = element(windowID: windowID, pid: pid) else {
            SnapDebug.log("place: NO ELEMENT for window \(windowID) of pid \(pid)")
            return false
        }
        return write(element: element, frame: frame, label: "pid \(pid) w\(windowID)")
    }

    struct OnScreenWindow: Equatable {
        let id: CGWindowID
        let pid: pid_t
        let frame: CGRect
    }

    /// The ordinary windows on `screen` right now, front to back, from every app but this
    /// one — what a snap has to fit around. CGWindowList bounds are top-left global
    /// coordinates, the same space AX uses.
    static func onScreenWindows(on screen: CGRect, excluding windowID: CGWindowID?) -> [OnScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID, id != windowID,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                (info[kCGWindowLayer as String] as? Int) == 0,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                w > 80, h > 80
            else { return nil }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            guard screen.intersects(frame) else { return nil }
            return OnScreenWindow(id: id, pid: pid, frame: frame)
        }
    }
}


// MARK: - Snap zone overlay

/// What a drag shows: the place the window will land, lit on the screen itself, and fainter
/// outlines of the windows that will move over to make room. No palette to aim at — where the
/// pointer is *is* the choice (`SnapLayout.zone(at:on:)`), the way every window manager the
/// user already has works. Nothing is moved until the hand lets go: an AX write per pointer
/// move stutters, and a window that rearranges under a live drag fights it.
@MainActor
final class SnapZoneOverlay {
    static let shared = SnapZoneOverlay()

    struct State: Equatable {
        var target: CGRect?
        var adjustments: [CGRect] = []
        var title: String = ""
    }

    private var panel: NSPanel?
    private var host: NSHostingView<ZoneView>?
    private var screenAppKit: NSRect = .zero
    private var screenAX: CGRect = .zero
    private var window: CGRect = .zero
    private var others: [AXWindowControl.OnScreenWindow] = []
    private(set) var hovered: SnapLayout?

    private init() {}

    func begin(at appKitPoint: NSPoint, windowID: CGWindowID, windowFrame: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) })
                ?? NSScreen.main,
            let placement = AXWindowControl.axPointAndScreen(fromAppKit: appKitPoint)
        else { return }
        screenAppKit = screen.visibleFrame
        screenAX = placement.screen
        window = windowFrame
        others = AXWindowControl.onScreenWindows(on: screenAX, excluding: windowID)
        let panel = self.panel ?? makePanel()
        panel.setFrame(screenAppKit, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        update(to: appKitPoint)
    }

    func update(to appKitPoint: NSPoint) {
        guard panel != nil, let placement = AXWindowControl.axPointAndScreen(fromAppKit: appKitPoint)
        else { return }
        hovered = SnapLayout.zone(at: placement.point, on: screenAX)
        var state = State()
        if let hovered {
            state.title = hovered.title
            state.target = hovered.frame(on: screenAX, window: window)
                .offsetBy(dx: -screenAX.minX, dy: -screenAX.minY)
            state.adjustments = moves(for: hovered).map { move in
                let other = others.first { $0.id == move.id }?.frame ?? .zero
                return move.layout.frame(on: screenAX, window: other)
                    .offsetBy(dx: -screenAX.minX, dy: -screenAX.minY)
            }
        }
        host?.rootView = ZoneView(state: state)
    }

    /// What a drop did, which the caller needs to tell apart: nothing to snap to is an
    /// ordinary move, but a window Accessibility cannot reach is a failure the user has to
    /// be told about — silently doing nothing is what made this look broken.
    enum Outcome: Equatable {
        case placed
        case noZone
        /// The app does not expose this window to Accessibility, so nothing can move it.
        case unreachable
    }

    /// Apply the hovered zone to the dragged window and arrange the others around it.
    ///
    /// The dragged window goes first and the arrangement only follows if it actually moved.
    /// The other way round rearranges the desktop for a snap that never happened — which is
    /// exactly what a window Safari does not expose produced: the complement slid into place
    /// beside nothing.
    @discardableResult
    func drop(windowID: CGWindowID, bundleID: String) -> Outcome {
        defer { end() }
        SnapDebug.log(
            "drop: window \(windowID) of \(bundleID) zone=\(hovered?.title ?? "none") "
                + "screenAX=\(screenAX) others=\(others.count)")
        guard let hovered else { return .noZone }
        guard AXWindowControl.place(
            windowID: windowID, bundleID: bundleID,
            frame: hovered.frame(on: screenAX, window: window))
        else {
            SnapDebug.log("drop: dragged window unreachable — arrangement skipped")
            return .unreachable
        }
        for move in moves(for: hovered) {
            guard let other = others.first(where: { $0.id == move.id }) else { continue }
            AXWindowControl.place(
                windowID: other.id, pid: other.pid,
                frame: move.layout.frame(on: screenAX, window: other.frame))
        }
        return .placed
    }

    func end() {
        panel?.orderOut(nil)
        hovered = nil
    }

    private func moves(for layout: SnapLayout) -> [SnapArrangement.Move] {
        SnapArrangement.adjustments(
            after: layout, others: others.map { .init(id: $0.id, frame: $0.frame) },
            screen: screenAX)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: ZoneView(state: State()))
        panel.contentView = host
        self.host = host
        return panel
    }

    struct ZoneView: View {
        let state: State

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                // The windows that will move over, first and fainter, then the one in hand.
                ForEach(Array(state.adjustments.enumerated()), id: \.offset) { _, rect in
                    highlight(rect, primary: false)
                }
                if let target = state.target {
                    highlight(target, primary: true)
                    Text(state.title)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                        .position(x: target.midX, y: target.midY)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.smooth(duration: 0.16), value: state)
        }

        private func highlight(_ rect: CGRect, primary: Bool) -> some View {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(primary ? 0.20 : 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            Color.accentColor.opacity(primary ? 0.95 : 0.4),
                            style: StrokeStyle(
                                lineWidth: primary ? 3 : 1.5, dash: primary ? [] : [8, 6])))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }
}
