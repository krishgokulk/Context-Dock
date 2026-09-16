// ChatAppDirectory.swift
// Context-Dock
//
// One answer to "which apps can this chat talk to", for every surface that asks.
//
// The dock's "/" filter, the composer bar's "/" filter and both app pickers each built
// their own list from a different source, so the same typing gave different results
// depending on which chat you were in. `/finder` is the case that exposed it: the app
// catalogue scans /Applications and /System/Applications, and Finder lives in
// /System/Library/CoreServices — so the dock (which starts from running apps) offered it
// and the window (which started from the catalogue) did not.
//
// Sources are merged here once, ranked by how likely the app is to have live data behind
// it: running, then adapter-configured, then merely installed.

import AppKit

struct ChatAppEntry: Identifiable, Equatable {
    let name: String
    let bundleId: String
    let icon: NSImage?
    let isRunning: Bool

    var id: String { bundleId.isEmpty ? name.lowercased() : bundleId.lowercased() }

    static func == (lhs: ChatAppEntry, rhs: ChatAppEntry) -> Bool { lhs.id == rhs.id }
}

@MainActor
enum ChatAppDirectory {

    static let finderBundleID = "com.apple.finder"

    // MARK: - The merged list

    /// Every app a chat can be scoped to. Finder first, then running apps, then
    /// adapter-configured ones, then everything else installed.
    ///
    /// Finder is pinned rather than sorted because it is the app most worth scoping a
    /// chat to — it is where the user's files are, this app can already read its
    /// selection, and a folder question is the most common thing to ask about.
    static func all() -> [ChatAppEntry] {
        var seen = Set<String>()
        var entries: [ChatAppEntry] = []

        func add(_ entry: ChatAppEntry) {
            guard entry.bundleId != Bundle.main.bundleIdentifier else { return }
            guard seen.insert(entry.id).inserted else { return }
            entries.append(entry)
        }

        if let finder = finderEntry() { add(finder) }
        running().forEach(add)
        adapterConfigured().forEach(add)
        installed().forEach(add)

        return entries
    }

    /// Apps matching a "/" filter, best match first. An empty filter (bare "/") lists
    /// the head of the directory, so the choices are visible before they are narrowed.
    ///
    /// Match quality outranks the pin: typing "/saf" must put Safari in front, not
    /// Finder, or the leftmost icon stops being what Return will take.
    static func matching(_ filter: String, limit: Int = 8) -> [ChatAppEntry] {
        let needle = filter.lowercased()
        guard !needle.isEmpty else { return Array(all().prefix(limit)) }

        var ranked: [(rank: Int, index: Int, entry: ChatAppEntry)] = []
        for (index, entry) in all().enumerated() {
            let lowered = entry.name.lowercased()
            let matchRank: Int
            if lowered.hasPrefix(needle) {
                matchRank = 0
            } else if lowered.contains(needle) {
                matchRank = 1
            } else {
                continue
            }
            ranked.append((rank: matchRank, index: index, entry: entry))
        }

        return
            ranked
            // Ties break on directory order, which already carries running-before-installed
            // — re-sorting by name here would bury a running app under an installed one.
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .prefix(limit)
            .map(\.entry)
    }

    /// The bundle id for an app the user picked by name — the composer surfaces attach by
    /// name, and the scope they open is keyed by bundle id.
    static func bundleId(forName name: String) -> String? {
        let match = all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard let bundleId = match?.bundleId, !bundleId.isEmpty else { return nil }
        return bundleId
    }

    // MARK: - Sources

    /// Finder, resolved from the system rather than from a scan, so it is offered even in
    /// the odd moment it is not reported as running.
    private static func finderEntry() -> ChatAppEntry? {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: finderBundleID)
        else { return nil }
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == finderBundleID
        }
        return ChatAppEntry(
            name: "Finder", bundleId: finderBundleID,
            icon: NSWorkspace.shared.icon(forFile: url.path), isRunning: isRunning)
    }

    /// macOS reports one NSRunningApplication per PROCESS, so the same bundle can appear
    /// twice — a relaunch mid-quit, or an app running from two copies. `add` dedupes by
    /// id, which matters: duplicate identifiers in a ForEach are undefined behaviour that
    /// has taken the app down when a picker was built.
    private static func running() -> [ChatAppEntry] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap { app in
                guard let name = app.localizedName, let bundleId = app.bundleIdentifier,
                    !bundleId.isEmpty
                else { return nil }
                let icon =
                    app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "")
                return ChatAppEntry(
                    name: name, bundleId: bundleId, icon: icon, isRunning: true)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func adapterConfigured() -> [ChatAppEntry] {
        AppAdapterManager.shared.adapters
            .filter {
                $0.isEnabled && !$0.bundleId.isEmpty && !$0.bundleId.hasPrefix("scope://")
            }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            .map { adapter in
                ChatAppEntry(
                    name: adapter.appName, bundleId: adapter.bundleId,
                    icon: icon(forBundleId: adapter.bundleId), isRunning: false)
            }
    }

    private static func installed() -> [ChatAppEntry] {
        InstalledApplicationsCatalog.cachedInstalledApps()
            .map {
                ChatAppEntry(
                    name: $0.name, bundleId: $0.bundleId, icon: $0.icon, isRunning: false)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func icon(forBundleId bundleId: String) -> NSImage? {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
