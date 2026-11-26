// Context-Dock/Services/Plugins/LegacyPluginCleanup.swift
// Context-Dock
//
// Safe .zip backup and one-time cleanup of legacy extension/plugin clutter
// (extensions.json, Layered L1-L3 folders, store-packs, Currency, currency fx files)
// before unifying on .doraxpack v3.
//
// Guarantees:
// 1. Never deletes a single file unless the .zip archive was created and verified > 0 bytes.
// 2. Preserves repo Packs/*.doraxpack untouched.
// 3. Idempotent: safe to call repeatedly; skips cleanly when nothing legacy exists.

import Foundation

struct LegacyCleanupReport: Equatable {
    let backupZipURL: URL?
    let backedUpRelativePaths: [String]
    let removedRelativePaths: [String]
    let errorMessage: String?

    var didCleanAnything: Bool { !removedRelativePaths.isEmpty }
    var succeeded: Bool { errorMessage == nil }
}

enum LegacyPluginCleanup {

    static let completionKey = "doraxpack_v3_legacy_cleanup_v2"

    /// Relative paths under `~/Library/Application Support/Context-Dock` that represent
    /// pre-v3 extension/plugin clutter to be archived into a `.zip` backup and removed.
    static let legacyRelativePaths: [String] = [
        "global/extensions.json",
        "Extensions/L1-Search",
        "Extensions/L2-Context",
        "Extensions/L3-Browser",
        "Extensions/Cross-Layer",
        "Extensions/User-Created",
        "plugins/store-packs",
        "plugins/essentials/plugins/currency",
        "plugins/state/currency.json",
        "plugins/v2/currency.doraxpack",
        "currency-favourites.json",
        "currency-target.json",
        "fx-rates.json",
    ]

    static var defaultAppSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context-Dock", isDirectory: true)
    }

    /// Runs once on startup in production builds (never during XCTest hosting).
    @MainActor
    @discardableResult
    static func runOnceIfNeeded() -> LegacyCleanupReport? {
        guard !AppDelegate.isHostingTests else { return nil }
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return nil }
        let report = runBackupAndCleanup(appSupportRoot: defaultAppSupportRoot)
        if report.succeeded {
            UserDefaults.standard.set(true, forKey: completionKey)
            if let zip = report.backupZipURL {
                NSLog("Context-Dock: legacy extension clutter archived to \(zip.path) and removed (\(report.removedRelativePaths.count) items)")
            }
        } else if let err = report.errorMessage {
            NSLog("Context-Dock: legacy extension backup failed (nothing deleted): \(err)")
        }
        return report
    }

    /// Archives any existing legacy paths inside `appSupportRoot` into a timestamped `.zip`
    /// under `backupDir` (default: `<appSupportRoot>/backups/`), verifies the archive is non-empty,
    /// and then removes the original legacy files/folders unless `dryRun == true`.
    static func runBackupAndCleanup(
        appSupportRoot: URL,
        backupDir: URL? = nil,
        dryRun: Bool = false
    ) -> LegacyCleanupReport {
        let fm = FileManager.default
        let presentPaths = legacyRelativePaths.filter { rel in
            fm.fileExists(atPath: appSupportRoot.appendingPathComponent(rel).path)
        }

        guard !presentPaths.isEmpty else {
            return LegacyCleanupReport(
                backupZipURL: nil,
                backedUpRelativePaths: [],
                removedRelativePaths: [],
                errorMessage: nil)
        }

        let resolvedBackupDir = backupDir
            ?? appSupportRoot.appendingPathComponent("backups", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let zipName = "legacy-extensions-backup-\(stamp).zip"
        let zipURL = resolvedBackupDir.appendingPathComponent(zipName)

        let stagingRoot = fm.temporaryDirectory
            .appendingPathComponent("dorax-legacy-backup-\(UUID().uuidString)", isDirectory: true)
        let stagingContent = stagingRoot.appendingPathComponent("legacy-extensions-backup", isDirectory: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        do {
            try fm.createDirectory(at: resolvedBackupDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: stagingContent, withIntermediateDirectories: true)

            for rel in presentPaths {
                let src = appSupportRoot.appendingPathComponent(rel)
                let dst = stagingContent.appendingPathComponent(rel)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dst)
            }

            // Create .zip via /usr/bin/ditto (argv-only, no shell string).
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", stagingContent.path, zipURL.path]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto failed"
                return LegacyCleanupReport(
                    backupZipURL: nil,
                    backedUpRelativePaths: [],
                    removedRelativePaths: [],
                    errorMessage: "Archive failed (exit \(process.terminationStatus)): \(errMsg)")
            }

            let attrs = try fm.attributesOfItem(atPath: zipURL.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                return LegacyCleanupReport(
                    backupZipURL: nil,
                    backedUpRelativePaths: [],
                    removedRelativePaths: [],
                    errorMessage: "Archive verification failed: zip file is empty")
            }
        } catch {
            return LegacyCleanupReport(
                backupZipURL: nil,
                backedUpRelativePaths: [],
                removedRelativePaths: [],
                errorMessage: error.localizedDescription)
        }

        if dryRun {
            return LegacyCleanupReport(
                backupZipURL: zipURL,
                backedUpRelativePaths: presentPaths,
                removedRelativePaths: [],
                errorMessage: nil)
        }

        var removed: [String] = []
        for rel in presentPaths {
            let target = appSupportRoot.appendingPathComponent(rel)
            do {
                try fm.removeItem(at: target)
                removed.append(rel)
            } catch {
                NSLog("Context-Dock: could not remove legacy path \(rel): \(error.localizedDescription)")
            }
        }

        return LegacyCleanupReport(
            backupZipURL: zipURL,
            backedUpRelativePaths: presentPaths,
            removedRelativePaths: removed,
            errorMessage: nil)
    }
}
