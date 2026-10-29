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
                && screen.auxiliaryTopLeftArea != nil
                && screen.auxiliaryTopRightArea != nil
        }
        return false
    }

    /// The exact rect of the notch in screen coordinates (origin bottom-left).
    static func notchRect(on screen: NSScreen) -> CGRect {
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            let width = max(160, right.minX - left.maxX)
            let height = screen.safeAreaInsets.top
            let x = left.maxX
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

    /// Standard dimensions for the Dynamic Island presentation at rest and when expanded.
    static let islandRestingWidth: CGFloat = 210
    static let islandRestingHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 18
}
