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
    private var observedPID: pid_t = 0
    private var debounceItem: DispatchWorkItem?

    // Notifications that signal a meaningful context change
    private static let watchedNotifications: [String] = [
        kAXSelectedTextChangedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
        "AXSelectedRowsChanged",           // kAXSelectedRowsChangedNotification
        "AXSelectedColumnsChanged",
        kAXValueChangedNotification as String,
    ]

    func start(for pid: pid_t) {
        guard pid != observedPID else { return }
        stop()
        observedPID = pid

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
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        for notif in Self.watchedNotifications {
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

    // Debounce: coalesce rapid fires (e.g. dragging a selection) into one callback
    private func scheduleCallback() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange?() }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
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
