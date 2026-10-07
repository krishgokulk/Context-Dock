// WindowLayoutRegions.swift
// Context-Dock
//
// Where each native window layout puts the window — one source for the Dock's row icon
// (`windowLayoutPreviewImage`) and the Corner board's preview (`WindowLayoutPreview`).
// Moved here from a private Dock function so the Corner reuses it rather than copying it.

import CoreGraphics

extension WindowManagementService.Command {
    /// Normalized regions (top-left origin) the layout moves the window into. Quarters is
    /// four cells; a two-window arrangement's first region is the scoped app, its second the
    /// other app sharing the desktop. Fill, full screen and restore take the whole screen.
    var layoutRegions: [CGRect] {
        switch self {
        case .left: return [CGRect(x: 0, y: 0, width: 0.5, height: 1)]
        case .right: return [CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .top: return [CGRect(x: 0, y: 0, width: 1, height: 0.5)]
        case .bottom: return [CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
        case .topLeft: return [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)]
        case .topRight: return [CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)]
        case .bottomLeft: return [CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)]
        case .bottomRight: return [CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .center: return [CGRect(x: 0.18, y: 0.16, width: 0.64, height: 0.68)]
        case .quarters:
            return [
                CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            ]
        // Two-window arrangements: first region is the scoped app, second is the
        // other app sharing the desktop.
        case .leftAndRight:
            return [
                CGRect(x: 0, y: 0, width: 0.5, height: 1),
                CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
            ]
        case .rightAndLeft:
            return [
                CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                CGRect(x: 0, y: 0, width: 0.5, height: 1),
            ]
        case .topAndBottom:
            return [
                CGRect(x: 0, y: 0, width: 1, height: 0.5),
                CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
            ]
        case .bottomAndTop:
            return [
                CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
                CGRect(x: 0, y: 0, width: 1, height: 0.5),
            ]
        default:
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]  // fill / fullscreen / restore
        }
    }
}
