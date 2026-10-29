// ScreenNotchMetrics.swift
// Context-Dock
//
// Hardware and virtual notch geometry for macOS displays.
// Supports the physical camera notch on modern MacBooks (MacBook Pro 14"/16", MacBook Air)
// and provides a seamless top-center Dynamic Island fallback for external displays.

import AppKit
import CoreGraphics
import Foundation

enum ScreenNotchMetrics {
    /// Detects if the screen has a physical hardware notch.
    static func hasHardwareNotch(on screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }

    /// Returns the notch height for the given screen (e.g. 32-38pt), or 0 if the screen has no notch.
    static func notchHeight(on screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *), hasHardwareNotch(on: screen) {
            return screen.safeAreaInsets.top
        }
        return 0
    }

    /// The exact rect of the notch in screen coordinates (origin bottom-left).
    static func notchRect(on screen: NSScreen) -> CGRect {
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            let height = screen.safeAreaInsets.top
            let width: CGFloat
            let x: CGFloat
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                x = left.maxX
                width = max(160, right.minX - left.maxX)
            } else {
                width = 200
                x = (screen.frame.width - width) / 2 + screen.frame.minX
            }
            let y = screen.frame.maxY - height
            return CGRect(x: x, y: y, width: width, height: height)
        }
        // Fallback for displays without physical notch (external monitors, older Macs):
        // Anchored flush to the top-center along the menu bar.
        let defaultWidth: CGFloat = 190
        let defaultHeight: CGFloat = 34
        let x = (screen.frame.width - defaultWidth) / 2 + screen.frame.minX
        let y = screen.frame.maxY - defaultHeight
        return CGRect(x: x, y: y, width: defaultWidth, height: defaultHeight)
    }

    /// Resolves the current active screen where the pointer or dock is located.
    static var activeScreen: NSScreen {
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    /// The notch height for the currently active screen.
    static var currentNotchHeight: CGFloat {
        notchHeight(on: activeScreen)
    }

    /// Standard dimensions for the Dynamic Island presentation at rest and when expanded.
    static let islandRestingWidth: CGFloat = 210
    static let islandRestingHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 18
}
