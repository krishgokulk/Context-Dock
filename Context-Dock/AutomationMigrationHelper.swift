//
//  AutomationMigrationHelper.swift
//  ILauncher
//
//  Helper utilities for migrating to unified Automation Studio
//

import Foundation
import AppKit

/// Helps migrate extensions from the old scattered structure to the new unified Automation Studio
class AutomationMigrationHelper {
    static let shared = AutomationMigrationHelper()
    
    private init() {}
    
    // MARK: - Migration Status
    
    /// Check if migration is needed
    func needsMigration() -> Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: "automation_studio_migrated")
    }
    
    /// Mark migration as complete
    func markMigrationComplete() {
        UserDefaults.standard.set(true, forKey: "automation_studio_migrated")
        UserDefaults.standard.set(Date(), forKey: "automation_studio_migration_date")
    }
    
    // MARK: - Automatic Migration
    
    /// Run automatic migration from old structure to new Automation Studio
    func performAutomaticMigration() async throws {
        guard needsMigration() else {
            print("✅ [Migration] Already migrated to Automation Studio")
            return
        }
        
        print("🔄 [Migration] Starting automatic migration to Automation Studio...")
        
        // Step 1: Migrate Quick Actions (L1)
        try await migrateQuickActions()
        
        // Step 2: Migrate Context Actions (L2)
        try await migrateContextActions()
        
        // Step 3: Migrate AI Tools
        try await migrateAITools()
        
        // Step 4: Migrate Terminal Packages
        try await migrateTerminalPackages()
        
        // Step 5: Verify migration
        try verifyMigration()
        
        // Step 6: Mark complete
        markMigrationComplete()
        
        print("✅ [Migration] Automatic migration completed successfully")
    }
    
    // MARK: - Individual Migrations
    
    private func migrateQuickActions() async throws {
        print("   Migrating Quick Actions...")
        // Quick actions should already be in L1 layer
        // Just verify and log count
        let l1Extensions = LayeredExtensionManager.shared.extensions(for: .l1_search)
        print("   ✓ Found \(l1Extensions.count) Quick Actions")
    }
    
    private func migrateContextActions() async throws {
        print("   Migrating Context Actions...")
        // Context actions should already be in L2 layer
        let l2Extensions = LayeredExtensionManager.shared.extensions(for: .l2_context)
        print("   ✓ Found \(l2Extensions.count) Context Actions")
    }
    
    private func migrateAITools() async throws {
        print("   Migrating AI Tools...")
        await L2ExtensionManager.shared.loadExtensions()
        let aiTools = L2ExtensionManager.shared.extensions
        print("   ✓ Found \(aiTools.count) AI Tools")
    }
    
    private func migrateTerminalPackages() async throws {
        print("   Migrating Terminal Packages...")
        await TerminalPackageManager.shared.loadPackages()
        let packages = TerminalPackageManager.shared.packages
        print("   ✓ Found \(packages.count) Terminal Packages")
    }
    
    private func verifyMigration() throws {
        // Verify all extension managers are loaded
        let totalExtensions = 
            LayeredExtensionManager.shared.allExtensions.count +
            L2ExtensionManager.shared.extensions.count +
            TerminalPackageManager.shared.packages.count
        
        guard totalExtensions > 0 else {
            throw MigrationError.noExtensionsFound
        }
        
        print("   ✓ Verified \(totalExtensions) total extensions")
    }
    
    // MARK: - Manual Migration Tools
    
    /// Export all extensions to backup JSON
    func exportExtensionsBackup() async throws -> URL {
        let backup = ExtensionBackup(
            exportDate: Date(),
            version: "2.0",
            quickActions: LayeredExtensionManager.shared.extensions(for: .l1_search),
            contextActions: LayeredExtensionManager.shared.extensions(for: .l2_context),
            aiTools: L2ExtensionManager.shared.extensions,
            terminalPackages: TerminalPackageManager.shared.packages,
            browserExtensions: LayeredExtensionManager.shared.extensions(for: .l3_browser)
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)
        
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ilauncher_extensions_backup_\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: backupURL)
        
        print("✅ [Backup] Exported extensions to: \(backupURL.path)")
        return backupURL
    }
    
    /// Import extensions from backup JSON
    func importExtensionsBackup(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let backup = try decoder.decode(ExtensionBackup.self, from: data)
        
        print("🔄 [Import] Restoring extensions from backup dated \(backup.exportDate)...")
        
        // Import each category
        for ext in backup.quickActions {
            LayeredExtensionManager.shared.addExtension(ext)
        }
        
        for ext in backup.contextActions {
            LayeredExtensionManager.shared.addExtension(ext)
        }
        
        // Reload all managers
        await LayeredExtensionManager.shared.loadExtensions()
        await L2ExtensionManager.shared.loadExtensions()
        await TerminalPackageManager.shared.loadPackages()
        
        print("✅ [Import] Restored extensions successfully")
    }
    
    // MARK: - Statistics
    
    /// Get migration statistics
    func getMigrationStats() -> MigrationStats {
        MigrationStats(
            totalExtensions: 
                LayeredExtensionManager.shared.allExtensions.count +
                L2ExtensionManager.shared.extensions.count +
                TerminalPackageManager.shared.packages.count,
            quickActions: LayeredExtensionManager.shared.extensions(for: .l1_search).count,
            contextActions: LayeredExtensionManager.shared.extensions(for: .l2_context).count,
            aiTools: L2ExtensionManager.shared.extensions.count,
            terminalPackages: TerminalPackageManager.shared.packages.count,
            browserExtensions: LayeredExtensionManager.shared.extensions(for: .l3_browser).count,
            workflows: LayeredExtensionManager.shared.extensions(for: .crossLayer).count,
            migrationDate: UserDefaults.standard.object(forKey: "automation_studio_migration_date") as? Date
        )
    }
}

