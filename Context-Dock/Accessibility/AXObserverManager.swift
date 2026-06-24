import AppKit
import ApplicationServices

// MARK: - AXObserverManager
//
// Owns a pool of AXSelectionObservers keyed by pid — one per app, reused when
// the user returns to a previously observed app (e.g. Safari → Chrome → Safari).
// Creating a new AXObserver is non-trivial (run-loop registration, AX callbacks),
// so reuse avoids unnecessary attach/detach churn.
//
// Pool is capped at maxObservers; LRU eviction discards the least-recently-used
// observer when the cap is reached.

final class AXObserverManager {
    static let shared = AXObserverManager()

    private var pool: [pid_t: AXSelectionObserver] = [:]
    private var accessOrder: [pid_t] = []   // LRU: front = oldest, back = newest
    private let maxObservers = 10

    private var currentPID: pid_t = 0
    private var appSwitchToken: NSObjectProtocol?

    private init() {}

    // MARK: - Public

    func startMonitoring() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            attach(to: front)
        }

        appSwitchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.attach(to: app)
            AXEventBus.shared.emit(.appActivated(app))
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func systemWillSleep() {
        clearPool()
    }

    @objc private func systemDidWake() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            attach(to: front)
        }
    }

    private func clearPool() {
        pool.values.forEach { $0.stop() }
        pool.removeAll()
        accessOrder.removeAll()
    }

    // MARK: - Private

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        currentPID = pid
        touchLRU(pid)

        // Reuse existing observer — zero overhead when switching back to a known app
        guard pool[pid] == nil else { return }

        // Evict LRU entry if pool is full
        if pool.count >= maxObservers, let oldest = accessOrder.first {
            pool[oldest]?.stop()
            pool.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }

        let obs = AXSelectionObserver()
        obs.onChange = { [pid] in
            AXEventBus.shared.emit(.focusedElementChanged(pid))
        }
        obs.start(for: pid, debounceInterval: 0.15)
        pool[pid] = obs
    }

    private func touchLRU(_ pid: pid_t) {
        accessOrder.removeAll { $0 == pid }
        accessOrder.append(pid)
    }

    deinit {
        pool.values.forEach { $0.stop() }
        if let t = appSwitchToken {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
        }
    }
}
