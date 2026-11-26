// Context-Dock/Services/Plugins/DoraxPackV3EditorService.swift
// Context-Dock
//
// Phase 1: In-Place `.doraxpack` v3 Pack Copy-on-Write Override, Backup Snapshots,
// Safe Multi-File Patch Application, Rollback, and Reset to Shipped Default.
//
// Shipped packs live read-only inside `Packs/`. Whenever a user upgrades or edits any
// pack with AI (or merges a Raycast extension into it), this service copies the bundle
// into `~/Library/Application Support/Context-Dock/plugins/v3/<id>.doraxpack`, saves a
// timestamped snapshot in `plugins/v3/.backups/<id>/<timestamp>/` before writing, validates
// every changed file via `DoraxPackV3Validator`, and rolls back automatically on error.

import Foundation

struct DoraxPackBackupSnapshot: Identifiable, Equatable {
    let id: String
    let packID: String
    let createdAt: Date
    let folderURL: URL
}

struct DoraxPackV3FileChange: Identifiable, Equatable {
    var id: String { relativePath }
    let relativePath: String
    let content: String
    let isNew: Bool
}

struct DoraxPackV3Patch: Equatable {
    let packID: String
    let packName: String
    let summary: String
    let updatedPackJSON: String
    let files: [DoraxPackV3FileChange]
    let addedPermissions: [String]
    let addedHooks: [String]
    let diagnostics: [PluginDiagnostic]
    let dryRunOutput: DoraxCommandOutput?
    let dryRunError: String?
    let stagedFolderURL: URL

    var hasBlockingErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

enum DoraxPackEditorError: Error, LocalizedError {
    case invalidRelativePath(String)
    case invalidPackJSON(String)
    case validationFailed([String])
    case noBackupAvailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let p):
            return "Rejected unsafe relative path in pack patch: \(p)"
        case .invalidPackJSON(let msg):
            return "Invalid pack.json in patch: \(msg)"
        case .validationFailed(let msgs):
            return "Validation failed (rolled back): \(msgs.joined(separator: "; "))"
        case .noBackupAvailable(let id):
            return "No backup snapshots available for pack \"\(id)\"."
        }
    }
}

@MainActor
final class DoraxPackV3EditorService {
    static let shared = DoraxPackV3EditorService()

    private let maxBackupsPerPack = 10

    init() {}

    // MARK: - Path Resolution

    func defaultV3Root() -> URL {
        DoraxPackV3Registry.userV3Directory
    }

    func defaultBackupRoot(v3Root: URL? = nil) -> URL {
        (v3Root ?? defaultV3Root()).appendingPathComponent(".backups", isDirectory: true)
    }

    func editableFolderURL(for packID: String, v3Root: URL? = nil) -> URL {
        (v3Root ?? defaultV3Root()).appendingPathComponent("\(packID).doraxpack", isDirectory: true)
    }

    func isUserOverride(packID: String, v3Root: URL? = nil) -> Bool {
        let fm = FileManager.default
        let dir = editableFolderURL(for: packID, v3Root: v3Root)
        return fm.fileExists(atPath: dir.appendingPathComponent("pack.json").path)
    }

    func shippedPackURL(packID: String, packsDirectory: URL? = nil) -> URL? {
        guard let dir = packsDirectory ?? FirstPartyPacks.resolvePacksDirectory() else { return nil }
        for url in DoraxPackV2Loader.discoverPacks(in: dir) {
            if let loaded = try? DoraxPackV2Loader.load(from: url),
               loaded.id.lowercased() == packID.lowercased()
            {
                return url
            }
        }
        return nil
    }

    func hasShippedDefault(packID: String, packsDirectory: URL? = nil) -> Bool {
        shippedPackURL(packID: packID, packsDirectory: packsDirectory) != nil
    }

    // MARK: - Copy-on-Write & Backups