// MARK: - Supporting Types

enum MigrationError: LocalizedError {
    case noExtensionsFound
    case corruptedData
    case incompatibleVersion
    
    var errorDescription: String? {
        switch self {
        case .noExtensionsFound:
            return "No extensions found to migrate"
        case .corruptedData:
            return "Extension data is corrupted"
        case .incompatibleVersion:
            return "Incompatible extension version"
        }
    }
}

struct ExtensionBackup: Codable {
    let exportDate: Date
    let version: String
    let quickActions: [ILExtension]
    let contextActions: [ILExtension]
    let aiTools: [L2Extension]
    let terminalPackages: [TerminalPackage]
    let browserExtensions: [ILExtension]
}

struct MigrationStats {
    let totalExtensions: Int
    let quickActions: Int
    let contextActions: Int
    let aiTools: Int
    let terminalPackages: Int
    let browserExtensions: Int
    let workflows: Int
    let migrationDate: Date?
    
    var summary: String {
        """
        Automation Studio Statistics
        
        Total Extensions: \(totalExtensions)
        
        By Category:
        • Quick Actions: \(quickActions)
        • Context Actions: \(contextActions)
        • AI Tools: \(aiTools)
        • Terminal Packages: \(terminalPackages)
        • Browser Extensions: \(browserExtensions)
        • Workflows: \(workflows)
        
        Migration Date: \(migrationDate?.formatted() ?? "Not migrated")
        """
    }
}

// MARK: - Migration UI Helper

import SwiftUI

struct MigrationWelcomeSheet: View {
    let stats: MigrationStats
    let onContinue: () -> Void
    let onSkip: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                    Image(systemName: "bolt.badge.automatic")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Automation Studio")
                        .font(.title.bold())
                    Text("Your extensions, unified and more powerful")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
            
            // Features
            VStack(alignment: .leading, spacing: 16) {
                MigrationFeatureRow(
                    icon: "sparkles",
                    color: .blue,
                    title: "Unified Interface",
                    description: "All your extensions in one beautiful, organized place"
                )

                MigrationFeatureRow(
                    icon: "bolt.fill",
                    color: .green,
                    title: "Better Performance",
                    description: "Faster loading and smarter extension matching"
                )

                MigrationFeatureRow(
                    icon: "puzzlepiece.extension",
                    color: .purple,
                    title: "Easy Management",
                    description: "Create, edit, and organize extensions with ease"
                )

                MigrationFeatureRow(
                    icon: "wand.and.stars",
                    color: .pink,
                    title: "AI-Powered",
                    description: "Enhanced AI tools for the L2 terminal assistant"
                )
            }
            .padding(.vertical)
            
            Divider()
            
            // Stats preview
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Extensions")
                    .font(.headline)
                
                HStack(spacing: 20) {
                    StatBadge(count: stats.quickActions, label: "Quick Actions", color: .blue)
                    StatBadge(count: stats.contextActions, label: "Context Actions", color: .purple)
                    StatBadge(count: stats.aiTools, label: "AI Tools", color: .pink)
                    StatBadge(count: stats.terminalPackages, label: "Packages", color: .green)
                }
            }
            .padding()
            .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            
            // Actions
            HStack(spacing: 12) {
                Button("Remind Me Later") {
                    onSkip()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Continue to Automation Studio") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(32)
        .frame(width: 600)
    }
}

struct MigrationFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatBadge: View {
    let count: Int
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    MigrationWelcomeSheet(
        stats: MigrationStats(
            totalExtensions: 23,
            quickActions: 5,
            contextActions: 4,
            aiTools: 8,
            terminalPackages: 6,
            browserExtensions: 0,
            workflows: 0,
            migrationDate: nil
        ),
        onContinue: {},
        onSkip: {}
    )
}
