// AXSelectionObserver.swift
// ILauncher
//
// Push-based AX observer: fires a debounced callback whenever the user changes
// their selection (text highlight, file pick, focus shift) in the target app.
// Lives on the main run loop — no polling, zero CPU when idle.
//

import AppKit
import ApplicationServices
import Combine

// MARK: - Low-level AX observer wrapper

final class AXSelectionObserver {
    var onChange: (() -> Void)?

    private var axObserver: AXObserver?
    private var observedElement: AXUIElement?
    private var observedPID: pid_t = 0
    private var debounceInterval: TimeInterval = 0.2
    private var debounceItem: DispatchWorkItem?

    /// A run of events must not postpone the callback indefinitely — see `scheduleCallback`.
    private static let maxCoalesceWindow: TimeInterval = 1.0
    /// Events per second above which an app is treated as continuously self-rewriting.
    private static let burstThreshold = 40

    private var pendingSince: Date?
    private var burstWindowStart = Date.distantPast
    private var burstCount = 0
    private var valueChangedSuspended = false

    // Notifications that signal a meaningful context change
    private static let watchedNotifications: [String] = [
        kAXSelectedTextChangedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
        "AXSelectedRowsChanged",           // kAXSelectedRowsChangedNotification
        "AXSelectedColumnsChanged",
        kAXValueChangedNotification as String,
    ]

    /// Apps whose AXValue changes on every character they print. Subscribing to
    /// value-changed on one of these delivers thousands of notifications a second onto
    /// the main run loop — enough to freeze the dock outright — and not one of them says
    /// anything about what the user has selected.
    private static let streamingOutputBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "io.alacritty",
        "co.zeit.hyper",
        "com.apple.Console",
    ]

    func start(for pid: pid_t, debounceInterval: TimeInterval = 0.2) {
        guard pid != observedPID else { return }
        stop()
        observedPID = pid
        self.debounceInterval = debounceInterval

        // C callback — called on the main run loop thread
        let callback: AXObserverCallback = { _, _, _, ctx in
            guard let ctx else { return }
            Unmanaged<AXSelectionObserver>.fromOpaque(ctx)
                .takeUnretainedValue()
                .scheduleCallback()
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        axObserver = obs

        let axApp = AXUIElementCreateApplication(pid)
        observedElement = axApp
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let skipValueChanged = Self.streamingOutputBundleIds.contains(bundleId)
        valueChangedSuspended = skipValueChanged

        for notif in Self.watchedNotifications {
            if skipValueChanged, notif == kAXValueChangedNotification as String { continue }
            AXObserverAddNotification(obs, axApp, notif as CFString, ctx)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )
    }

    func stop() {
        debounceItem?.cancel()
        debounceItem = nil
        pendingSince = nil
        burstCount = 0
        burstWindowStart = .distantPast
        valueChangedSuspended = false
        observedElement = nil
        if let obs = axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(obs),
                .defaultMode
            )
        }
        axObserver = nil
        observedPID = 0
    }

    deinit { stop() }

    // Debounce: coalesce rapid fires (e.g. dragging a selection) into one callback.
    // Bounded, because a plain trailing debounce never fires at all while an app emits
    // events continuously — it just keeps rescheduling while the run loop drowns.
    private func scheduleCallback() {
        suspendValueChangedIfStorming()

        let now = Date()
        if pendingSince == nil { pendingSince = now }
        let waited = now.timeIntervalSince(pendingSince ?? now)
        let delay = max(0, min(debounceInterval, Self.maxCoalesceWindow - waited))

        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pendingSince = nil
            self?.onChange?()
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Any app — not just the known terminals — can start rewriting itself continuously
    /// (a build log, a progress view). Past a sustained rate, drop the value-changed
    /// subscription for it: selection and focus notifications still arrive, and the main
    /// run loop gets its capacity back.
    private func suspendValueChangedIfStorming() {
        let now = Date()
        if now.timeIntervalSince(burstWindowStart) > 1.0 {
            burstWindowStart = now
            burstCount = 0
        }
        burstCount += 1

        guard burstCount > Self.burstThreshold,
            !valueChangedSuspended,
            let obs = axObserver,
            let element = observedElement
        else { return }
        AXObserverRemoveNotification(obs, element, kAXValueChangedNotification as CFString)
        valueChangedSuspended = true
    }
}

// MARK: - ObservableObject wrapper for SwiftUI

/// Wraps AXSelectionObserver so SwiftUI views can react via @StateObject + onChange.
final class SelectionObserverModel: ObservableObject {
    /// Increments every time a selection/focus change fires (after 200ms debounce).
    @Published private(set) var changeCount: Int = 0

    private let observer = AXSelectionObserver()

    init() {
        observer.onChange = { [weak self] in
            DispatchQueue.main.async { self?.changeCount += 1 }
        }
    }

    func start(for pid: pid_t) { observer.start(for: pid) }
    func stop()                 { observer.stop() }
}