    @discardableResult
    func ensureEditableCopy(of pack: DoraxPackV2, v3Root: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let root = v3Root ?? defaultV3Root()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destURL = editableFolderURL(for: pack.id, v3Root: root)
        if !fm.fileExists(atPath: destURL.appendingPathComponent("pack.json").path) {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            if fm.fileExists(atPath: pack.folderURL.path) {
                try fm.copyItem(at: pack.folderURL, to: destURL)
            } else {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(pack.metadata)
                try data.write(to: destURL.appendingPathComponent("pack.json"), options: .atomic)
            }
        }
        return destURL
    }

    @discardableResult
    func createBackup(packID: String, from sourceFolder: URL, backupRoot: URL? = nil) throws -> DoraxPackBackupSnapshot {
        let fm = FileManager.default
        let packBackupDir = (backupRoot ?? defaultBackupRoot())
            .appendingPathComponent(packID, isDirectory: true)
        try fm.createDirectory(at: packBackupDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date()) + "-\(UUID().uuidString.prefix(4))"
        let snapURL = packBackupDir.appendingPathComponent(stamp, isDirectory: true)
        try fm.copyItem(at: sourceFolder, to: snapURL)

        pruneOldBackups(in: packBackupDir)
        return DoraxPackBackupSnapshot(id: stamp, packID: packID, createdAt: Date(), folderURL: snapURL)
    }

    func listBackups(for packID: String, backupRoot: URL? = nil) -> [DoraxPackBackupSnapshot] {
        let fm = FileManager.default
        let packBackupDir = (backupRoot ?? defaultBackupRoot())
            .appendingPathComponent(packID, isDirectory: true)
        guard let urls = try? fm.contentsOfDirectory(
            at: packBackupDir,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return urls.compactMap { url in
            guard fm.fileExists(atPath: url.appendingPathComponent("pack.json").path) else { return nil }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let created = (attrs?[.creationDate] as? Date) ?? Date.distantPast
            return DoraxPackBackupSnapshot(id: url.lastPathComponent, packID: packID, createdAt: created, folderURL: url)
        }
        .sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id > b.id
        }
    }

    private func pruneOldBackups(in packBackupDir: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: packBackupDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let sorted = urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
        if sorted.count > maxBackupsPerPack {
            for old in sorted.dropFirst(maxBackupsPerPack) {
                try? fm.removeItem(at: old)
            }
        }
    }

    // MARK: - Path Guardrail

