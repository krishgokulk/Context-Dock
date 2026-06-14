//
//  ExtensionManager.swift
//  ILauncher
//
//  Centralized extension registry that manages both built-in and custom extensions
//  Provides a single source of truth for all available extensions in the app
//

import Foundation
import AppKit

/// Centralized manager for all extensions (built-in and custom)
class ExtensionManager {
    static let shared = ExtensionManager()
    
    // MARK: - Properties
    
    private var registeredExtensions: [ScriptExtension] = []
    private var builtInExtensions: [ScriptExtension] = []
    private var fileBasedExtensions: [ScriptExtension] = []
    
    private var lastRefreshDate: Date?
    
    // MARK: - Initialization
    
    private init() {
        #if DEBUG
        print("🔧 [ExtensionManager] Initializing...")
        #endif
        registerBuiltInExtensions()
        refreshFileBasedExtensions()
    }
    
    // MARK: - Public API
    
    /// Get all available extensions
    func getAllExtensions() -> [ScriptExtension] {
        // Refresh file-based extensions if cache is stale (older than 5 minutes)
        if let lastRefresh = lastRefreshDate, Date().timeIntervalSince(lastRefresh) < 300 {
            // Use cache
            return registeredExtensions
        }
        
        // Refresh and rebuild
        refreshFileBasedExtensions()
        rebuildRegistry()
        return registeredExtensions
    }
    
    /// Get extensions filtered by category
    func getExtensions(for category: ScriptExtension.Category) -> [ScriptExtension] {
        return getAllExtensions().filter { $0.category == category }
    }
    
    /// Get extensions filtered by enabled state
    func getEnabledExtensions() -> [ScriptExtension] {
        let all = getAllExtensions()
        
        // Check settings to see if context AI extensions are enabled
        let contextAIEnabled = AppSettings.shared.enableContextAIExtensions
        
        if !contextAIEnabled {
            // Filter out AI category built-in extensions
            return all.filter { !($0.isBuiltIn && $0.category == .ai) }
        }
        
        return all
    }
    
    /// Find an extension by name
    func findExtension(byName name: String) -> ScriptExtension? {
        return getAllExtensions().first { ext in
            ext.name.lowercased() == name.lowercased() ||
            ext.displayName.lowercased() == name.lowercased()
        }
    }
    
    /// Force refresh all extensions
    func refresh() {
        #if DEBUG
        print("🔄 [ExtensionManager] Refreshing all extensions...")
        #endif
        refreshFileBasedExtensions()
        rebuildRegistry()
        lastRefreshDate = Date()
    }
    
    // MARK: - Built-In Extensions Registration
    
    private func registerBuiltInExtensions() {
        // Built-in extensions disabled — users add their own via Settings > Extensions
        builtInExtensions = []
    }
    
    // MARK: - File-Based Extensions Scanning
    
    private func refreshFileBasedExtensions() {
        #if DEBUG
        print("🔍 [ExtensionManager] Scanning file-based extensions...")
        #endif
        fileBasedExtensions = ExtensionScanner.shared.getExtensions()
        #if DEBUG
        print("✅ [ExtensionManager] Found \(fileBasedExtensions.count) file-based extensions")
        #endif
    }
    
    // MARK: - Registry Management
    
    private func rebuildRegistry() {
        // Combine built-in and file-based extensions
        registeredExtensions = builtInExtensions + fileBasedExtensions
        
        // Sort by category, then by name
        registeredExtensions.sort { lhs, rhs in
            if lhs.category == rhs.category {
                return lhs.displayName < rhs.displayName
            }
            return lhs.category.sortOrder < rhs.category.sortOrder
        }
        
        #if DEBUG
        print("📊 [ExtensionManager] Registry rebuilt: \(registeredExtensions.count) total extensions")
        #endif
        #if DEBUG
        print("   - Built-in: \(builtInExtensions.count)")
        #endif
        #if DEBUG
        print("   - File-based: \(fileBasedExtensions.count)")
        #endif
        
        // Print breakdown by category
        let categories = registeredExtensions.reduce(into: [:]) { dict, ext in
            dict[ext.category, default: 0] += 1
        }
        
        for (category, count) in categories {
            #if DEBUG
            print("   - \(category.displayName): \(count)")
            #endif
        }
    }
    
    // MARK: - Execution
    
    /// Execute an extension by name with given input
    func execute(extensionName: String, with input: String) async throws -> String {
        guard let ext = findExtension(byName: extensionName) else {
            throw ExtensionError.scriptNotFound
        }
        
        return try await execute(extension: ext, with: input)
    }
    
    /// Execute a specific extension
    func execute(extension ext: ScriptExtension, with input: String) async throws -> String {
        #if DEBUG
        print("⚡️ [ExtensionManager] Executing: \(ext.displayName)")
        #endif
        #if DEBUG
        print("   Input: \(input.prefix(100))\(input.count > 100 ? "..." : "")")
        #endif
        
        // Check if it's a built-in extension
        if ext.isBuiltIn, let builtInAction = ext.builtInAction {
            let result = try await builtInAction.execute(with: input)
            #if DEBUG
            print("✅ [ExtensionManager] Built-in execution completed")
            #endif
            return result
        }
        
        // Execute file-based extension
        let result = try await ext.execute(with: input)
        #if DEBUG
        print("✅ [ExtensionManager] File-based execution completed")
        #endif
        return result
    }
}

// MARK: - Category Sort Order

extension ScriptExtension.Category {
    var sortOrder: Int {
        switch self {
        case .ai: return 0
        case .starter: return 1
        case .status: return 2
        case .web: return 3
        case .custom: return 4
        }
    }
}

// MARK: - Extension Statistics

extension ExtensionManager {
    /// Get statistics about registered extensions
    func getStatistics() -> ExtensionStatistics {
        let all = getAllExtensions()
        
        return ExtensionStatistics(
            total: all.count,
            builtIn: all.filter { $0.isBuiltIn }.count,
            fileBased: all.filter { !$0.isBuiltIn }.count,
            byCategory: [
                .ai: all.filter { $0.category == .ai }.count,
                .status: all.filter { $0.category == .status }.count,
                .starter: all.filter { $0.category == .starter }.count,
                .web: all.filter { $0.category == .web }.count,
                .custom: all.filter { $0.category == .custom }.count,
            ],
            byType: [
                .shell: all.filter { $0.type == .shell }.count,
                .python: all.filter { $0.type == .python }.count,
                .appleScript: all.filter { $0.type == .appleScript }.count,
                .javascript: all.filter { $0.type == .javascript }.count,
                .ruby: all.filter { $0.type == .ruby }.count,
            ]
        )
    }
}

struct ExtensionStatistics {
    let total: Int
    let builtIn: Int
    let fileBased: Int
    let byCategory: [ScriptExtension.Category: Int]
    let byType: [ScriptExtension.ScriptType: Int]
    
    var description: String {
        var lines: [String] = []
        lines.append("📊 Extension Statistics")
        lines.append("   Total: \(total)")
        lines.append("   Built-in: \(builtIn)")
        lines.append("   File-based: \(fileBased)")
        lines.append("")
        lines.append("By Category:")
        for (category, count) in byCategory.sorted(by: { $0.key.sortOrder < $1.key.sortOrder }) {
            lines.append("   \(category.displayName): \(count)")
        }
        lines.append("")
        lines.append("By Type:")
        for (type, count) in byType.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append("   \(type.rawValue.uppercased()): \(count)")
        }
        return lines.joined(separator: "\n")
    }
}
