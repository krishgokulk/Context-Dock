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

        static let defaultVisibleCommands: [Command] = [
            .left, .right, .fill, .center, .minimize, .fullScreen,
        ]

        var title: String {
            switch self {
            case .minimize: return "Minimize"
            case .zoom: return "Zoom"
            case .fill: return "Fill"
            case .center: return "Centre"
            case .left: return "Left"
            case .right: return "Right"
            case .top: return "Top"
            case .bottom: return "Bottom"
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            case .leftAndRight: return "Left & Right"
            case .rightAndLeft: return "Right & Left"
            case .topAndBottom: return "Top & Bottom"
            case .bottomAndTop: return "Bottom & Top"
            case .quarters: return "Quarters"
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
    }

    private struct WindowFrameSnapshot {
        let window: AXUIElement
        let frame: CGRect
    }

    private struct WorkspaceLayoutWindow {
        let pid: pid_t
        let window: AXUIElement
        let order: Int
    }

    private struct OnScreenWindowSignature {
        let pid: pid_t
        let bounds: CGRect
        let order: Int
    }

    private var previousFrames: [pid_t: [WindowFrameSnapshot]] = [:]

    private init() {}

    func matchingCommands(query: String) -> [Command] {
        let normalized = normalize(query)
        guard !normalized.isEmpty else { return Command.defaultVisibleCommands }
        return Command.allCases.filter { command in
            command.searchTerms.contains { normalize($0).contains(normalized) }
                || normalized.contains(normalize(command.title))
        }
    }

    func handlesMenuPath(_ path: [String]) -> Bool {
        let normalized = path.map(normalize)
        guard normalized.contains("window"), let title = normalized.last else { return false }
        if title.contains("full screen") || title.contains("fullscreen") {
            return true
        }
        return command(for: title, path: normalized) != nil
    }

    func executeIfSupported(path: [String], sourceApp: NSRunningApplication) -> Bool {
        let normalized = path.map(normalize)
        guard let title = normalized.last else { return false }
        if title.contains("full screen") || title.contains("fullscreen") {
            return toggleFullScreen(
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
        switch command {
        case .minimize:
            return true
        case .zoom:
            return toggleZoom(pid: pid, appName: appName)
        case .center:
            return centerFrontmostWindow(pid: pid, appName: appName)
        case .fill, .left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight:
            guard let transform = singleWindowFrame(for: command) else { return false }
            return resizeFrontmostWindow(pid: pid, appName: appName, normalizedFrame: transform)
        case .leftAndRight, .rightAndLeft, .topAndBottom, .bottomAndTop, .quarters:
            return arrangeWindows(command, pid: pid, appName: appName)
        case .restorePreviousSize:
            return restorePreviousFrames(pid: pid, appName: appName)
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

    private func singleWindowFrame(for command: Command) -> ((CGRect) -> CGRect)? {
        switch command {
        case .fill: return fullFrame
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

    private func centerFrontmostWindow(pid: pid_t, appName: String) -> Bool {
        guard let window = frontmostEligibleWindow(pid: pid),
            let screen = screen(for: window)
        else { return showNoWindow(appName) }
        rememberFrame(window, pid: pid)
        let visible = screen.visibleFrame
        let centered = visible.insetBy(dx: visible.width * 0.10, dy: visible.height * 0.10)
        return apply(centered, to: window)
    }

    private func arrangeWindows(_ command: Command, pid: pid_t, appName: String) -> Bool {
        var windows = workspaceEligibleWindows(preferredPID: pid)
        if isPairArrangement(command) {
            windows = preferredPairArrangementWindows(windows, preferredPID: pid)
        }
        guard !windows.isEmpty else { return showNoWindow(appName) }
        rememberWorkspaceFrames(windows)

        var changed = false
        if isPairArrangement(command) {
            guard let first = windows.first,
                let targetScreen = screen(for: first.window) ?? NSScreen.main
            else { return false }
            let frames = arrangementFrames(
                for: command,
                windowCount: windows.count,
                in: targetScreen.visibleFrame
            )
            for (item, frame) in zip(windows, frames) {
                changed = apply(frame, to: item.window) || changed
                AXUIElementPerformAction(item.window, kAXRaiseAction as CFString)
            }
            return changed
        }

        for screenWindows in workspaceWindowsGroupedByScreen(windows) {
            guard let first = screenWindows.first,
                let targetScreen = screen(for: first.window) ?? NSScreen.main
            else { continue }
            let frames = arrangementFrames(
                for: command,
                windowCount: screenWindows.count,
                in: targetScreen.visibleFrame
            )
            for (item, frame) in zip(screenWindows, frames) {
                changed = apply(frame, to: item.window) || changed
                AXUIElementPerformAction(item.window, kAXRaiseAction as CFString)
            }
        }
        return changed
    }

    private func isPairArrangement(_ command: Command) -> Bool {
        switch command {
        case .leftAndRight, .rightAndLeft, .topAndBottom, .bottomAndTop:
            return true
        default:
            return false
        }
    }

    private func preferredPairArrangementWindows(
        _ windows: [WorkspaceLayoutWindow],
        preferredPID: pid_t
    ) -> [WorkspaceLayoutWindow] {
        guard let primary = windows.first(where: { $0.pid == preferredPID }) ?? windows.first else {
            return []
        }
        guard windows.count > 1 else { return [primary] }

        let primaryScreenKey = screenKey(for: primary.window)
        let sameScreen = windows.filter {
            !sameWindow($0.window, primary.window) && screenKey(for: $0.window) == primaryScreenKey
        }
        let anyScreen = windows.filter { !sameWindow($0.window, primary.window) }

        let companion =
            sameScreen.first(where: { $0.pid != primary.pid })
            ?? sameScreen.first
            ?? anyScreen.first(where: { $0.pid != primary.pid })
            ?? anyScreen.first

        guard let companion else { return [primary] }
        return [primary, companion]
    }

    private func workspaceEligibleWindows(preferredPID: pid_t) -> [WorkspaceLayoutWindow] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let currentDesktopWindows = currentDesktopWindowSignatures()
        let signaturesByPID = Dictionary(grouping: currentDesktopWindows, by: \.pid)
        var seenPIDs = Set<pid_t>()
        let orderedPIDs = currentDesktopWindows.compactMap { signature -> pid_t? in
            guard seenPIDs.insert(signature.pid).inserted else { return nil }
            return signature.pid
        }

        return orderedPIDs.flatMap { pid -> [WorkspaceLayoutWindow] in
            guard
                let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.processIdentifier == pid && !$0.isTerminated
                }),
                app.bundleIdentifier != ownBundleID,
                let appSignatures = signaturesByPID[pid],
                !appSignatures.isEmpty
            else { return [] }

            return eligibleWindows(pid: pid)
                .compactMap { window -> WorkspaceLayoutWindow? in
                    guard
                        let order = matchingCurrentDesktopWindowOrder(
                            window,
                            signatures: appSignatures
                        )
                    else { return nil }
                    return WorkspaceLayoutWindow(pid: pid, window: window, order: order)
                }
                .sorted {
                    if $0.pid == preferredPID, $1.pid != preferredPID { return true }
                    if $1.pid == preferredPID, $0.pid != preferredPID { return false }
                    return $0.order < $1.order
                }
        }
    }

    private func currentDesktopWindowSignatures() -> [OnScreenWindowSignature] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        return infoList.enumerated().compactMap { index, info -> OnScreenWindowSignature? in
            guard
                let ownerPIDValue = info[kCGWindowOwnerPID as String] as? NSNumber,
                let layerValue = info[kCGWindowLayer as String] as? NSNumber,
                layerValue.intValue == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.width >= 120,
                bounds.height >= 80
            else { return nil }

            if let alphaValue = info[kCGWindowAlpha as String] as? NSNumber,
                alphaValue.doubleValue <= 0
            {
                return nil
            }
            return OnScreenWindowSignature(
                pid: ownerPIDValue.int32Value,
                bounds: bounds,
                order: index
            )
        }
    }

    private func matchingCurrentDesktopWindowOrder(
        _ window: AXUIElement,
        signatures: [OnScreenWindowSignature]
    ) -> Int? {
        guard let frame = frame(of: window) else { return nil }
        let nativeFrame = nativeFrame(of: window)
        return signatures.first { signature in
            framesMatch(frame, signature.bounds)
                || nativeFrame.map { framesMatch($0, signature.bounds) } == true
        }?.order
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if framesEqual(lhs, rhs) { return true }

        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return false }
        let lhsArea = lhs.width * lhs.height
        let rhsArea = rhs.width * rhs.height
        let smallerArea = max(1, min(lhsArea, rhsArea))
        return (intersection.width * intersection.height) / smallerArea > 0.9
    }

    private func framesEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 8
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func workspaceWindowsGroupedByScreen(
        _ windows: [WorkspaceLayoutWindow]
    ) -> [[WorkspaceLayoutWindow]] {
        Dictionary(grouping: windows) { item -> String in
            screenKey(for: item.window)
        }
        .values
        .map { $0.sorted { $0.order < $1.order } }
    }

    private func screenKey(for window: AXUIElement) -> String {
        let frame = screen(for: window)?.frame ?? NSScreen.main?.frame ?? .zero
        return "\(frame.minX):\(frame.minY):\(frame.width):\(frame.height)"
    }

    private func sameWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    private func rememberWorkspaceFrames(_ windows: [WorkspaceLayoutWindow]) {
        for (pid, items) in Dictionary(grouping: windows, by: \.pid) {
            rememberFrames(items.map(\.window), pid: pid)
        }
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
                count: count, columns: 2, in: visibleFrame, reverseColumns: false)
        case .rightAndLeft:
            return tiledFrames(
                count: count, columns: 2, in: visibleFrame, reverseColumns: true)
        case .topAndBottom:
            return tiledFrames(
                count: count, rows: 2, in: visibleFrame, reverseRows: false)
        case .bottomAndTop:
            return tiledFrames(
                count: count, rows: 2, in: visibleFrame, reverseRows: true)
        case .quarters:
            return quarterArrangementFrames(count: count, in: visibleFrame)
        default:
            return []
        }
    }

    private func quarterArrangementFrames(count: Int, in visibleFrame: CGRect) -> [CGRect] {
        if count > 4 {
            return tiledFrames(count: count, columns: 2, in: visibleFrame)
        }
        switch max(1, count) {
        case 1:
            return [fullFrame(visibleFrame)]
        case 2:
            return [leftFrame(visibleFrame), rightFrame(visibleFrame)]
        case 3:
            return [
                leftFrame(visibleFrame),
                topRightFrame(visibleFrame),
                bottomRightFrame(visibleFrame),
            ]
        default:
            return [
                topLeftFrame(visibleFrame),
                topRightFrame(visibleFrame),
                bottomLeftFrame(visibleFrame),
                bottomRightFrame(visibleFrame),
            ]
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
        let focused = focusedWindow(pid: pid)
        let currentIndex =
            focused.flatMap { focused in
                windows.firstIndex(where: { CFEqual($0, focused) })
            } ?? 0
        let next = unminimize(windows[(currentIndex + 1) % windows.count])
        AXUIElementSetAttributeValue(next, kAXMainAttribute as CFString, kCFBooleanTrue)
        return AXUIElementPerformAction(next, kAXRaiseAction as CFString) == .success
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
        // Some apps (e.g. Image Playground) error on the size-settable query while position
        // is still movable. Requiring BOTH queries to succeed wrongly rejected those windows
        // ("no window found"). Treat a failed query as "not settable" instead of rejecting,
        // and keep the window if EITHER position or size can be set.
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(
            window, kAXPositionAttribute as CFString, &positionSettable)
        _ = AXUIElementIsAttributeSettable(
            window, kAXSizeAttribute as CFString, &sizeSettable)
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
        let target = snapped(frame)
        var point = CGPoint(x: target.minX, y: desktopTop - target.maxY)
        var size = target.size
        guard let pointValue = AXValueCreate(.cgPoint, &point),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }

        // With AXEnhancedUserInterface enabled (Electron and friends turn it on
        // when an AX client connects), macOS animates frame writes and applies
        // them against stale geometry — disable it while setting the frame.
        let appElement = applicationElement(for: window)
        let hadEnhancedUI = appElement.map(disableEnhancedUserInterface) ?? false
        defer {
            if hadEnhancedUI, let appElement {
                AXUIElementSetAttributeValue(
                    appElement, Self.enhancedUserInterfaceAttribute as CFString, kCFBooleanTrue)
            }
        }

        // Apps clamp a grow when the new size would overflow from the window's
        // current origin, and clamp a move while the old size still overflows
        // the destination — so always set size -> position -> size, then verify
        // strictly and retry until the frame settles.
        var succeeded = false
        for attempt in 0..<3 {
            let sizeResult = AXUIElementSetAttributeValue(
                window, kAXSizeAttribute as CFString, sizeValue)
            let positionResult = AXUIElementSetAttributeValue(
                window, kAXPositionAttribute as CFString, pointValue)
            let settleResult = AXUIElementSetAttributeValue(
                window, kAXSizeAttribute as CFString, sizeValue)
            succeeded = succeeded || positionResult == .success || sizeResult == .success
                || settleResult == .success
            if let actual = nativeFrame(of: window), framesEqual(actual, target) {
                break
            }
            if attempt < 2 { usleep(25_000) }
        }
        // Some apps apply AX size changes asynchronously and still report the
        // old frame above; push the target once more after they have settled.
        if succeeded, let actual = nativeFrame(of: window), !framesEqual(actual, target) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self else { return }
                let hadEnhancedUI = appElement.map(self.disableEnhancedUserInterface) ?? false
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
                if hadEnhancedUI, let appElement {
                    AXUIElementSetAttributeValue(
                        appElement, Self.enhancedUserInterfaceAttribute as CFString, kCFBooleanTrue)
                }
            }
        }
        if succeeded {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        return succeeded
    }

    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    private func applicationElement(for window: AXUIElement) -> AXUIElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid > 0 else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    private func disableEnhancedUserInterface(_ appElement: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement, Self.enhancedUserInterfaceAttribute as CFString, &value) == .success,
            (value as? Bool) == true
        else { return false }
        AXUIElementSetAttributeValue(
            appElement, Self.enhancedUserInterfaceAttribute as CFString, kCFBooleanFalse)
        return true
    }

    private func snapped(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX.rounded(.toNearestOrAwayFromZero),
            y: frame.minY.rounded(.toNearestOrAwayFromZero),
            width: max(120, frame.width.rounded(.toNearestOrAwayFromZero)),
            height: max(80, frame.height.rounded(.toNearestOrAwayFromZero))
        )
    }

    private func showNoWindow(_ appName: String) -> Bool {
        AppToast.show("No \(appName) window found", icon: "macwindow", tint: .orange)
        return false
    }

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "and" }
            .joined(separator: " ")
    }

    // AX coordinates have their origin at the top-left of the primary screen (screens[0]),
    // not at the top of the tallest screen in the arrangement.
    private var desktopTop: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private var fullFrame: (CGRect) -> CGRect { { $0 } }
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
