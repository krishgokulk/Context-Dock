import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class WindowManagementService {
    static let shared = WindowManagementService()

    enum Command: String, CaseIterable, Identifiable {
        case minimize
        case zoom
        case fill
        case center
        case left
        case right
        case top
        case bottom
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
        case leftAndRight
        case rightAndLeft
        case topAndBottom
        case bottomAndTop
        case quarters
        case restorePreviousSize
        case fullScreen
        case bringAllToFront
        case switchWindow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .minimize: return "Minimize"
            case .zoom: return "Zoom"
            case .fill: return "Fill"
            case .center: return "Centre"
            case .left: return "Move & Resize: Left"
            case .right: return "Move & Resize: Right"
            case .top: return "Move & Resize: Top"
            case .bottom: return "Move & Resize: Bottom"
            case .topLeft: return "Move & Resize: Top Left"
            case .topRight: return "Move & Resize: Top Right"
            case .bottomLeft: return "Move & Resize: Bottom Left"
            case .bottomRight: return "Move & Resize: Bottom Right"
            case .leftAndRight: return "Arrange: Left & Right"
            case .rightAndLeft: return "Arrange: Right & Left"
            case .topAndBottom: return "Arrange: Top & Bottom"
            case .bottomAndTop: return "Arrange: Bottom & Top"
            case .quarters: return "Arrange: Quarters"
            case .restorePreviousSize: return "Return to Previous Size"
            case .fullScreen: return "Full Screen"
            case .bringAllToFront: return "Bring All to Front"
            case .switchWindow: return "Switch Window"
            }
        }

        var icon: String {
            switch self {
            case .minimize: return "minus.square"
            case .zoom, .fill: return "rectangle.inset.filled"
            case .center: return "rectangle.center.inset.filled"
            case .left, .right: return "rectangle.split.2x1"
            case .top, .bottom: return "rectangle.split.1x2"
            case .topLeft, .topRight, .bottomLeft, .bottomRight, .quarters:
                return "rectangle.split.2x2"
            case .leftAndRight, .rightAndLeft: return "rectangle.split.2x1"
            case .topAndBottom, .bottomAndTop: return "rectangle.split.1x2"
            case .restorePreviousSize: return "arrow.uturn.backward.square"
            case .fullScreen: return "arrow.up.left.and.arrow.down.right"
            case .bringAllToFront: return "square.stack.3d.up"
            case .switchWindow: return "macwindow.on.rectangle"
            }
        }

        var searchTerms: [String] {
            [title, rawValue, "window", "window manager", "move resize", "arrange"]
        }
    }

    private var previousFrames: [pid_t: CGRect] = [:]

    private init() {}

    func matchingCommands(query: String) -> [Command] {
        let normalized = normalize(query)
        guard !normalized.isEmpty else { return [] }
        return Command.allCases.filter { command in
            command.searchTerms.contains { normalize($0).contains(normalized) }
                || normalized.contains(normalize(command.title))
        }
    }

    func executeIfSupported(path: [String], sourceApp: NSRunningApplication) -> Bool {
        let normalized = path.map(normalize)
        guard let title = normalized.last else { return false }
        if title.contains("full screen") || title.contains("fullscreen") {
            return execute(.fullScreen, sourceApp: sourceApp)
        }
        guard normalized.contains("window") else { return false }
        guard let command = command(for: title, path: normalized) else { return false }
        return execute(command, sourceApp: sourceApp)
    }

    @discardableResult
    func execute(_ command: Command, sourceApp: NSRunningApplication) -> Bool {
        let pid = sourceApp.processIdentifier
        let appName = sourceApp.localizedName ?? "App"
        if command == .minimize {
            return minimizeWindows(pid: pid, appName: appName)
        }
        if sourceApp.isHidden { sourceApp.unhide() }
        sourceApp.activate(options: [.activateIgnoringOtherApps])

        switch command {
        case .minimize:
            return true
        case .zoom:
            return toggleZoom(pid: pid, appName: appName)
        case .fill:
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: fullFrame)
        case .center:
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: centerFrame)
        case .left:
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: leftFrame)
        case .right:
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: rightFrame)
        case .top:
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: topFrame)
        case .bottom:
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: bottomFrame)
        case .topLeft:
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: topLeftFrame)
        case .topRight:
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: topRightFrame)
        case .bottomLeft:
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: bottomLeftFrame)
        case .bottomRight:
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: bottomRightFrame)
        case .leftAndRight:
            return arrange(pid: pid, appName: appName, frames: [leftFrame, rightFrame])
        case .rightAndLeft:
            return arrange(pid: pid, appName: appName, frames: [rightFrame, leftFrame])
        case .topAndBottom:
            return arrange(pid: pid, appName: appName, frames: [topFrame, bottomFrame])
        case .bottomAndTop:
            return arrange(pid: pid, appName: appName, frames: [bottomFrame, topFrame])
        case .quarters:
            return arrange(
                pid: pid, appName: appName,
                frames: [topLeftFrame, topRightFrame, bottomLeftFrame, bottomRightFrame])
        case .restorePreviousSize:
            return restorePreviousFrame(pid: pid, appName: appName)
        case .fullScreen:
            return toggleFullScreen(pid: pid, appName: appName)
        case .bringAllToFront:
            return bringAllToFront(pid: pid, appName: appName)
        case .switchWindow:
            return switchWindow(pid: pid, appName: appName)
        }
    }

    private func command(for title: String, path _: [String]) -> Command? {
        if title == "minimize" || title == "minimise" { return .minimize }
        if title == "zoom" { return .zoom }
        if title == "fill" || title.contains("fill") { return .fill }
        if title == "centre" || title == "center" { return .center }
        if title == "left" { return .left }
        if title == "right" { return .right }
        if title == "top" { return .top }
        if title == "bottom" { return .bottom }
        if title == "top left" { return .topLeft }
        if title == "top right" { return .topRight }
        if title == "bottom left" { return .bottomLeft }
        if title == "bottom right" { return .bottomRight }
        if title == "left right" { return .leftAndRight }
        if title == "right left" { return .rightAndLeft }
        if title == "top bottom" { return .topAndBottom }
        if title == "bottom top" { return .bottomAndTop }
        if title == "quarters" { return .quarters }
        if title.contains("previous size") { return .restorePreviousSize }
        if title.contains("full screen") || title.contains("fullscreen") { return .fullScreen }
        if title == "bring all to front" { return .bringAllToFront }
        if title.hasPrefix("switch window") { return .switchWindow }
        return nil
    }

    private func resizeFrontmostWindow(
        pid: pid_t,
        appName: String,
        normalizedFrame: (CGRect) -> CGRect
    ) -> Bool {
        guard let window = frontmostWindow(pid: pid), let screen = screen(for: window) else {
            return showNoWindow(appName)
        }
        rememberFrame(window, pid: pid)
        return apply(normalizedFrame(screen.visibleFrame), to: window)
    }

    private func arrange(
        pid: pid_t,
        appName: String,
        frames: [(CGRect) -> CGRect]
    ) -> Bool {
        let windows = windows(pid: pid)
        guard let firstWindow = windows.first, let screen = screen(for: firstWindow) else {
            return showNoWindow(appName)
        }
        for (window, frameBuilder) in zip(windows, frames) {
            rememberFrame(window, pid: pid)
            _ = apply(frameBuilder(screen.visibleFrame), to: window)
        }
        return true
    }

    private func minimizeWindows(pid: pid_t, appName: String) -> Bool {
        let windows = windows(pid: pid)
        guard !windows.isEmpty else { return showNoWindow(appName) }
        var changed = false
        for window in windows {
            changed =
                AXUIElementSetAttributeValue(
                    window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
                || changed
        }
        return changed
    }

    private func toggleZoom(pid: pid_t, appName: String) -> Bool {
        guard let window = frontmostWindow(pid: pid) else { return showNoWindow(appName) }
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXZoomButtonAttribute as CFString, &buttonRef) == .success,
            let buttonRef
        else { return false }
        return AXUIElementPerformAction(
            unsafeBitCast(buttonRef, to: AXUIElement.self), kAXPressAction as CFString) == .success
    }

    private func toggleFullScreen(pid: pid_t, appName: String) -> Bool {
        guard let window = frontmostWindow(pid: pid) else { return showNoWindow(appName) }
        var value: CFTypeRef?
        let isFullScreen =
            AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success
            && (value as? Bool) == true
        return AXUIElementSetAttributeValue(
            window, "AXFullScreen" as CFString,
            (isFullScreen ? kCFBooleanFalse : kCFBooleanTrue)) == .success
    }

    private func bringAllToFront(pid: pid_t, appName: String) -> Bool {
        let windows = windows(pid: pid)
        guard !windows.isEmpty else { return showNoWindow(appName) }
        for window in windows {
            AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        return true
    }

    private func switchWindow(pid: pid_t, appName: String) -> Bool {
        let windows = windows(pid: pid)
        guard windows.count > 1 else { return showNoWindow(appName) }
        AXUIElementPerformAction(windows[1], kAXRaiseAction as CFString)
        return true
    }

    private func restorePreviousFrame(pid: pid_t, appName: String) -> Bool {
        guard let frame = previousFrames.removeValue(forKey: pid),
            let window = frontmostWindow(pid: pid)
        else { return showNoWindow(appName) }
        return apply(frame, to: window)
    }

    private func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
            == .success,
            let windows = windowsRef as? [AXUIElement]
        else { return [] }
        return windows
    }

    private func frontmostWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &ref) == .success,
                let ref
            {
                return unminimize(unsafeBitCast(ref, to: AXUIElement.self))
            }
        }
        return windows(pid: pid).first.map(unminimize)
    }

    private func unminimize(_ window: AXUIElement) -> AXUIElement {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        return window
    }

    private func rememberFrame(_ window: AXUIElement, pid: pid_t) {
        guard previousFrames[pid] == nil, let frame = nativeFrame(of: window) else { return }
        previousFrames[pid] = frame
    }

    private func nativeFrame(of window: AXUIElement) -> CGRect? {
        guard let frame = frame(of: window) else { return nil }
        return CGRect(
            x: frame.minX,
            y: desktopTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func screen(for window: AXUIElement) -> NSScreen? {
        guard let frame = nativeFrame(of: window) else { return NSScreen.main }
        return NSScreen.screens.max {
            intersectionArea($0.frame, frame) < intersectionArea($1.frame, frame)
        } ?? NSScreen.main
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
            == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let positionRef, let sizeRef
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func apply(_ frame: CGRect, to window: AXUIElement) -> Bool {
        var point = CGPoint(x: frame.minX, y: desktopTop - frame.maxY)
        var size = frame.size
        guard let pointValue = AXValueCreate(.cgPoint, &point),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }
        let positionResult = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, pointValue)
        let sizeResult = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, sizeValue)
        return positionResult == .success || sizeResult == .success
    }

    private func showNoWindow(_ appName: String) -> Bool {
        AppToast.show("No \(appName) window found", icon: "macwindow", tint: .orange)
        return false
    }

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var desktopTop: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private var fullFrame: (CGRect) -> CGRect { { $0 } }
    private var centerFrame: (CGRect) -> CGRect {
        { visible in visible.insetBy(dx: visible.width * 0.075, dy: visible.height * 0.075) }
    }
    private var leftFrame: (CGRect) -> CGRect {
        { CGRect(x: $0.minX, y: $0.minY, width: $0.width / 2, height: $0.height) }
    }
    private var rightFrame: (CGRect) -> CGRect {
        { CGRect(x: $0.midX, y: $0.minY, width: $0.width / 2, height: $0.height) }
    }
    private var topFrame: (CGRect) -> CGRect {
        { CGRect(x: $0.minX, y: $0.midY, width: $0.width, height: $0.height / 2) }
    }
    private var bottomFrame: (CGRect) -> CGRect {
        { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height / 2) }
    }
    private var topLeftFrame: (CGRect) -> CGRect {
        { CGRect(x: $0.minX, y: $0.midY, width: $0.width / 2, height: $0.height / 2) }
    }
    private var topRightFrame: (CGRect) -> CGRect {
        { CGRect(x: $0.midX, y: $0.midY, width: $0.width / 2, height: $0.height / 2) }
    }
    private var bottomLeftFrame: (CGRect) -> CGRect {
        { CGRect(x: $0.minX, y: $0.minY, width: $0.width / 2, height: $0.height / 2) }
    }
    private var bottomRightFrame: (CGRect) -> CGRect {
        { CGRect(x: $0.midX, y: $0.minY, width: $0.width / 2, height: $0.height / 2) }
    }
}
