//
//  FileIndexManager.swift
//  ILauncher
//
//  Created by Krishgokul on 21/11/2025.
//

import Foundation
import AppKit
import Combine

// MARK: - Indexed File Model
struct IndexedFile: Codable, Identifiable {
    let id: UUID
    let name: String
    let path: String
    let isDirectory: Bool
    let fileExtension: String
    let parentPath: String
    let modificationDate: Date
    let size: Int64
    
    // Computed property - not stored in cache
    var displayName: String {
        return name
    }
    
    init(url: URL, attributes: [FileAttributeKey: Any]) {
        self.id = UUID()
        self.name = url.lastPathComponent
        self.path = url.path
        self.isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        self.fileExtension = url.pathExtension.lowercased()
        self.parentPath = url.deletingLastPathComponent().path
        self.modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
        self.size = (attributes[.size] as? Int64) ?? 0
    }
    
    // Custom coding keys to exclude icon from serialization
    enum CodingKeys: String, CodingKey {
        case id, name, path, isDirectory, fileExtension, parentPath, modificationDate, size
    }
}

// MARK: - Index Metadata
struct IndexMetadata: Codable {
    var lastFullIndexDate: Date?
    var indexedDirectories: [String]
    var totalFilesIndexed: Int
    var indexVersion: Int
    
    static let currentVersion = 1
    
    init() {
        self.lastFullIndexDate = nil
        self.indexedDirectories = []
        self.totalFilesIndexed = 0
        self.indexVersion = Self.currentVersion
    }
}

// MARK: - Indexing Progress
struct IndexingProgress {
    var isIndexing: Bool = false
    var currentDirectory: String = ""
    var filesIndexed: Int = 0
    var totalDirectories: Int = 0
    var processedDirectories: Int = 0
    var errors: [IndexingError] = []
    var lastError: String? = nil

    var progressPercentage: Double {
        guard totalDirectories > 0 else { return 0 }
        return Double(processedDirectories) / Double(totalDirectories) * 100
    }
}

// MARK: - Indexing Error
struct IndexingError: Identifiable {
    let id = UUID()
    let path: String
    let message: String
    let timestamp: Date

    init(path: String, message: String) {
        self.path = path
        self.message = message
        self.timestamp = Date()
    }
}

// MARK: - File Index Manager
@MainActor
class FileIndexManager: ObservableObject {
    static let shared = FileIndexManager()
    
    // MARK: - Published Properties
    @Published private(set) var indexedFiles: [IndexedFile] = []
    @Published private(set) var progress = IndexingProgress()
    @Published private(set) var isReady = false
    @Published private(set) var metadata = IndexMetadata()
    
    // MARK: - Private Properties
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let indexCacheURL: URL
    private let metadataCacheURL: URL
    
    // Search index for fast lookups
    private var searchIndex: [String: [IndexedFile]] = [:]  // First character -> files
    private var nameIndex: [String: [IndexedFile]] = [:]     // Lowercased name -> files

    // File system watcher for real-time updates
    private var fileSystemWatcher: FileSystemWatcher?
    
