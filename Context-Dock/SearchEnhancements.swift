//
//  SearchEnhancements.swift
//  ILauncher
//
//  Enhanced search features: Recent searches, filters, caching
//

import Foundation
import SwiftUI
import Combine

// MARK: - Search History Manager
class SearchHistoryManager: ObservableObject {
    static let shared = SearchHistoryManager()

    @Published private(set) var recentSearches: [SearchHistoryItem] = []

    private let maxHistoryCount = 50
    private let userDefaults = UserDefaults.standard
    private let historyKey = "recentSearchHistory"

    struct SearchHistoryItem: Codable, Identifiable {
        let id: UUID
        let query: String
        let timestamp: Date

        init(query: String) {
            self.id = UUID()
            self.query = query
            self.timestamp = Date()
        }
    }

    private init() {
        loadHistory()
    }

    /// Add a search query to history
    func addSearch(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else { return }

        // Remove duplicate if exists
        recentSearches.removeAll { $0.query.lowercased() == trimmedQuery.lowercased() }

        // Add to front
        let item = SearchHistoryItem(query: trimmedQuery)
        recentSearches.insert(item, at: 0)

        // Trim to max count
        if recentSearches.count > maxHistoryCount {
            recentSearches = Array(recentSearches.prefix(maxHistoryCount))
        }

        saveHistory()
    }

    /// Clear all search history
    func clearHistory() {
        recentSearches = []
        saveHistory()
    }

    /// Remove a specific search from history
    func removeSearch(_ item: SearchHistoryItem) {
        recentSearches.removeAll { $0.id == item.id }
        saveHistory()
    }

    private func loadHistory() {
        guard let data = userDefaults.data(forKey: historyKey) else { return }

        do {
            let decoder = JSONDecoder()
            recentSearches = try decoder.decode([SearchHistoryItem].self, from: data)
        } catch {
            print("⚠️ Failed to load search history: \(error)")
            recentSearches = []
        }
    }

    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(recentSearches)
            userDefaults.set(data, forKey: historyKey)
        } catch {
            print("⚠️ Failed to save search history: \(error)")
        }
    }
}

// MARK: - Search Filter Options
struct SearchFilter: Equatable {
    var fileTypes: Set<FileType> = []
    var dateRange: DateRange?
    var sizeRange: SizeRange?

    enum FileType: String, CaseIterable, Identifiable {
        case document = "Documents"
        case image = "Images"
        case video = "Videos"
        case audio = "Audio"
        case code = "Code"
        case archive = "Archives"
        case pdf = "PDFs"
        case folder = "Folders"

        var id: String { rawValue }

        var extensions: Set<String> {
            switch self {
            case .document:
                return ["doc", "docx", "txt", "rtf", "pages", "md", "odt"]
            case .image:
                return ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "webp", "svg"]
            case .video:
                return ["mp4", "mov", "avi", "mkv", "flv", "wmv", "m4v"]
            case .audio:
                return ["mp3", "wav", "flac", "aac", "m4a", "ogg", "wma"]
            case .code:
                return ["swift", "py", "js", "ts", "java", "cpp", "c", "h", "go", "rs", "rb", "php", "html", "css", "json", "xml"]
            case .archive:
                return ["zip", "rar", "7z", "tar", "gz", "bz2", "dmg", "iso"]
            case .pdf:
                return ["pdf"]
            case .folder:
                return [] // Special case for directories
            }
        }

        var icon: String {
            switch self {
            case .document: return "doc.text"
            case .image: return "photo"
            case .video: return "video"
            case .audio: return "music.note"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .archive: return "archivebox"
            case .pdf: return "doc.richtext"
            case .folder: return "folder"
            }
        }
    }

    enum DateRange: String, CaseIterable, Identifiable {
        case today = "Today"
        case lastWeek = "Last Week"
        case lastMonth = "Last Month"
        case lastYear = "Last Year"

        var id: String { rawValue }

        func matches(_ date: Date) -> Bool {
            let calendar = Calendar.current
            let now = Date()

            switch self {
            case .today:
                return calendar.isDateInToday(date)
            case .lastWeek:
                guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) else { return false }
                return date >= weekAgo
            case .lastMonth:
                guard let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) else { return false }
                return date >= monthAgo
            case .lastYear:
                guard let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) else { return false }
                return date >= yearAgo
            }
        }
    }

    enum SizeRange: String, CaseIterable, Identifiable {
        case small = "< 1 MB"
        case medium = "1-10 MB"
        case large = "10-100 MB"
        case veryLarge = "> 100 MB"

        var id: String { rawValue }

        func matches(_ sizeInBytes: Int64) -> Bool {
            let mb = Double(sizeInBytes) / 1_048_576.0 // Bytes to MB

            switch self {
            case .small:
                return mb < 1.0
            case .medium:
                return mb >= 1.0 && mb < 10.0
            case .large:
                return mb >= 10.0 && mb < 100.0
            case .veryLarge:
                return mb >= 100.0
            }
        }
    }

    var isActive: Bool {
        return !fileTypes.isEmpty || dateRange != nil || sizeRange != nil
    }

    mutating func clear() {
        fileTypes.removeAll()
        dateRange = nil
        sizeRange = nil
    }
}

// MARK: - Search Result Cache
class SearchResultCache {
    static let shared = SearchResultCache()

    private var cache: [String: CacheEntry] = [:]
    private let maxCacheSize = 50
    private let cacheExpiration: TimeInterval = 300 // 5 minutes

    struct CacheEntry {
        let results: [SearchResult]
        let timestamp: Date
    }

    private init() {}

    /// Get cached results for a query
    func getCachedResults(for query: String) -> [SearchResult]? {
        let key = query.lowercased()

        guard let entry = cache[key] else { return nil }

        // Check if cache is still valid
        if Date().timeIntervalSince(entry.timestamp) > cacheExpiration {
            cache.removeValue(forKey: key)
            return nil
        }

        return entry.results
    }

    /// Cache results for a query
    func cacheResults(_ results: [SearchResult], for query: String) {
        let key = query.lowercased()
        cache[key] = CacheEntry(results: results, timestamp: Date())

        // Trim cache if too large
        if cache.count > maxCacheSize {
            // Remove oldest entries
            let sorted = cache.sorted { $0.value.timestamp < $1.value.timestamp }
            for (key, _) in sorted.prefix(cache.count - maxCacheSize) {
                cache.removeValue(forKey: key)
            }
        }
    }

    /// Clear all cached results
    func clearCache() {
        cache.removeAll()
    }

    /// Invalidate cache (call when file system changes)
    func invalidateCache() {
        cache.removeAll()
        print("🗑️ Search cache invalidated")
    }
}
