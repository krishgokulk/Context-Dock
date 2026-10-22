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
// An app is re-scanned only when its version changes from the cached manifest's, which
// is exactly when a dictionary could have changed with it. The kick comes from two
// places: AppKnowledgeSkillRefresher (every known app, at launch and after a change)
// and the scoped-chat preflight (the app the user is talking to right now).
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

    /// bundleID → manifest, newest version per app.
    private(set) var dictionaries: [String: AppScriptingDictionary] = [:]

    private let directory: URL
    /// Bundle ids whose scan is running, so the per-turn kick fires the scan once.
    private var scansInFlight: Set<String> = []
    /// The bundle id of the app its capability list should come from. Empty while no
    /// app-scoped turn has named one this launch.
    private var lastScopedBundleID: String = ""

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

    // MARK: Scanning

    /// Kick a scan for the app's current version when the cached one is stale. Returns
    /// nothing and costs nothing when the cache is current or a scan is already running.
    ///
    /// A scan that finds an empty dictionary (a non-scriptable app, sdef prints nothing)
    /// stores an empty marker manifest, so the absence is cached too and the same app is
    /// not re-scanned on every turn.
    func kickScanIfStale(bundleID: String, appName: String) {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("scope://") else { return }
        guard !AppDelegate.isHostingTests else { return }
        guard scansInFlight.insert(bundleID).inserted else { return }

        lastScopedBundleID = bundleID
        let displayName = appName.isEmpty ? bundleName(bundleID: bundleID) : appName
        let version = Self.installedVersion(bundleID: bundleID)
        if let cached = dictionaries[bundleID],
            !version.isEmpty, cached.version == version
        {
            scansInFlight.remove(bundleID)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let manifest = await Self.scan(
                bundleID: bundleID, appName: displayName, version: version)
            self.scansInFlight.remove(bundleID)
            guard let manifest else { return }
            self.write(manifest)
            let counts = String(manifest.classes.count) + " classes, "
                + String(manifest.commands.count) + " commands"
            Self.log.notice(
                "dictionary scanned: \(bundleID, privacy: .public) v\(manifest.version) — \(counts, privacy: .public)")
            // Newly-learned dictionaries reach the prompt the same way built-ins do.
            if self.lastScopedBundleID == bundleID {
                CapabilityRegistry.shared.refreshBuiltInMCPs()
            }
        }
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
