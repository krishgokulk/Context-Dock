//
//  SettingsBackupManager.swift
//  ILauncher
//
//  Export and import settings for backup and sync
//

import Foundation
import AppKit
import UniformTypeIdentifiers

class SettingsBackupManager {
    static let shared = SettingsBackupManager()

    private init() {}

    struct BackupData: Codable {
        let version: Int
        let exportDate: Date

        // App Settings
        let showMenuBarIcon: Bool
        let enableSpotlightSearch: Bool
        let useCustomSearchDirectories: Bool
        let hotkeyKeyCode: Int
        let hotkeyModifiers: Int

        // AI Settings
        let selectedAIProvider: String
        let ollamaEndpoint: String
        let selectedOllamaModel: String
        let shortcutsProviderShortcut: String

        // Appearance Settings
        let launcherWindowOpacity: Double
        let folderPreviewOpacity: Double

        // Pinned Apps
        let pinnedApps: [PinnedApp]

        // Search Directories (paths only, not bookmarks for portability)
        let searchDirectoryPaths: [String]

        // Permission settings
        let allowCalendars: Bool
        let allowReminders: Bool
        let allowPhotos: Bool
        let allowContacts: Bool
        let allowAutomation: Bool

        static let currentVersion = 1
    }

    /// Export settings to file
    func exportSettings() -> Result<URL, Error> {
        let settings = AppSettings.shared

        let backupData = BackupData(
            version: BackupData.currentVersion,
            exportDate: Date(),
            showMenuBarIcon: settings.showMenuBarIcon,
            enableSpotlightSearch: settings.enableSpotlightSearch,
            useCustomSearchDirectories: settings.useCustomSearchDirectories,
            hotkeyKeyCode: Int(settings.hotkeyKeyCode),
            hotkeyModifiers: Int(settings.hotkeyModifiers),
            selectedAIProvider: settings.selectedAIProvider.rawValue,
            ollamaEndpoint: settings.ollamaEndpoint,
            selectedOllamaModel: settings.selectedOllamaModel,
            shortcutsProviderShortcut: settings.shortcutsProviderShortcut,
            launcherWindowOpacity: settings.launcherWindowOpacity,
            folderPreviewOpacity: settings.folderPreviewOpacity,
            pinnedApps: settings.pinnedApps,
            searchDirectoryPaths: settings.searchDirectories.map { $0.path },
            allowCalendars: settings.allowCalendars,
            allowReminders: settings.allowReminders,
            allowPhotos: settings.allowPhotos,
            allowContacts: settings.allowContacts,
            allowAutomation: settings.allowAutomation
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(backupData)

            // Save to file
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "ILauncher-Settings-\(dateFormatter.string(from: Date())).json"
            panel.message = "Export ILauncher Settings"
            panel.prompt = "Export"

            guard panel.runModal() == .OK, let url = panel.url else {
                return .failure(NSError(domain: "SettingsBackup", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Export cancelled by user"
                ]))
            }

            try data.write(to: url, options: [.atomic])
            print("✅ Settings exported to: \(url.path)")

            return .success(url)
        } catch {
            print("⚠️ Failed to export settings: \(error)")
            return .failure(error)
        }
    }

    /// Import settings from file
    func importSettings() -> Result<Bool, Error> {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Import ILauncher Settings"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return .failure(NSError(domain: "SettingsBackup", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Import cancelled by user"
            ]))
        }

        do {
            let data = try Data(contentsOf: url)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let backupData = try decoder.decode(BackupData.self, from: data)

            // Verify version compatibility
            guard backupData.version == BackupData.currentVersion else {
                return .failure(NSError(domain: "SettingsBackup", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Incompatible settings version"
                ]))
            }

            // Apply settings
            let settings = AppSettings.shared

            settings.showMenuBarIcon = backupData.showMenuBarIcon
            settings.enableSpotlightSearch = backupData.enableSpotlightSearch
            settings.useCustomSearchDirectories = backupData.useCustomSearchDirectories
            settings.hotkeyKeyCode = UInt32(backupData.hotkeyKeyCode)
            settings.hotkeyModifiers = UInt32(backupData.hotkeyModifiers)
            settings.selectedAIProvider = AIProvider(rawValue: backupData.selectedAIProvider) ?? .onDevice
            settings.ollamaEndpoint = backupData.ollamaEndpoint
            settings.selectedOllamaModel = backupData.selectedOllamaModel
            settings.shortcutsProviderShortcut = backupData.shortcutsProviderShortcut
            settings.launcherWindowOpacity = backupData.launcherWindowOpacity
            settings.folderPreviewOpacity = backupData.folderPreviewOpacity
            settings.pinnedApps = backupData.pinnedApps
            settings.allowCalendars = backupData.allowCalendars
            settings.allowReminders = backupData.allowReminders
            settings.allowPhotos = backupData.allowPhotos
            settings.allowContacts = backupData.allowContacts
            settings.allowAutomation = backupData.allowAutomation

            // Import search directories (user will need to re-grant access)
            for path in backupData.searchDirectoryPaths {
                let displayName = URL(fileURLWithPath: path).lastPathComponent
                settings.addSearchDirectory(path: path, displayName: displayName)
            }

            print("✅ Settings imported from: \(url.path)")

            // Notify to reload UI
            NotificationCenter.default.post(name: .settingsImported, object: nil)

            return .success(true)
        } catch {
            print("⚠️ Failed to import settings: \(error)")
            return .failure(error)
        }
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }
}

// MARK: - Notification Names
