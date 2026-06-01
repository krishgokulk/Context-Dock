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
            var terms = [title, rawValue, "window", "window manager"]
            switch self {
            case .left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight:
                terms.append("move resize")
            case .leftAndRight, .rightAndLeft, .topAndBottom, .bottomAndTop, .quarters:
                terms.append("arrange")
            default:
                break
            }
            return terms
        }

        var isDirectGeometryLayout: Bool {
            switch self {
            case .fill, .center, .left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft,
                .bottomRight, .leftAndRight, .rightAndLeft, .topAndBottom, .bottomAndTop, .quarters:
                return true
            default:
                return false
            }
        }
    }

    private struct WindowFrameSnapshot {
        let window: AXUIElement
        let frame: CGRect
    }

    private var previousFrames: [pid_t: [WindowFrameSnapshot]] = [:]

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
            return executeFullScreen(
                preferredPath: path,
                pid: sourceApp.processIdentifier,
                appName: sourceApp.localizedName ?? "App"
            )
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
        if command.isDirectGeometryLayout {
            return executeDirectGeometryLayout(command, pid: pid, appName: appName)
        }
        if command == .restorePreviousSize {
            return restorePreviousFrames(pid: pid, appName: appName)
        }
        if let path = nativeMenuPath(for: command),
            AXMenuReader.shared.clickMenuItem(path: path, in: pid)
        {
            return true
        }

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
            return false
        case .rightAndLeft:
            return false
        case .topAndBottom:
            return false
        case .bottomAndTop:
            return false
        case .quarters:
            return false
        case .restorePreviousSize:
            return false
        case .fullScreen:
            return executeFullScreen(preferredPath: nil, pid: pid, appName: appName)
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

    private func nativeMenuPath(for command: Command) -> [String]? {
        switch command {
        case .zoom:
            return ["Window", "Zoom"]
        case .bringAllToFront:
            return ["Window", "Bring All to Front"]
        case .switchWindow:
            return ["Window", "Switch Window..."]
        case .minimize, .fill, .center, .left, .right, .top, .bottom, .topLeft, .topRight,
            .bottomLeft, .bottomRight, .leftAndRight, .rightAndLeft, .topAndBottom, .bottomAndTop,
            .quarters, .restorePreviousSize, .fullScreen:
            return nil
        }
    }

    private func executeDirectGeometryLayout(
        _ command: Command,
        pid: pid_t,
        appName: String
    ) -> Bool {
        if let transform = singleWindowFrame(for: command) {
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: transform)
        }
        return arrangeWindows(command, pid: pid, appName: appName)
    }

    private func singleWindowFrame(for command: Command) -> ((CGRect) -> CGRect)? {
        switch command {
        case .fill: return fullFrame
        case .center: return centerFrame
        case .left: return leftFrame
        case .right: return rightFrame
        case .top: return topFrame
        case .bottom: return bottomFrame
        case .topLeft: return topLeftFrame
        case .topRight: return topRightFrame
        case .bottomLeft: return bottomLeftFrame
        case .bottomRight: return bottomRightFrame
        default: return nil
        }
    }

    private func resizeFrontmostWindow(
        pid: pid_t,
        appName: String,
        normalizedFrame: (CGRect) -> CGRect
    ) -> Bool {
        guard let window = frontmostEligibleWindow(pid: pid), let screen = screen(for: window) else {
            return showNoWindow(appName)
        }
        rememberFrame(window, pid: pid)
        return apply(normalizedFrame(screen.visibleFrame), to: window)
    }

    private func arrangeWindows(_ command: Command, pid: pid_t, appName: String) -> Bool {
        let windows = eligibleWindows(pid: pid)
        guard !windows.isEmpty else { return showNoWindow(appName) }
        guard let screen = screen(for: windows[0]) ?? NSScreen.main else {
            return showNoWindow(appName)
        }
        rememberFrames(windows, pid: pid)
        let frames = arrangementFrames(
            for: command,
            windowCount: windows.count,
            in: screen.visibleFrame
        )
        var changed = false
        for (window, frame) in zip(windows, frames) {
            changed = apply(frame, to: window) || changed
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        return changed
    }

    private func arrangementFrames(
        for command: Command,
        windowCount: Int,
        in visibleFrame: CGRect
    ) -> [CGRect] {
        let count = max(1, windowCount)
        switch command {
        case .leftAndRight:
            return tiledFrames(
                count: count, columns: min(2, count), in: visibleFrame, reverseColumns: false)
        case .rightAndLeft:
            return tiledFrames(
                count: count, columns: min(2, count), in: visibleFrame, reverseColumns: true)
        case .topAndBottom:
            return tiledFrames(
                count: count, rows: min(2, count), in: visibleFrame, reverseRows: false)
        case .bottomAndTop:
            return tiledFrames(
                count: count, rows: min(2, count), in: visibleFrame, reverseRows: true)
        case .quarters:
            return tiledFrames(count: count, columns: min(2, count), in: visibleFrame)
        default:
            return []
        }
    }

    private func tiledFrames(
        count: Int,
        columns requestedColumns: Int? = nil,
        rows requestedRows: Int? = nil,
        in visibleFrame: CGRect,
        reverseColumns: Bool = false,
        reverseRows: Bool = false
    ) -> [CGRect] {
        let columns = max(
            1,
            requestedColumns ?? Int(ceil(Double(count) / Double(max(1, requestedRows ?? 1))))
        )
        let rows = max(1, requestedRows ?? Int(ceil(Double(count) / Double(columns))))
        let width = visibleFrame.width / CGFloat(columns)
        let height = visibleFrame.height / CGFloat(rows)
        return (0..<count).map { index in
            let naturalColumn = index % columns
            let naturalRow = index / columns
            let column = reverseColumns ? columns - naturalColumn - 1 : naturalColumn
            let row = reverseRows ? rows - naturalRow - 1 : naturalRow
            return CGRect(
                x: visibleFrame.minX + CGFloat(column) * width,
                y: visibleFrame.minY + CGFloat(rows - row - 1) * height,
                width: width,
                height: height
            )
        }
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

    private func executeFullScreen(
        preferredPath: [String]?,
        pid: pid_t,
        appName: String
    ) -> Bool {
        let fallbackPaths = [
            ["View", "Exit Full Screen"],
            ["Window", "Exit Full Screen"],
            ["View", "Enter Full Screen"],
            ["Window", "Enter Full Screen"],
            ["Window", "Toggle Full Screen"],
        ]
        var candidates: [[String]] = []
        if let preferredPath, !preferredPath.isEmpty {
            candidates.append(preferredPath)
        }
        candidates.append(contentsOf: fallbackPaths)

        var seen = Set<String>()
        for path in candidates {
            let key = path.map(normalize).joined(separator: ">")
            guard seen.insert(key).inserted else { continue }
            if AXMenuReader.shared.clickMenuItem(path: path, in: pid) {
                return true
            }
        }
        return toggleFullScreen(pid: pid, appName: appName)
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

    private func restorePreviousFrames(pid: pid_t, appName: String) -> Bool {
        guard let snapshots = previousFrames.removeValue(forKey: pid), !snapshots.isEmpty else {
            return showNoWindow(appName)
        }
        var changed = false
        for snapshot in snapshots {
            changed = apply(snapshot.frame, to: snapshot.window) || changed
        }
        return changed
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

    private func eligibleWindows(pid: pid_t) -> [AXUIElement] {
        let focused = focusedWindow(pid: pid)
        return windows(pid: pid)
            .filter(isEligibleLayoutWindow)
            .map(unminimize)
            .sorted { lhs, rhs in
                let lhsFocused = focused.map { CFEqual(lhs, $0) } ?? false
                let rhsFocused = focused.map { CFEqual(rhs, $0) } ?? false
                if lhsFocused != rhsFocused { return lhsFocused }
                guard let lhsFrame = nativeFrame(of: lhs), let rhsFrame = nativeFrame(of: rhs) else {
                    return lhsFocused
                }
                if abs(lhsFrame.minY - rhsFrame.minY) > 1 {
                    return lhsFrame.minY > rhsFrame.minY
                }
                return lhsFrame.minX < rhsFrame.minX
            }
    }

    private func isEligibleLayoutWindow(_ window: AXUIElement) -> Bool {
        if let role = stringAttribute(kAXRoleAttribute, of: window), role != kAXWindowRole {
            return false
        }
        if let subrole = stringAttribute(kAXSubroleAttribute, of: window),
            ["AXSheet", "AXFloatingWindow", "AXSystemDialog"].contains(subrole)
        {
            return false
        }
        guard let frame = frame(of: window), frame.width >= 120, frame.height >= 80 else {
            return false
        }
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                window, kAXPositionAttribute as CFString, &positionSettable) == .success,
            AXUIElementIsAttributeSettable(
                window, kAXSizeAttribute as CFString, &sizeSettable) == .success
        else { return false }
        return positionSettable.boolValue || sizeSettable.boolValue
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func frontmostWindow(pid: pid_t) -> AXUIElement? {
        if let focused = focusedWindow(pid: pid) {
            return unminimize(focused)
        }
        return windows(pid: pid).first.map(unminimize)
    }

    private func frontmostEligibleWindow(pid: pid_t) -> AXUIElement? {
        eligibleWindows(pid: pid).first
    }

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &ref) == .success,
                let ref
            {
                return unsafeBitCast(ref, to: AXUIElement.self)
            }
        }
        return nil
    }

    private func unminimize(_ window: AXUIElement) -> AXUIElement {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        return window
    }

    private func rememberFrame(_ window: AXUIElement, pid: pid_t) {
        guard previousFrames[pid] == nil, let frame = nativeFrame(of: window) else { return }
        previousFrames[pid] = [WindowFrameSnapshot(window: window, frame: frame)]
    }

    private func rememberFrames(_ windows: [AXUIElement], pid: pid_t) {
        guard previousFrames[pid] == nil else { return }
        let snapshots = windows.compactMap { window -> WindowFrameSnapshot? in
            guard let frame = nativeFrame(of: window) else { return nil }
            return WindowFrameSnapshot(window: window, frame: frame)
        }
        if !snapshots.isEmpty {
            previousFrames[pid] = snapshots
        }
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

    private func showNativeActionUnavailable(_ command: Command, appName: String) -> Bool {
        AppToast.show(
            "\(command.title) unavailable for \(appName)",
            icon: "rectangle.split.2x1",
            tint: .orange
        )
        return false
    }

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "and" }
            .joined(separator: " ")
    }

    private var desktopTop: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? 0
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
