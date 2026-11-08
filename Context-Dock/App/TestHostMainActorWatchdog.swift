//
//  TestHostMainActorWatchdog.swift
//  Context-Dock
//
//  Watchdog that monitors MainActor responsiveness during test host runs.
//  Uses a lock-protected heartbeat timestamp to detect stalls without deadlocks
//  or blocking dispatch queues.
//

import Foundation

final class TestHostMainActorWatchdog: @unchecked Sendable {
    static let shared = TestHostMainActorWatchdog()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.ilauncher.test-watchdog", qos: .userInitiated)
    private let lock = NSLock()
    private var lastHeartbeatTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var _isMainActorStalled = false
    private var pingPending = false
    private var hasLoggedStall = false

    var isMainActorStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isMainActorStalled
    }

    static func install(timeoutSeconds: TimeInterval = 10.0) {
        #if DEBUG
        guard AppDelegate.isHostingTests else { return }
        shared.start(timeoutSeconds: timeoutSeconds)
        #endif
    }

    static func stop() {
        #if DEBUG
        shared.stop()
        #endif
    }

    func stop() {
        #if DEBUG
        timer?.cancel()
        timer = nil
        lock.lock()
        _isMainActorStalled = false
        pingPending = false
        hasLoggedStall = false
        lock.unlock()
        #endif
    }

    private func start(timeoutSeconds: TimeInterval) {
        stop()
        lock.lock()
        lastHeartbeatTime = CFAbsoluteTimeGetCurrent()
        _isMainActorStalled = false
        pingPending = false
        hasLoggedStall = false
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            self.lock.lock()
            let elapsed = CFAbsoluteTimeGetCurrent() - self.lastHeartbeatTime
            if elapsed > timeoutSeconds {
                self._isMainActorStalled = true
                if !self.hasLoggedStall {
                    self.hasLoggedStall = true
                    let warning = "⚠️ [TestHostWatchdog] MainActor blocked for \(String(format: "%.1f", elapsed))s! Potential deadlock or synchronous AX scan in test host."
                    fputs(warning + "\n", stderr)
                }
            } else {
                self._isMainActorStalled = false
                self.hasLoggedStall = false
            }

            let shouldSchedulePing = !self.pingPending
            if shouldSchedulePing {
                self.pingPending = true
            }
            self.lock.unlock()

            guard shouldSchedulePing else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.lastHeartbeatTime = CFAbsoluteTimeGetCurrent()
                self._isMainActorStalled = false
                self.pingPending = false
                self.hasLoggedStall = false
                self.lock.unlock()
            }
        }
        self.timer = timer
        timer.resume()
    }
}
