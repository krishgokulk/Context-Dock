import AppKit
import Foundation
import Testing
@testable import Context_Dock

/// The System Events walk `AXMenuReader` falls back to when an app's AX menu tree is empty
/// (VS Code, other Electron apps) never runs on the main thread: a main-thread read returns
/// what AX has at once, and the walk's rows land later. No AppleScript runs here — the walk
/// is a stub — and no Accessibility permission is needed: the AX tree is injected too.
@MainActor
struct AXMenuReaderScriptedFallbackTests {
    /// A pid no process has, so nothing real is read or stored.
    private let pid: pid_t = 999_983

    private final class WalkLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _ranOnMain = false
        var calls: Int { lock.withLock { _calls } }
        var ranOnMain: Bool { lock.withLock { _ranOnMain } }
        func record() {
            lock.withLock {
                _calls += 1
                if Thread.isMainThread { _ranOnMain = true }
            }
        }
    }

    private final class Announcements: @unchecked Sendable {
        private let lock = NSLock()
        private var _pids: [pid_t] = []
        var pids: [pid_t] { lock.withLock { _pids } }
        func append(_ pid: pid_t) { lock.withLock { _pids.append(pid) } }
    }

    private func reader(
        log: WalkLog,
        output: String? = "Code|||1\nFile|||1\nFile > New Window|||1\nFile > Save|||0",
        axItems: [AXMenuItem] = []
    ) -> AXMenuReader {
        AXMenuReader(
            scriptedMenuWalk: { _ in
                log.record()
                Thread.sleep(forTimeInterval: 0.02)
                return (output, nil)
            },
            appNameForPID: { _ in "Fake App" },
            axMenuTree: { _, _ in axItems })
    }

    private func axItem(_ path: [String]) -> AXMenuItem {
        AXMenuItem(
            title: path.last ?? "", path: path, isEnabled: true,
            element: AXUIElementCreateApplication(pid), children: [])
    }

    @Test func anAXTreeIsReturnedAtOnceAndNeverWalks() {
        let log = WalkLog()
        let reader = reader(log: log, axItems: [axItem(["File", "New Window"])])

        let items = reader.allMenuItems(for: pid)

        #expect(items.map(\.title) == ["New Window"])
        #expect(reader.pendingScriptedMenuWalk(for: pid) == nil)
        #expect(log.calls == 0)
    }

    /// The Dock's load path on the main thread: an empty AX tree comes back empty at once,
    /// the walk runs off main, and its rows are there — cache, re-read and notification —
    /// once it lands.
    @Test func anEmptyAXTreeReturnsAtOnceAndTheWalkLandsLater() async throws {
        let log = WalkLog()
        let reader = reader(log: log)
        let announced = Announcements()
        let observer = NotificationCenter.default.addObserver(
            forName: AXMenuReader.scriptedMenusDidLoad, object: nil, queue: nil
        ) { note in
            if let pid = note.userInfo?["pid"] as? pid_t { announced.append(pid) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(reader.refreshAllMenuItems(for: pid).isEmpty)
        let walk = try #require(reader.pendingScriptedMenuWalk(for: pid))
        #expect(reader.lastDebug(for: pid)?.hasSuffix("as_pending") == true)

        await walk.value

        #expect(log.calls == 1)
        #expect(!log.ranOnMain)
        #expect(announced.pids == [pid])
        #expect(reader.peekCachedAllMenuItems(for: pid).count == 4)
        let reread = reader.refreshAllMenuItems(for: pid)
        #expect(reread.map(\.path) == [
            ["Code"], ["File"], ["File", "New Window"], ["File", "Save"],
        ])
        #expect(reread.last?.isEnabled == false)
        // The fresh result answers the re-read; no second walk.
        #expect(reader.pendingScriptedMenuWalk(for: pid) == nil)
        #expect(log.calls == 1)
    }

    @Test func readsWhileAWalkIsInFlightDoNotStartAnother() async throws {
        let log = WalkLog()
        let reader = reader(log: log)

        _ = reader.allMenuItems(for: pid)
        let walk = try #require(reader.pendingScriptedMenuWalk(for: pid))
        _ = reader.allMenuItems(for: pid)
        _ = reader.cachedAllMenuItems(for: pid)
        #expect(reader.pendingScriptedMenuWalk(for: pid) != nil)

        await walk.value
        #expect(log.calls == 1)
    }

    /// An app whose walk finds nothing is not walked again on every keystroke.
    @Test func anEmptyWalkIsNotRetriedWhileFresh() async throws {
        let log = WalkLog()
        let reader = reader(log: log, output: nil)
        let announced = Announcements()
        let observer = NotificationCenter.default.addObserver(
            forName: AXMenuReader.scriptedMenusDidLoad, object: nil, queue: nil
        ) { note in
            if let pid = note.userInfo?["pid"] as? pid_t { announced.append(pid) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = reader.allMenuItems(for: pid)
        let walk = try #require(reader.pendingScriptedMenuWalk(for: pid))
        await walk.value

        #expect(reader.allMenuItems(for: pid).isEmpty)
        #expect(reader.pendingScriptedMenuWalk(for: pid) == nil)
        #expect(log.calls == 1)
        #expect(announced.pids.isEmpty)
    }

    /// The one entry the walk runs through works off the main thread; on it, it traps
    /// (`dispatchPrecondition`), which is why every caller goes through `AppleScriptQueue`.
    @Test func theWalkEntryRunsOffTheMainThread() async {
        let log = WalkLog()
        let result = await withCheckedContinuation { continuation in
            AppleScriptQueue.shared.async {
                continuation.resume(
                    returning: AXMenuReader.runScriptedMenuWalk(appName: "Fake App") { name in
                        log.record()
                        return (name, nil)
                    })
            }
        }
        #expect(result.output == "Fake App")
        #expect(log.calls == 1)
        #expect(!log.ranOnMain)
    }
}