    // Directories to skip during indexing
    private let excludedDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".npm", ".cargo",
        "Library/Caches", "Library/Logs", ".Trash", "System",
        ".DS_Store", "__pycache__", ".build", "DerivedData",
        "xcuserdata", ".xcodeproj", ".xcworkspace"
    ]
    
    // File extensions to exclude
    private let excludedExtensions: Set<String> = [
        "pyc", "pyo", "o", "obj", "class", "dSYM"
    ]
    
    // MARK: - Initialization
    private init() {
        // Setup cache directory
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDirectory = appSupport.appendingPathComponent("ILauncher", isDirectory: true)
        indexCacheURL = cacheDirectory.appendingPathComponent("file_index.json")
        metadataCacheURL = cacheDirectory.appendingPathComponent("index_metadata.json")
        
        // Create cache directory if needed
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        print("📁 FileIndexManager initialized")
        print("   Cache directory: \(cacheDirectory.path)")
    }
    
    // MARK: - Public Methods
    
    /// Initialize the index - call this on app launch
    func initialize() async {
        print("🔄 Initializing file index...")
        print("   enableSpotlightSearch: \(AppSettings.shared.enableSpotlightSearch)")
        print("   useCustomSearchDirectories: \(AppSettings.shared.useCustomSearchDirectories)")
        
        // Try to load cached index first
        if await loadCachedIndex() {
            print("✅ Loaded cached index with \(indexedFiles.count) files")
            isReady = true
            buildSearchIndex()
            
            // Check if we need to re-index (e.g., index is old)
            if shouldReindex() {
                print("📝 Index is stale, starting background re-index...")
                Task.detached(priority: .background) {
                    await self.performFullIndex()
                }
            }
        } else {
            print("📝 No cached index found or cache invalid, starting full index...")
            await performFullIndex()
        }
        
        print("📊 Final state: isReady=\(isReady), indexedFiles=\(indexedFiles.count)")
    }
    
    /// Force a full re-index
    func forceReindex() async {
        print("🔄 Force re-indexing...")

        // Reset indexing flag first to allow forced reindex
        await MainActor.run {
            progress.isIndexing = false
        }

        await performFullIndex()
    }
    
    /// Search indexed files with fuzzy matching
    func search(query: String, limit: Int = 50) -> [SearchResult] {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        
        var results: [(file: IndexedFile, score: Double)] = []
        
        // Strategy 1: Exact prefix match on first character
        if let firstChar = query.first {
            let key = String(firstChar)
            if let candidates = searchIndex[key] {
                for file in candidates {
                    if let score = FuzzyMatcher.score(query, against: file.name.lowercased()) {
                        results.append((file, score))
                    }
                }
            }
        }
        
        // Strategy 2: Search in name index for longer queries
        if query.count >= 2 {
            let queryPrefix = String(query.prefix(3))
            for (name, files) in nameIndex {
                if name.contains(query) || name.hasPrefix(queryPrefix) {
                    for file in files {
                        // Avoid duplicates
                        if !results.contains(where: { $0.file.path == file.path }) {
                            if let score = FuzzyMatcher.score(query, against: file.name.lowercased()) {
                                results.append((file, score))
                            }
                        }
                    }
                }
            }
        }
        
        // Sort by score and limit results
        results.sort { $0.score > $1.score }
        let topResults = results.prefix(limit)
        
        // Convert to SearchResult
        return topResults.map { item in
            let file = item.file
            let icon = NSWorkspace.shared.icon(forFile: file.path)
            icon.size = NSSize(width: 32, height: 32)
            
            let resultType: SearchResult.ResultType = file.isDirectory ? .folder :
                                                      (file.fileExtension.isEmpty ? .file : .document)
            
            // Format path for display
            let homeDir = fileManager.homeDirectoryForCurrentUser.path
            let displayPath = file.path.replacingOccurrences(of: homeDir, with: "~")
            
            // Get file type description
            let fileType: String
            if file.isDirectory {
                fileType = "Folder"
            } else if !file.fileExtension.isEmpty {
                fileType = file.fileExtension.uppercased()
            } else {
                fileType = "File"
            }
            
            return SearchResult(
                title: file.name,
                subtitle: "\(fileType) • \(displayPath)",
                icon: icon,
                action: {
                    NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                },
                score: item.score,
                type: resultType,
                filePath: file.path,
                contactData: nil
            )
        }
    }
    
    /// Get index statistics
    var statistics: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        
        var stats = "Files indexed: \(indexedFiles.count)"
        if let lastIndex = metadata.lastFullIndexDate {
            stats += "\nLast indexed: \(formatter.string(from: lastIndex))"
        }
        return stats
    }
    
    // MARK: - Private Methods
    
    private func shouldReindex() -> Bool {
        guard let lastIndex = metadata.lastFullIndexDate else { return true }
        
        // Re-index if more than 24 hours old
        let hoursSinceLastIndex = Date().timeIntervalSince(lastIndex) / 3600
        return hoursSinceLastIndex > 24
    }
    
    private func performFullIndex() async {
        // Prevent multiple concurrent indexing operations
        let isAlreadyIndexing = await MainActor.run { progress.isIndexing }
        if isAlreadyIndexing {
            print("⚠️ Indexing already in progress, skipping...")
            return
        }

        await MainActor.run {
            progress.isIndexing = true
            progress.filesIndexed = 0
            progress.processedDirectories = 0
            progress.errors = []
            progress.lastError = nil
        }

        let settings = AppSettings.shared
        
        // Determine directories to index
        var directoriesToIndex: [String] = []
        
        if settings.useCustomSearchDirectories && !settings.searchDirectories.isEmpty {
            // Start accessing security-scoped resources for custom directories
            settings.startAccessingSearchDirectories()
            directoriesToIndex = settings.searchDirectories.map { $0.path }
            print("📂 Using custom search directories: \(directoriesToIndex)")
        } else {
            // Default directories
            let home = fileManager.homeDirectoryForCurrentUser.path
            print("📂 Home directory: \(home)")
            
            let potentialDirectories = [
                "\(home)/Documents",
                "\(home)/Downloads",
                "\(home)/Desktop",
                "\(home)/Pictures",
                "\(home)/Movies",
                "\(home)/Music",
                "\(home)/Projects",
                "\(home)/Developer"
            ]
            
            for dir in potentialDirectories {
                let exists = fileManager.fileExists(atPath: dir)
                let readable = fileManager.isReadableFile(atPath: dir)
                print("   \(dir): exists=\(exists), readable=\(readable)")
                if exists && readable {
                    directoriesToIndex.append(dir)
                }
            }
        }
        
        if directoriesToIndex.isEmpty {
            let errorMsg = "No directories to index. Check permissions or add custom directories in settings."
            print("⚠️ \(errorMsg)")
            await MainActor.run {
                progress.isIndexing = false
                progress.lastError = errorMsg
                isReady = true // Mark as ready but empty
            }
            return
        }
        
        await MainActor.run {
            progress.totalDirectories = directoriesToIndex.count
        }
        
        print("📂 Indexing \(directoriesToIndex.count) directories...")
        
        var allFiles: [IndexedFile] = []
        
        for directory in directoriesToIndex {
            await MainActor.run {
                progress.currentDirectory = directory
            }

            do {
                let files = try await indexDirectoryWithErrorHandling(at: directory)
                allFiles.append(contentsOf: files)

                await MainActor.run {
                    progress.processedDirectories += 1
                    progress.filesIndexed = allFiles.count
                }

                print("   ✓ \(directory): \(files.count) files")
            } catch let err {
                let indexError = IndexingError(path: directory, message: err.localizedDescription)
                await MainActor.run {
                    progress.errors.append(indexError)
                    progress.lastError = "Failed to index \(directory): \(indexError.message)"
                    progress.processedDirectories += 1
                }
                print("   ✗ \(directory): \(err.localizedDescription)")
            }
        }
        
        // Update state
        await MainActor.run {
            indexedFiles = allFiles
            metadata.lastFullIndexDate = Date()
            metadata.indexedDirectories = directoriesToIndex
            metadata.totalFilesIndexed = allFiles.count
            progress.isIndexing = false
            isReady = true
        }
        
        // Build search index
        buildSearchIndex()

        // Save to cache
        await saveCachedIndex()

        // Setup file system watcher for real-time updates
        setupFileSystemWatcher(for: directoriesToIndex)

        print("✅ Indexing complete: \(allFiles.count) files indexed")
    }

    /// Setup file system watcher for real-time updates
    private func setupFileSystemWatcher(for directories: [String]) {
        // Stop existing watcher if any
        fileSystemWatcher?.stopWatching()

        guard !directories.isEmpty else { return }

        fileSystemWatcher = FileSystemWatcher(paths: directories) { [weak self] changedPaths in
            guard let self = self else { return }

            Task { @MainActor in
                // Debounce: wait a bit to batch multiple changes
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                await self.handleFileSystemChanges(changedPaths)
            }
        }

        fileSystemWatcher?.startWatching()
    }

    /// Handle file system changes detected by FSEvents
    private func handleFileSystemChanges(_ changedPaths: [String]) async {
        print("🔄 File system changes detected: \(changedPaths.count) paths")

        // For simplicity, trigger a background re-index
        // In a production app, you'd want to incrementally update the index
        Task.detached(priority: .utility) {
            await self.performFullIndex()
        }
    }
    
    /// Index directory with error handling
    private func indexDirectoryWithErrorHandling(at path: String) async throws -> [IndexedFile] {
        // Check if directory exists and is accessible
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "FileIndexManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Directory does not exist or is not accessible"
            ])
        }

        // Check if we have read permission
        guard fileManager.isReadableFile(atPath: path) else {
            throw NSError(domain: "FileIndexManager", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No read permission for directory"
            ])
        }

        return await indexDirectory(at: path)
    }

    private func indexDirectory(at path: String) async -> [IndexedFile] {
        var files: [IndexedFile] = []
        
        // Check if directory exists and is accessible
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            print("⚠️ Directory does not exist or is not accessible: \(path)")
            return files
        }
        
        // Check if we have read permission
        guard fileManager.isReadableFile(atPath: path) else {
            print("⚠️ No read permission for: \(path)")
            return files
        }
        
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .isHiddenKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                print("⚠️ Error enumerating \(url.path): \(error.localizedDescription)")
                return true // Continue enumeration despite errors
            }
        ) else {
            print("⚠️ Could not enumerate: \(path)")
            return files
        }
        
        for case let fileURL as URL in enumerator {
            // Skip excluded directories
            let pathComponents = fileURL.pathComponents
            if pathComponents.contains(where: { excludedDirectories.contains($0) }) {
                if fileURL.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }
            
            // Skip app bundles (we index those separately)
            if fileURL.pathExtension == "app" {
                enumerator.skipDescendants()
                continue
            }
            
            // Skip excluded extensions
            if excludedExtensions.contains(fileURL.pathExtension.lowercased()) {
                continue
            }
            
            // Get file attributes
            do {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                let indexedFile = IndexedFile(url: fileURL, attributes: attributes)
                files.append(indexedFile)
                
                // Update progress periodically
                if files.count % 1000 == 0 {
                    await MainActor.run {
                        progress.filesIndexed = files.count
                    }
                }
            } catch {
                // Skip files we can't read
                continue
            }
        }
        
        return files
    }
    
    private func buildSearchIndex() {
        searchIndex.removeAll()
        nameIndex.removeAll()
        
        for file in indexedFiles {
            let lowerName = file.name.lowercased()
            
            // Index by first character
            if let firstChar = lowerName.first {
                let key = String(firstChar)
                if searchIndex[key] == nil {
                    searchIndex[key] = []
                }
                searchIndex[key]?.append(file)
            }
            
            // Index by full name
            if nameIndex[lowerName] == nil {
                nameIndex[lowerName] = []
            }
            nameIndex[lowerName]?.append(file)
        }
        
        print("🔍 Search index built: \(searchIndex.keys.count) character keys, \(nameIndex.keys.count) name entries")
    }
    
    // MARK: - Cache Management
    
    private func loadCachedIndex() async -> Bool {
        // Load metadata first
        if fileManager.fileExists(atPath: metadataCacheURL.path) {
            do {
                let data = try Data(contentsOf: metadataCacheURL)
                let loadedMetadata = try JSONDecoder().decode(IndexMetadata.self, from: data)
                
                // Check version compatibility
                guard loadedMetadata.indexVersion == IndexMetadata.currentVersion else {
                    print("⚠️ Index version mismatch, need to rebuild")
                    return false
                }
                
                await MainActor.run {
                    metadata = loadedMetadata
                }
            } catch {
                print("⚠️ Failed to load metadata: \(error)")
                return false
            }
        } else {
            return false
        }
        
        // Load file index
        guard fileManager.fileExists(atPath: indexCacheURL.path) else {
            return false
        }
        
        do {
            let data = try Data(contentsOf: indexCacheURL)
            let loadedFiles = try JSONDecoder().decode([IndexedFile].self, from: data)
            
            // If no files in cache, need to rebuild
            guard !loadedFiles.isEmpty else {
                print("⚠️ Cache is empty, need to rebuild")
                return false
            }
            
            // Verify files still exist (sample check)
            let sampleSize = min(100, loadedFiles.count)
            let sampleIndices = (0..<loadedFiles.count).shuffled().prefix(sampleSize)
            var validCount = 0
            
            for index in sampleIndices {
                if fileManager.fileExists(atPath: loadedFiles[index].path) {
                    validCount += 1
                }
            }
            
            // If less than 80% of sample exists, invalidate cache
            let validRatio = Double(validCount) / Double(sampleSize)
            if validRatio < 0.8 {
                let validPercent = Int(validRatio * 100)
                print("⚠️ Cache validation failed: \(validPercent)% valid")
                return false
            }
            
            await MainActor.run {
                indexedFiles = loadedFiles
            }
            
            let validPercent = Int(validRatio * 100)
            print("✅ Loaded \(loadedFiles.count) files from cache (\(validPercent)% validation)")
            return true
        } catch {
            print("⚠️ Failed to load cached index: \(error)")
            return false
        }
    }
    
    private func saveCachedIndex() async {
        do {
            // Save index
            let indexData = try JSONEncoder().encode(indexedFiles)
            try indexData.write(to: indexCacheURL, options: .atomic)
            
            // Save metadata
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: metadataCacheURL, options: .atomic)
            
            print("💾 Saved index cache: \(ByteCountFormatter.string(fromByteCount: Int64(indexData.count), countStyle: .file))")
        } catch {
            print("⚠️ Failed to save index cache: \(error)")
        }
    }
    
    /// Clear the cached index
    func clearCache() async {
        try? fileManager.removeItem(at: indexCacheURL)
        try? fileManager.removeItem(at: metadataCacheURL)
        
        await MainActor.run {
            indexedFiles = []
            metadata = IndexMetadata()
            searchIndex.removeAll()
            nameIndex.removeAll()
            isReady = false
        }
        
        print("🗑️ Cache cleared")
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let fileIndexingStarted = Notification.Name("fileIndexingStarted")
    static let fileIndexingCompleted = Notification.Name("fileIndexingCompleted")
}

