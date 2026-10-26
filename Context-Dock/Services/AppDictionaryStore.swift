// AppDictionaryStore.swift
// Context-Dock
//
// The scripting-dictionary rung's cache and scanner (P13 #208).
//
// One JSON manifest per app, under ILauncher/AppDictionaries/, keyed by the version it
// was scanned from. Scanning runs `/usr/bin/sdef` on the app bundle — a command-line
// reader, not an Apple Event, so scanning never launches or activates the app — with a
// hard watchdog, then parses (AppSdefParser), then stores.
//
// Staleness has two causes, and both re-scan: the app's version changed (its dictionary
// could have changed with it), or the manifest is older than the parser schema (a cached
// manifest from before typed codes and enumerations existed cannot drive typed Apple
// Events). The kick comes from AppKnowledgeSkillRefresher (every known app, at launch and
// after a change) and from each chat preflight for the apps that turn may reach.
//
// The first turn after a cold cache must not race the scan: `ensureScanned` awaits the
// scan (bounded) so the prompt and the capability list are built from the manifest that
// lands, rather than from the empty cache the turn started with.
//
// Apps whose dictionary is unknown are simply absent — the rung is invisible until its
// first scan lands, and every consumer treats absence as "no dictionary". The test host
// never scans: the suite is offline and its Mac is nobody's Mac.

import AppKit
import Foundation
import OSLog

@MainActor
final class AppDictionaryStore {
    static let shared = AppDictionaryStore()

