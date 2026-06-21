import AppKit
import ApplicationServices
import Foundation

@MainActor
final class MenuWarmCacheService {
    static let shared = MenuWarmCacheService()

    private var warmTask: Task<Void, Never>?
    private var idleWarmTask: Task<Void, Never>?
    private var activeWarmPID: pid_t?
    private var lastWarmDateByBundleID: [String: Date] = [:]
    private var recentBundleIDs: [String] = []
    private var recentAppsByBundleID: [String: NSRunningApplication] = [:]
    private let warmFreshness: TimeInterval = 45
    private let idleWarmFreshness: TimeInterval = 5 * 60
    private let debounceNanoseconds: UInt64 = 350_000_000
    private let maxRecentApps = 12

    private init() {}

    func frontmostAppDidChange(_ app: NSRunningApplication) {
        guard shouldWarm(app) else { return }
        rememberRecent(app)

        warmTask?.cancel()
        warmTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.warm(app: app, force: false)
            guard !Task.isCancelled,
                  let bundleID = app.bundleIdentifier,
                  self.needsWarm(bundleID: bundleID, freshness: self.warmFreshness)
            else { return }

            // An idle/background scan may have owned AX when the first request arrived.
            // Retry once so the newly frontmost app is not left with stale capabilities.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self.warm(app: app, force: false)
        }
    }

    func appDidLaunch(_ app: NSRunningApplication) {
        guard shouldWarm(app) else { return }
        rememberRecent(app)

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self.warm(app: app, force: false)
        }
    }

    /// Called when the launcher window opens. Warms recent apps with a 2-min threshold
    /// so global context AI and menu pills are fresh without waiting for the 5-min idle cycle.
    func warmRecentAppsOnLauncherOpen() {
        Task { [weak self] in
            guard let self else { return }
            await self.warmRecentWithFreshness(120)
        }
    }

    func warmRunningAppsOnLauncherOpen(_ apps: [NSRunningApplication], maxApps: Int = 6) {
        Task { [weak self] in
            guard let self else { return }
            await self.warmRunningApps(apps, maxApps: maxApps, freshness: 120)
        }
    }

    private func warmRecentWithFreshness(_ freshness: TimeInterval) async {
        guard AXIsProcessTrusted(), activeWarmPID == nil,
              !AXMenuReader.shared.isScanningMenus
        else { return }

        for bundleID in recentBundleIDs {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                      $0.bundleIdentifier == bundleID && !$0.isTerminated
                  }),
                  shouldWarm(app)
            else { continue }
            recentAppsByBundleID[bundleID] = app

            let age = lastWarmDateByBundleID[bundleID].map { Date().timeIntervalSince($0) } ?? .infinity
            guard age >= freshness else { continue }

            await warm(app: app, force: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
        }
    }

    private func warmRunningApps(
        _ apps: [NSRunningApplication],
        maxApps: Int,
        freshness: TimeInterval
    ) async {
        guard AXIsProcessTrusted(), activeWarmPID == nil,
              !AXMenuReader.shared.isScanningMenus
        else { return }

        var seenBundleIDs = Set<String>()
        let candidates = apps.compactMap { app -> NSRunningApplication? in
            guard shouldWarm(app),
                  let bundleID = app.bundleIdentifier,
                  seenBundleIDs.insert(bundleID).inserted
            else { return nil }
            return app
        }

        for app in candidates.prefix(maxApps) {
            guard let bundleID = app.bundleIdentifier else { continue }
            rememberRecent(app)
            let age = lastWarmDateByBundleID[bundleID].map { Date().timeIntervalSince($0) } ?? .infinity
            guard age >= freshness else { continue }

            await warm(app: app, force: false)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
        }
    }

    func startIdleWarming() {
        guard idleWarmTask == nil else { return }
        idleWarmTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { break }
                await self.warmRecentAppsIfIdle()
            }
        }
    }

    func cachedMenuItems(for app: NSRunningApplication, maxResults: Int = 160) -> [AXMenuItem] {
        AppMenuCapabilityCache.shared.menuItems(for: app, maxResults: maxResults)
    }

    func warm(app: NSRunningApplication, force: Bool) async {
        guard shouldWarm(app) else { return }
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return }
        guard AXIsProcessTrusted() else { return }

        if !force,
           let lastWarm = lastWarmDateByBundleID[bundleID],
           Date().timeIntervalSince(lastWarm) < warmFreshness {
            return
        }
        if let activeWarmPID, activeWarmPID != app.processIdentifier {
            return
        }
        guard !AXMenuReader.shared.isScanningMenus else { return }

        activeWarmPID = app.processIdentifier
        defer {
            if activeWarmPID == app.processIdentifier {
                activeWarmPID = nil
            }
        }

        let pid = app.processIdentifier
        let name = app.localizedName ?? bundleID
        let capturedApp = app

        // Interactive callers await this result. Keep the scan at userInitiated
        // priority to avoid a user-interactive → utility priority inversion.
        let items = await Task.detached(priority: .userInitiated) {
            var readItems = await AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 6)
            if readItems.isEmpty {
                try? await Task.sleep(nanoseconds: 160_000_000)
                readItems = await AXMenuReader.shared.refreshAllMenuItems(for: pid, maxDepth: 6)
            }
            for index in readItems.indices {
                readItems[index].sourcePID = pid
                readItems[index].sourceAppName = name
            }
            return readItems
        }.value

        guard !app.isTerminated else { return }
        guard !items.isEmpty else { return }
        // If this app is frontmost, the live scan is authoritative — REPLACE its cache
        // so it always mirrors the current menu (drop stale items / outdated state).
        let isFrontmost =
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        AppMenuCapabilityCache.shared.store(
            items: items, for: capturedApp, replace: isFrontmost)
        lastWarmDateByBundleID[bundleID] = Date()
    }

    private func warmRecentAppsIfIdle() async {
        guard AXIsProcessTrusted(), activeWarmPID == nil,
              !AXMenuReader.shared.isScanningMenus
        else { return }

        for bundleID in recentBundleIDs {
            // Re-fetch from workspace: stored reference may be stale after app restart
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                      $0.bundleIdentifier == bundleID && !$0.isTerminated
                  }),
                  shouldWarm(app)
            else { continue }
            recentAppsByBundleID[bundleID] = app  // refresh reference

            let age = lastWarmDateByBundleID[bundleID].map { Date().timeIntervalSince($0) } ?? .infinity
            guard age >= idleWarmFreshness else { continue }

            await warm(app: app, force: false)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
        }
    }

    private func shouldWarm(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated,
              app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }
        return true
    }

    private func rememberRecent(_ app: NSRunningApplication) {
        let bundleID = app.bundleIdentifier ?? ""
        guard !bundleID.isEmpty else { return }
        recentAppsByBundleID[bundleID] = app
        recentBundleIDs.removeAll { $0 == bundleID }
        recentBundleIDs.insert(bundleID, at: 0)
        if recentBundleIDs.count > maxRecentApps {
            let removed = recentBundleIDs.suffix(recentBundleIDs.count - maxRecentApps)
            for id in removed {
                recentAppsByBundleID[id] = nil
                lastWarmDateByBundleID[id] = nil
            }
            recentBundleIDs.removeLast(recentBundleIDs.count - maxRecentApps)
        }
    }

    private func needsWarm(bundleID: String, freshness: TimeInterval) -> Bool {
        guard let lastWarm = lastWarmDateByBundleID[bundleID] else { return true }
        return Date().timeIntervalSince(lastWarm) >= freshness
    }
}