    static func validateRelativePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("\\"),
              !trimmed.contains("..")
        else { return nil }
        let components = trimmed.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return components.joined(separator: "/")
    }

    // MARK: - Apply Patch, Rollback & Reset

    @discardableResult
    func applyPatch(
        _ patch: DoraxPackV3Patch,
        to basePack: DoraxPackV2,
        v3Root: URL? = nil,
        backupRoot: URL? = nil,
        registry: DoraxPackV3Registry = .shared,
        persistToDisk: Bool = !AppDelegate.isHostingTests
    ) throws -> DoraxPackV2 {
        let root = v3Root ?? defaultV3Root()
        let bRoot = backupRoot ?? defaultBackupRoot(v3Root: root)

        // Pre-flight decode & path safety check BEFORE touching user pack folder
        guard let packJSONData = patch.updatedPackJSON.data(using: .utf8),
              let decodedMeta = try? JSONDecoder().decode(DoraxPackMetadata.self, from: packJSONData)
        else {
            throw DoraxPackEditorError.invalidPackJSON("Updated pack.json could not be decoded as DoraxPackMetadata.")
        }
        guard decodedMeta.formatVersion == 2 || decodedMeta.formatVersion == 3 else {
            throw DoraxPackEditorError.invalidPackJSON("format_version must be 2 or 3.")
        }

        for change in patch.files {
            if Self.validateRelativePath(change.relativePath) == nil {
                throw DoraxPackEditorError.invalidRelativePath(change.relativePath)
            }
        }

        // Copy-on-Write into plugins/v3/<id>.doraxpack and snapshot current state
        let editableDir = try ensureEditableCopy(of: basePack, v3Root: root)
        let snapshot = try createBackup(packID: basePack.id, from: editableDir, backupRoot: bRoot)

        let fm = FileManager.default
        do {
            try Data(patch.updatedPackJSON.utf8).write(
                to: editableDir.appendingPathComponent("pack.json"), options: .atomic)

            for change in patch.files {
                guard let safeRel = Self.validateRelativePath(change.relativePath) else { continue }
                let destFile = editableDir.appendingPathComponent(safeRel)
                try fm.createDirectory(at: destFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(change.content.utf8).write(to: destFile, options: .atomic)
                if ["py", "sh", "zsh"].contains(destFile.pathExtension.lowercased()) {
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destFile.path)
                }
            }

            let reloaded = try DoraxPackV2Loader.load(from: editableDir)
            let errors = DoraxPackV3Validator.validate(reloaded).filter { $0.severity == .error }
            if !errors.isEmpty {
                throw DoraxPackEditorError.validationFailed(errors.map(\.message))
            }

            _ = try? StorePackInstaller.installV2(reloaded, persistToDisk: persistToDisk)
            registry.register(reloaded)
            NotificationCenter.default.post(name: .globalSearchIndexRebuildRequested, object: nil)
            return reloaded
        } catch {
            // Rollback automatically to the snapshot created seconds ago
            if fm.fileExists(atPath: snapshot.folderURL.path) {
                try? fm.removeItem(at: editableDir)
                try? fm.copyItem(at: snapshot.folderURL, to: editableDir)
            }
            throw error
        }
    }

    @discardableResult
    func rollback(
        packID: String,
        to snapshot: DoraxPackBackupSnapshot? = nil,
        v3Root: URL? = nil,
        backupRoot: URL? = nil,
        registry: DoraxPackV3Registry = .shared,
        persistToDisk: Bool = !AppDelegate.isHostingTests
    ) throws -> DoraxPackV2 {
        let root = v3Root ?? defaultV3Root()
        let bRoot = backupRoot ?? defaultBackupRoot(v3Root: root)
        let chosen = snapshot ?? listBackups(for: packID, backupRoot: bRoot).first
        guard let targetSnap = chosen else {
            throw DoraxPackEditorError.noBackupAvailable(packID)
        }

        let fm = FileManager.default
        let destDir = editableFolderURL(for: packID, v3Root: root)
        if fm.fileExists(atPath: destDir.path) {
            try fm.removeItem(at: destDir)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: targetSnap.folderURL, to: destDir)

        let restored = try DoraxPackV2Loader.load(from: destDir)
        _ = try? StorePackInstaller.installV2(restored, persistToDisk: persistToDisk)
        registry.register(restored)
        NotificationCenter.default.post(name: .globalSearchIndexRebuildRequested, object: nil)
        return restored
    }

    @discardableResult
    func resetToDefault(
        packID: String,
        v3Root: URL? = nil,
        packsDirectory: URL? = nil,
        registry: DoraxPackV3Registry = .shared,
        persistToDisk: Bool = !AppDelegate.isHostingTests
    ) throws -> DoraxPackV2? {
        let root = v3Root ?? defaultV3Root()
        let overrideDir = editableFolderURL(for: packID, v3Root: root)
        let fm = FileManager.default
        if fm.fileExists(atPath: overrideDir.path) {
            try fm.removeItem(at: overrideDir)
        }
        if let shipped = shippedPackURL(packID: packID, packsDirectory: packsDirectory),
           let loaded = try? DoraxPackV2Loader.load(from: shipped)
        {
            _ = try? StorePackInstaller.installV2(loaded, persistToDisk: persistToDisk)
            registry.register(loaded)
            NotificationCenter.default.post(name: .globalSearchIndexRebuildRequested, object: nil)
            return loaded
        }
        registry.reload()
        NotificationCenter.default.post(name: .globalSearchIndexRebuildRequested, object: nil)
        return registry.pack(id: packID)
    }
}
