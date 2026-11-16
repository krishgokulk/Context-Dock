// FluidSelection.swift
// Context-Dock
//
// Fluid, hardware-accelerated list selection motion matching Spotlight, Lumio, and Raycast.
// Uses a single persistent selection capsule that glides between rows via matchedGeometryEffect,
// incorporates an intentional pointer motion gate to prevent stationary hover jitter, and pulses
// leading row icons with a micro-zoom beat.

import AppKit
import SwiftUI

public enum FluidMotion {
    /// The gliding spring for the selection capsule.
    /// Perfectly damped to travel smoothly without oscillating or lagging behind rapid keystrokes.
    public static let selectionGlide = Animation.spring(response: 0.28, dampingFraction: 0.85)

    /// Micro-zoom spring for row icons when stepping into focus.
    public static let iconPop = Animation.spring(response: 0.22, dampingFraction: 0.65)

    /// Subtle scale factor for focused icons (1.08x).
    public static let iconScale: CGFloat = 1.08

    /// Subtle scale factor for focused selection pill (1.015x).
    public static let pillScale: CGFloat = 1.015
}

/// A mouse pointer gate that ignores hover events when the pointer is stationary.
///
/// When search results update or the user navigates with keyboard arrows, rows move or scroll
/// under the mouse pointer. Standard SwiftUI `.onHover` fires on whichever row happens to pass
/// under the pointer, stealing focus from the keyboard. `MouseGate` rejects hover unless the mouse
/// has physically moved by > 1.5 points.
@MainActor
public final class MouseGate {
    private var lastLocation: NSPoint = NSEvent.mouseLocation

    public init() {}

    /// Returns `true` only if the mouse pointer has physically moved since the last check.
    public func moved() -> Bool {
        let current = NSEvent.mouseLocation
        let dx = abs(current.x - lastLocation.x)
        let dy = abs(current.y - lastLocation.y)
        guard dx > 1.5 || dy > 1.5 else { return false }
        lastLocation = current
        return true
    }
}

/// The unified gliding selection capsule.
///
/// Instead of fading each row's background in and out independently (which causes two rows
/// to be half-lit during transitions or requires disabling animation entirely), a single
/// capsule is matched across the container's namespace and glides smoothly.
public struct FluidSelectionPill: ViewModifier {
    public let isSelected: Bool
    public let namespace: Namespace.ID
    public var cornerRadius: CGFloat
    public var paddingHorizontal: CGFloat
    public var fill: Color
    public var strokeColor: Color

    public init(
        isSelected: Bool,
        namespace: Namespace.ID,
        cornerRadius: CGFloat = 8,
        paddingHorizontal: CGFloat = 8,
        fill: Color = Color.primary.opacity(0.10),
        strokeColor: Color = Color.white.opacity(0.12)
    ) {
        self.isSelected = isSelected
        self.namespace = namespace
        self.cornerRadius = cornerRadius
        self.paddingHorizontal = paddingHorizontal
        self.fill = fill
        self.strokeColor = strokeColor
    }

    public func body(content: Content) -> some View {
        content
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(strokeColor, lineWidth: 0.5)
                        )
                        .padding(.horizontal, paddingHorizontal)
                        .matchedGeometryEffect(id: "fluidSelectionPill", in: namespace)
                }
            }
    }
}

/// Micro-zoom beat on a row's leading icon when it becomes focused.
public struct FluidIconZoom: ViewModifier {
    public let isFocused: Bool

    public init(isFocused: Bool) {
        self.isFocused = isFocused
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? FluidMotion.iconScale : 1.0)
            .animation(FluidMotion.iconPop, value: isFocused)
    }
}

extension View {
    public func fluidSelection(
        isSelected: Bool,
        namespace: Namespace.ID,
        cornerRadius: CGFloat = 8,
        paddingHorizontal: CGFloat = 8,
        fill: Color = Color.primary.opacity(0.10),
        strokeColor: Color = Color.white.opacity(0.12)
    ) -> some View {
        modifier(FluidSelectionPill(
            isSelected: isSelected,
            namespace: namespace,
            cornerRadius: cornerRadius,
            paddingHorizontal: paddingHorizontal,
            fill: fill,
            strokeColor: strokeColor
        ))
    }

    public func fluidIconZoom(isFocused: Bool) -> some View {
        modifier(FluidIconZoom(isFocused: isFocused))
    }
}