    /// `nonisolated` because the scanner runs off the main actor and `Logger` is Sendable.
    nonisolated private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "AppDictionaryStore")

    /// How long a cold-cache turn waits for the scan before answering from what it has.
    /// `sdef` is a local command-line read and normally lands well inside this.
    private static let coldCacheWait: TimeInterval = 8

    /// bundleID → manifest, newest version per app.
    private(set) var dictionaries: [String: AppScriptingDictionary] = [:]

    private let directory: URL
    /// One task per bundle id, shared by every caller — the kick and a cold-cache await
    /// must not start two `sdef` processes for the same app.
    private var scansInFlight: [String: Task<AppScriptingDictionary?, Never>] = [:]
    /// Bundle ids a scan has already been attempted for this launch and failed (the app is
    /// missing, or sdef refused). Absence is not retried every turn.
    private var failedScans: Set<String> = []

    /// Injectable for tests: a store pointed at a scratch directory writes nothing to
    /// the real Application Support.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            self.directory = appSupport
                .appendingPathComponent("ILauncher/AppDictionaries", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
        loadAll()
    }

    // MARK: Cache

    func dictionary(forBundleID bundleID: String) -> AppScriptingDictionary? {
        dictionaries[bundleID]
    }

    /// Test injection: plant or drop a manifest without a scan. Dead in the app — the
    /// suite must never reach the real Application Support (runbooks: offline testing).
    func _injectForTesting(bundleID: String, manifest: AppScriptingDictionary?) {
        guard AppDelegate.isHostingTests else { return }
        dictionaries[bundleID] = manifest
    }

    private func loadAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let manifest = try? JSONDecoder().decode(
                    AppScriptingDictionary.self, from: data)
            else { continue }
            dictionaries[manifest.bundleID] = manifest
        }
    }

    private func write(_ manifest: AppScriptingDictionary) {
        dictionaries[manifest.bundleID] = manifest
        let file = directory.appendingPathComponent(
            "\(manifest.bundleID).json")
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Staleness

    /// True when the cache cannot answer for the app as it is installed today: no manifest,
    /// an app version change, or a parser schema older than this build's.
    func isStale(bundleID: String) -> Bool {
        guard let cached = dictionaries[bundleID] else { return true }
        if cached.schema < AppScriptingDictionary.currentSchema { return true }
        let installed = Self.installedVersion(bundleID: bundleID)
        return !installed.isEmpty && cached.version != installed
    }

    // MARK: Scanning

    /// Kick a scan when the cached manifest is stale. Returns nothing and costs nothing
    /// when the cache is current or a scan is already running.
    ///
    /// A scan that finds an empty dictionary (a non-scriptable app, sdef prints nothing)
    /// stores an empty marker manifest, so the absence is cached too and the same app is
    /// not re-scanned on every turn.
    ///
    /// - Parameter grants: Apps the calling surface is allowed to reach. A scan that lands
    ///   for one of them re-registers the learned capabilities; an ungranted scan never
    ///   grants anything by itself.
    func kickScanIfStale(
        bundleID: String, appName: String, grants: Set<String> = []
    ) {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("scope://") else { return }
        guard !AppDelegate.isHostingTests else { return }
        guard isStale(bundleID: bundleID) else { return }
        _ = scanTask(bundleID: bundleID, appName: appName, grants: grants)
    }

    /// The cold-cache path: await the scan (bounded) and return the manifest the turn
    /// should use. Current cache returns synchronously; a scan already in flight is joined,
    /// not duplicated.
    func ensureScanned(
        bundleID: String, appName: String, grants: Set<String>
    ) async -> AppScriptingDictionary? {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("scope://") else {
            return dictionaries[bundleID]
        }
        guard !AppDelegate.isHostingTests else { return dictionaries[bundleID] }
        guard isStale(bundleID: bundleID) else { return dictionaries[bundleID] }
        guard !failedScans.contains(bundleID) else { return dictionaries[bundleID] }

        let task = scanTask(bundleID: bundleID, appName: appName, grants: grants)
        let scanned = await withTaskGroup(
            of: AppScriptingDictionary?.self, returning: AppScriptingDictionary?.self
        ) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.coldCacheWait * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // A timed-out scan keeps running; the notification it posts refreshes the panel
        // and the next turn finds the manifest. This turn answers from the cache.
        return scanned ?? dictionaries[bundleID]
    }

    private func scanTask(
        bundleID: String, appName: String, grants: Set<String>
    ) -> Task<AppScriptingDictionary?, Never> {
        if let running = scansInFlight[bundleID] { return running }

        let displayName = appName.isEmpty ? bundleName(bundleID: bundleID) : appName
        let version = Self.installedVersion(bundleID: bundleID)
        let task = Task { [weak self] in
            let manifest = await Self.scan(
                bundleID: bundleID, appName: displayName, version: version)
            guard let self else { return manifest }
            self.scansInFlight[bundleID] = nil
            guard let manifest else {
                self.failedScans.insert(bundleID)
                return nil
            }
            self.write(manifest)
            let counts = String(manifest.classes.count) + " classes, "
                + String(manifest.commands.count) + " commands"
            Self.log.notice(
                "dictionary scanned: \(bundleID, privacy: .public) v\(manifest.version) — \(counts, privacy: .public)")
            // Tell the scope panel the manifest it is showing just changed. This is the
            // fix for the panel staying on an empty/stale dictionary after a scan.
            NotificationCenter.default.post(name: .appDictionaryChanged, object: nil)
            // Re-register for a surface that asked. An ungranted scan deliberately does
            // not refresh: scanning an installed app is discovery, not consent.
            if !grants.isEmpty {
                CapabilityRegistry.shared.refreshBuiltInMCPs(dictionaryGrants: grants)
            }
            return manifest
        }
        scansInFlight[bundleID] = task
        return task
    }

    /// One scan: `sdef` output in, manifest out. Nil when the app cannot be found or sdef
    /// failed; an empty-but-valid dictionary is still stored (absence caching).
    nonisolated static func scan(
        bundleID: String, appName: String, version: String
    ) async -> AppScriptingDictionary? {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID)
        else { return nil }

        let output: String
        do {
            output = try await sdefOutput(at: appURL)
        } catch {
            let reason = error.localizedDescription
            log.notice(
                "sdef scan failed: \(bundleID, privacy: .public) — \(reason, privacy: .public)")
            return nil
        }
        let manifest = AppSdefParser.parse(
            output, bundleID: bundleID, appName: appName, version: version)
        let counts = String(manifest.classes.count) + " classes, "
            + String(manifest.commands.count) + " commands"
        log.notice(
            "sdef scanned: \(bundleID, privacy: .public) — \(counts, privacy: .public)")
        return manifest
    }

    /// Run `sdef <app path>`, capturing its XML. Hard watchdog: a hung scan must never
    /// pin a task forever — the pattern is the P8 CLI scanner's, at 20 s.
    private nonisolated static func sdefOutput(at appURL: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sdef")
        process.arguments = [appURL.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let timeout: TimeInterval = 20
        var timedOut = false
        let killer = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let drained: (output: Data, error: Data) = await withCheckedContinuation {
            continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (out, err))
            }
        }
        process.waitUntilExit()
        killer.cancel()
        if timedOut {
            throw NSError(
                domain: "AppDictionaryStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "sdef timed out after 20 s."])
        }
        _ = String(data: drained.error, encoding: .utf8)
        return (String(data: drained.output, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: App facts

    /// The installed app version the refresher also keys on. Re-derived here because the
    /// refresher's copy is private, and the manifest's version stamp must be derived from
    /// the same thing both sides compare.
    static func installedVersion(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let info = Bundle(url: url)?.infoDictionary
        else { return "" }
        return (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? ""
    }

    private func bundleName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "", options: .caseInsensitive)
    }
}
