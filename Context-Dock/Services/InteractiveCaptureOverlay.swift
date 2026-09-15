import AppKit

/// A custom screen-capture picker that switches mode automatically by what's under the
/// cursor — no Space key. Hover a window → that window is highlighted and a click captures
/// it; move over the empty desktop → a crosshair appears and a drag selects a custom area.
/// Esc cancels. macOS's own `screencapture -i` ties the window/area toggle to the Space key;
/// this reimplements the selection UI, then hands the final target to `screencapture`
/// (`-l<windowID>` for a window, `-R x,y,w,h` for an area) so the actual capture is native.
@MainActor
final class InteractiveCaptureOverlay {
    private var window: NSWindow?
    private var completion: ((URL?) -> Void)?
    private var retain: InteractiveCaptureOverlay?

    /// Present the picker. `completion` gets the captured PNG URL, or nil if cancelled.
    static func capture(completion: @escaping (URL?) -> Void) {
        let overlay = InteractiveCaptureOverlay()
        overlay.retain = overlay  // keep alive for the duration of the interaction
        overlay.completion = completion
        overlay.present()
    }

    // Union of all screens, in AppKit global (bottom-left) coordinates.
    private var unionFrame: NSRect {
        NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
    }

    /// Height of the primary display (the one whose AppKit origin is (0,0)) — the reference
    /// for converting between Core Graphics (top-left) and AppKit (bottom-left) coordinates.
    static var primaryDisplayHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
    }

    private func present() {
        let frame = unionFrame
        let win = OverlayWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.acceptsMouseMovedEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = CaptureOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        view.owner = self
        win.contentView = view
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)
        NSCursor.crosshair.push()
    }

    /// Convert a Core Graphics global rect (top-left origin) into the overlay view's
    /// coordinate space (the view fills the union-frame window).
    func viewRect(fromCG cg: CGRect) -> NSRect {
        let origin = unionFrame.origin
        let nsGlobalY = Self.primaryDisplayHeight - cg.maxY
        return NSRect(
            x: cg.minX - origin.x, y: nsGlobalY - origin.y,
            width: cg.width, height: cg.height)
    }

    /// Frontmost normal window under the given CG cursor point, excluding our own app and
    /// non-window layers (menu bar, dock, our overlay). Returns its id + CG bounds.
    func windowUnderCursor(_ cursorCG: CGPoint) -> (id: CGWindowID, rect: CGRect)? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }
        for info in infos {  // front-to-back order
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != myPID,
                let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if rect.contains(cursorCG), rect.width > 20, rect.height > 20,
                let id = info[kCGWindowNumber as String] as? CGWindowID
            {
                return (id, rect)
            }
        }
        return nil
    }

    /// Tear down the overlay, then run the native capture for the chosen target.
    func finish(windowID: CGWindowID?, areaCG: CGRect?) {
        NSCursor.pop()
        window?.orderOut(nil)
        window = nil
        let completion = self.completion
        self.completion = nil

        guard windowID != nil || areaCG != nil else {
            completion?(nil)
            retain = nil
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-dock-shot-\(UUID().uuidString).png")
        var args: [String] = ["-x", "-o"]
        if let windowID {
            args += ["-l", "\(windowID)"]
        } else if let a = areaCG {
            args += [
                "-R",
                "\(Int(a.minX)),\(Int(a.minY)),\(Int(a.width)),\(Int(a.height))",
            ]
        }
        args.append(url.path)

        Task.detached { [retain] in
            // Small delay so the overlay is fully off-screen before the capture fires.
            try? await Task.sleep(nanoseconds: 120_000_000)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = args
            var producedURL: URL? = nil
            do {
                try process.run()
                process.waitUntilExit()
                if FileManager.default.fileExists(atPath: url.path),
                    (try? Data(contentsOf: url))?.isEmpty == false
                {
                    producedURL = url
                }
            } catch {
                producedURL = nil
            }
            await MainActor.run {
                completion?(producedURL)
            }
            _ = retain  // released when this closure ends
        }
        retain = nil
    }

    func cancel() {
        finish(windowID: nil, areaCG: nil)
    }
}

/// Borderless window that can still become key so it receives Esc / key events.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the dim + highlight and drives the pointer-based mode switching.
private final class CaptureOverlayView: NSView {
    weak var owner: InteractiveCaptureOverlay?

    private var hoverWindow: (id: CGWindowID, rect: CGRect)?
    private var isDraggingArea = false
    private var dragStartCG: CGPoint = .zero
    private var dragCurrentCG: CGPoint = .zero
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    private func cursorCG() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isDraggingArea else { return }
        hoverWindow = owner?.windowUnderCursor(cursorCG())
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if hoverWindow == nil {
            // Over the empty desktop → start an area drag.
            isDraggingArea = true
            dragStartCG = cursorCG()
            dragCurrentCG = dragStartCG
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingArea else { return }
        dragCurrentCG = cursorCG()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingArea {
            isDraggingArea = false
            let rect = normalizedCGRect(dragStartCG, dragCurrentCG)
            if rect.width >= 5, rect.height >= 5 {
                owner?.finish(windowID: nil, areaCG: rect)
            } else {
                owner?.cancel()
            }
        } else if let hover = hoverWindow {
            // Click on a highlighted window → capture that window.
            owner?.finish(windowID: hover.id, areaCG: nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            owner?.cancel()
        }
    }

    private func normalizedCGRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        let accent = NSColor.controlAccentColor

        if isDraggingArea {
            let cg = normalizedCGRect(dragStartCG, dragCurrentCG)
            let r = owner?.viewRect(fromCG: cg) ?? .zero
            // Punch a clear hole so the selected area shows through.
            NSColor.clear.setFill()
            r.fill(using: .copy)
            accent.setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 2
            path.stroke()
        } else if let hover = hoverWindow, let r = owner?.viewRect(fromCG: hover.rect) {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            accent.withAlphaComponent(0.14).setFill()
            r.fill()
            accent.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2.5
            path.stroke()
        }
    }
}
