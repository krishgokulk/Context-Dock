// ContextDockStore.swift
// Context-Dock
//
// Canonical file-based, per-app namespaced storage.
//
// Directory layout:
//   ~/Library/Application Support/Context-Dock/
//       global/
//           rules.json        ← AX trigger rules that apply to all apps (bundleId = nil)
//       apps/
//           com.apple.Safari/
//               menus.json    ← PersistedMenuSnapshot (version + signature + items)
//               rules.json    ← app-scoped AX trigger rules
//           com.google.Chrome/
//               menus.json
//               rules.json
//
// Write guarantees:
//   • Writes are debounced 300ms — rapid saves coalesce into one I/O operation.
//   • Content-hash check prevents identical rewrites from touching the filesystem.
//   • Atomic writes (.atomic option) prevent partial-file corruption on crash.

import Foundation

final class ContextDockStore {
    static let shared = ContextDockStore()

    // MARK: - Root directories

    static let root: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock", isDirectory: true)
    }()

    static var globalDir: URL {
        root.appendingPathComponent("global", isDirectory: true)
    }

    static func appDir(bundleId: String) -> URL {
        root.appendingPathComponent("apps/\(bundleId)", isDirectory: true)
    }

    // MARK: - Debounced write engine

    private var pendingWrites: [URL: Data] = [:]
    private var lastWritten:   [URL: Data] = [:]    // content-hash skip
    private var flushWork: DispatchWorkItem?
    private let writeQueue = DispatchQueue(label: "com.contextdock.store.writes", qos: .utility)
    private let pendingLock = NSLock()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private init() {}

    // MARK: - Generic I/O

    func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }

        pendingLock.lock()
        // Skip if identical content was already flushed to this path
        if lastWritten[url] == data {
            pendingLock.unlock()
            return
        }
        pendingWrites[url] = data
        pendingLock.unlock()

        scheduleFlush()
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func delete(at url: URL) {
        pendingLock.lock()
        pendingWrites.removeValue(forKey: url)
        lastWritten.removeValue(forKey: url)
        pendingLock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    // Flush immediately — call when app is about to terminate
    func flushNow() {
        flushWork?.cancel()
        performFlush()
    }

    // MARK: - Debounce logic

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performFlush() }
        flushWork = work
        writeQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func performFlush() {
        pendingLock.lock()
        let batch = pendingWrites
        pendingWrites.removeAll()
        pendingLock.unlock()

        for (url, data) in batch {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            pendingLock.lock()
            lastWritten[url] = data
            pendingLock.unlock()
        }
    }

    // MARK: - AX Trigger Rules

    func rulesURL(bundleId: String?) -> URL {
        if let b = bundleId, !b.isEmpty {
            return Self.appDir(bundleId: b).appendingPathComponent("rules.json")
        }
        return Self.globalDir.appendingPathComponent("rules.json")
    }

    func saveRules(_ rules: [AXTriggerRule], bundleId: String?) {
        write(rules, to: rulesURL(bundleId: bundleId))
    }

    func loadRules(bundleId: String?) -> [AXTriggerRule] {
        read([AXTriggerRule].self, from: rulesURL(bundleId: bundleId)) ?? []
    }

    func loadAllRules() -> [AXTriggerRule] {
        var all = loadRules(bundleId: nil)
        let appsDir = Self.root.appendingPathComponent("apps", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: appsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        for entry in entries {
            if let rules = read([AXTriggerRule].self, from: entry.appendingPathComponent("rules.json")) {
                all.append(contentsOf: rules)
            }
        }
        return all
    }

    func migrateIfNeeded(legacyRules: [AXTriggerRule]) {
        let flag = Self.root.appendingPathComponent(".migrated_rules_v1")
        guard !FileManager.default.fileExists(atPath: flag.path) else { return }

        var globalRules: [AXTriggerRule] = []
        var byApp: [String: [AXTriggerRule]] = [:]
        for rule in legacyRules {
            if let b = rule.bundleId, !b.isEmpty { byApp[b, default: []].append(rule) }
            else { globalRules.append(rule) }
        }
        if !globalRules.isEmpty { saveRules(globalRules, bundleId: nil) }
        for (b, rules) in byApp { saveRules(rules, bundleId: b) }

        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        flushNow()
    }

    // MARK: - Menu Snapshots (AXMenuEnumerator disk cache)

    func menuSnapshotURL(bundleId: String) -> URL {
        Self.appDir(bundleId: bundleId).appendingPathComponent("menus.json")
    }

    func saveMenuSnapshot(_ snapshot: PersistedMenuSnapshot, bundleId: String) {
        write(snapshot, to: menuSnapshotURL(bundleId: bundleId))
    }

    func loadMenuSnapshot(bundleId: String) -> PersistedMenuSnapshot? {
        read(PersistedMenuSnapshot.self, from: menuSnapshotURL(bundleId: bundleId))
    }

    func deleteMenuSnapshot(bundleId: String) {
        delete(at: menuSnapshotURL(bundleId: bundleId))
    }

    // Legacy shims — kept so old call sites compile without changes
    func saveMenuItems(_ items: [AXMenuItemInfo], bundleId: String) {
        let snap = PersistedMenuSnapshot(
            bundleVersion: "", menuSignature: "", items: items, savedAt: Date())
        saveMenuSnapshot(snap, bundleId: bundleId)
    }

    func loadMenuItems(bundleId: String) -> [AXMenuItemInfo]? {
        loadMenuSnapshot(bundleId: bundleId)?.items
    }

    func deleteMenuItems(bundleId: String) {
        deleteMenuSnapshot(bundleId: bundleId)
    }

    // MARK: - App directory listing

    func allPersistedAppBundleIds() -> [String] {
        let appsDir = Self.root.appendingPathComponent("apps", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: appsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        return entries.map { $0.lastPathComponent }.sorted()
    }
}
