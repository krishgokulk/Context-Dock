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

    /// Every eligible window of an app, for the strip's hover row.
    @Published private(set) var windowSets: [String: [WindowSnapshot]] = [:]
    fileprivate var windowsInFlight: Set<String> = []
    fileprivate var windowsCaptured: [String: Date] = [:]

    /// How stale a snapshot may be before scoping in takes another. Short enough to feel
    /// live, long enough that walking the pills does not capture continuously.
    fileprivate static let freshness: TimeInterval = 2

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

/// What the window filter needs from an `SCWindow`, as a value so the rule can be tested
/// without ScreenCaptureKit in the room.
struct WindowCandidate: Equatable {
    let id: CGWindowID
    let bundleID: String?
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int
}

struct WindowSnapshot: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let image: NSImage?
}

extension AppWindowSnapshotService {
    static let windowRowLimit = 6

    /// This app's ordinary windows, front to back, at most `limit`. Layer 0 is a normal
    /// window; palettes, tooltips and menus sit above it. The size floor drops the
    /// one-line palettes that pass as layer 0.
    nonisolated static func eligibleWindows(
        _ all: [WindowCandidate], bundleID: String, limit: Int = windowRowLimit
    ) -> [WindowCandidate] {
        Array(
            all.filter {
                $0.bundleID == bundleID && $0.isOnScreen && $0.layer == 0
                    && $0.frame.width > 80 && $0.frame.height > 80
            }
            .prefix(limit))
    }

    func windowSnapshots(for bundleID: String) -> [WindowSnapshot] {
        windowSets[bundleID] ?? []
    }

    /// Every eligible window of one app, captured one by one. The 2 s freshness rule is
    /// the single-window path's; walking the strip must not capture continuously.
    func refreshWindows(bundleID: String) {
        guard !bundleID.isEmpty, !windowsInFlight.contains(bundleID) else { return }
        if let last = windowsCaptured[bundleID],
            Date().timeIntervalSince(last) < Self.freshness
        {
            return
        }
        windowsInFlight.insert(bundleID)
        Task { [weak self] in
            let set = await Self.captureWindows(bundleID: bundleID)
            guard let self else { return }
            self.windowsInFlight.remove(bundleID)
            guard let set else { return }
            self.windowsCaptured[bundleID] = Date()
            self.isDenied = false
            self.windowSets[bundleID] = set
        }
    }

    private static func captureWindows(bundleID: String) async -> [WindowSnapshot]? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            let candidates = content.windows.map {
                WindowCandidate(
                    id: $0.windowID, bundleID: $0.owningApplication?.bundleIdentifier,
                    title: $0.title ?? "", frame: $0.frame, isOnScreen: $0.isOnScreen,
                    layer: $0.windowLayer)
            }
            let wanted = eligibleWindows(candidates, bundleID: bundleID).map(\.id)
            var result: [WindowSnapshot] = []
            for id in wanted {
                guard let window = content.windows.first(where: { $0.windowID == id }) else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                // A 160-point thumbnail: a quarter-size capture is already more than it shows.
                config.width = max(Int(window.frame.width / 4), 1)
                config.height = max(Int(window.frame.height / 4), 1)
                config.showsCursor = false
                let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                result.append(
                    WindowSnapshot(
                        id: window.windowID, title: window.title ?? "",
                        image: image.map {
                            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                        }))
            }
            return result
        } catch {
            await MainActor.run { AppWindowSnapshotService.shared.isDenied = true }
            return nil
        }
    }
}
