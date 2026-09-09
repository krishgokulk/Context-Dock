// AppWindowSnapshotService.swift
// Context-Dock
//
// A picture of what an app is showing right now, for the corner's app switcher.
//
// Scoping into a running app from Global asks "what is this app doing?" — and a list of its
// menu commands does not answer that. The window does. This is the same thing ⌘-Tab shows,
// except it stays on screen while the user decides.
//
// ScreenCaptureKit, because the old `CGWindowListCreateImage` path is deprecated on this
// deployment target and this app already uses SCK elsewhere. Capture needs Screen Recording
// permission; without it the snapshot is simply absent, and the surface says so rather than
// showing an empty frame.

import AppKit
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
final class AppWindowSnapshotService: ObservableObject {
    static let shared = AppWindowSnapshotService()

    /// The newest snapshot per bundle id. Small and bounded: one image per app the user has
    /// actually scoped into this session.
    @Published private(set) var snapshots: [String: NSImage] = [:]
    /// Set when capture is refused, so the surface can say "allow Screen Recording" instead
    /// of showing nothing and looking broken.
    @Published private(set) var isDenied = false

    private var inFlight: Set<String> = []
    private var lastCaptured: [String: Date] = [:]

    /// How stale a snapshot may be before scoping in takes another. Short enough to feel
    /// live, long enough that walking the pills does not capture continuously.
    private static let freshness: TimeInterval = 2

    private init() {}

    func snapshot(for bundleID: String) -> NSImage? { snapshots[bundleID] }

    /// Capture the app's frontmost window, unless a recent shot is already in hand.
    func refresh(bundleID: String) {
        guard !bundleID.isEmpty, !inFlight.contains(bundleID) else { return }
        if let last = lastCaptured[bundleID],
            Date().timeIntervalSince(last) < Self.freshness
        {
            return
        }
        inFlight.insert(bundleID)

        Task { [weak self] in
            let image = await Self.capture(bundleID: bundleID)
            guard let self else { return }
            self.inFlight.remove(bundleID)
            guard let image else {
                // No timestamp on a failure. Recording one meant a window that was simply
                // not ready yet — an app still drawing, a window on another Space coming
                // forward — was written off for two seconds and never asked about again.
                return
            }
            self.lastCaptured[bundleID] = Date()
            self.isDenied = false
            self.snapshots[bundleID] = image
        }
    }

    /// The app's largest on-screen window, which is the one the user means. Windows are
    /// listed front-to-back, but the frontmost can be a one-line palette or a tooltip, so
    /// area decides rather than order.
    private static func capture(bundleID: String) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            // Small windows are palettes and tooltips, not the app — but the floor has to
            // stay low enough for a genuinely small window to count.
            let windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
                    && $0.frame.width > 80 && $0.frame.height > 80
                    && $0.isOnScreen
            }
            guard let window = windows.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            // Half size: this is drawn at 372 points wide and never inspected closely, and
            // a full-resolution capture of a 6K window costs far more than it shows.
            config.width = max(Int(window.frame.width / 2), 1)
            config.height = max(Int(window.frame.height / 2), 1)
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            return NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            await MainActor.run { AppWindowSnapshotService.shared.isDenied = true }
            return nil
        }
    }
}
