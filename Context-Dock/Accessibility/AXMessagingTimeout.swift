//
//  AXMessagingTimeout.swift
//  Context-Dock
//
//  Bounds how long an accessibility call may block.
//
//  Every AXUIElement read is a synchronous IPC round-trip into the target app, and
//  with no timeout set the system default is measured in seconds. An app that is
//  launching, redrawing, or flooding its own text view (Terminal doing all three at
//  once is the reliable way to see it) answers late, and any read we do on the main
//  thread freezes the whole dock for exactly as long as that app takes. Bounding the
//  wait turns a beachball into a missed field, which every reader here already
//  handles — they all treat a failed read as "not available".
//

import ApplicationServices

enum AXMessagingTimeout {

    /// Process-wide ceiling. Generous enough for a deep menu-tree traversal, far below
    /// the point where a user believes the app has hung.
    static let processDefault: Float = 2.0

    /// For reads on (or blocking) the main thread — window title, focused role,
    /// selection. A frame is 16 ms; nothing here is worth a visible stall.
    static let interactive: Float = 0.4

    /// Sets the default for every accessibility message this process sends.
    /// Call once, early in launch.
    static func installProcessDefault() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), processDefault)
    }

    static func apply(_ seconds: Float, to element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }
}
