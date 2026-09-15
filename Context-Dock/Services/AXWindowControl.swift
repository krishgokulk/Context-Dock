import AppKit
import ApplicationServices
import Foundation

/// Where a window lands when its thumbnail is dropped on the screen.
///
/// Top-left-origin coordinates throughout, as AX reports them. Edges tile — left quarter of
/// the screen to the left half, right quarter to the right half, the top band to the whole
/// screen — and anywhere else moves the window so its top-left sits under the pointer, kept
/// on the screen it was dropped on.
enum WindowPlacement {
    static let edgeFraction: CGFloat = 0.25
    static let topFraction: CGFloat = 0.15

    static func frame(drop: CGPoint, screen: CGRect, size: CGSize) -> CGRect {
        if drop.y < screen.minY + screen.height * topFraction {
            return screen
        }
        if drop.x < screen.minX + screen.width * edgeFraction {
            return CGRect(
                x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
        }
        if drop.x > screen.maxX - screen.width * edgeFraction {
            return CGRect(
                x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
        }
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
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
            == .success,
            let windows = value as? [AXUIElement]
        else { return nil }
        return windows.first { element in
            var number: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "_AXWindowNumber" as CFString, &number)
                == .success,
                let n = number as? Int
            else { return false }
            return CGWindowID(n) == windowID
        }
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
        guard let element = element(windowID: windowID, bundleID: bundleID) else { return false }
        var origin = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
            == .success
        let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            == .success
        return moved && resized
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
}
