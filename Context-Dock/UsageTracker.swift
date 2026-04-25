//
//  UsageTracker.swift
//  ILauncher
//
//  Tracks usage frequency and recency for intelligent search ranking
//

import Foundation

// MARK: - Usage Data Model

struct UsageRecord: Codable {
    var lastAccessDate: Date
    var accessCount: Int
    var totalScore: Double

    mutating func recordAccess() {
        lastAccessDate = Date()
        accessCount += 1
        // Calculate frecency score: combines frequency and recency
        // More recent accesses get higher weight
        totalScore = calculateFrecencyScore()
    }

    func calculateFrecencyScore() -> Double {
        let daysSinceLastAccess = -lastAccessDate.timeIntervalSinceNow / 86400 // Convert to days

        // Decay function: more recent = higher score
        let recencyScore: Double
        if daysSinceLastAccess < 1 {
            recencyScore = 100.0 // Accessed today
        } else if daysSinceLastAccess < 7 {
            recencyScore = 70.0 // Accessed this week
        } else if daysSinceLastAccess < 30 {
            recencyScore = 40.0 // Accessed this month
        } else if daysSinceLastAccess < 90 {
            recencyScore = 20.0 // Accessed in last 3 months
        } else {
            recencyScore = 5.0 // Old access
        }

        // Frequency score: logarithmic to prevent dominance
        let frequencyScore = log10(Double(accessCount) + 1) * 10

        // Combine scores
        return recencyScore + frequencyScore
    }
}

// MARK: - Usage Tracker

class UsageTracker {
    static let shared = UsageTracker()

    private var usageData: [String: UsageRecord] = [:]
    private let storageKey = "usageTrackerData"
    private let userDefaults = UserDefaults.standard

    private init() {
        loadUsageData()
    }

    // MARK: - Public Methods

    /// Record that an item was accessed
    func recordAccess(for identifier: String) {
        if var record = usageData[identifier] {
            record.recordAccess()
            usageData[identifier] = record
        } else {
            var newRecord = UsageRecord(
                lastAccessDate: Date(),
                accessCount: 1,
                totalScore: 0
            )
            newRecord.recordAccess()
            usageData[identifier] = newRecord
        }

        saveUsageData()

        print("📊 Usage tracked for: \(identifier) - Score: \(usageData[identifier]?.totalScore ?? 0)")
    }

    /// Get the frecency score for an item (higher = more relevant)
    func getScore(for identifier: String) -> Double {
        guard let record = usageData[identifier] else {
            return 0.0
        }

        // Recalculate score based on current time
        return record.calculateFrecencyScore()
    }

    /// Get all tracked items sorted by score
    func getTopItems(limit: Int = 20) -> [(identifier: String, score: Double)] {
        var items: [(String, Double)] = []

        for (identifier, record) in usageData {
            let score = record.calculateFrecencyScore()
            items.append((identifier, score))
        }

        return items.sorted { $0.1 > $1.1 }.prefix(limit).map { $0 }
    }

    /// Clear old usage data (items not accessed in over 6 months)
    func cleanupOldData() {
        let sixMonthsAgo = Date().addingTimeInterval(-180 * 86400)

        usageData = usageData.filter { _, record in
            record.lastAccessDate > sixMonthsAgo
        }

        saveUsageData()
        print("🧹 Cleaned up old usage data. Remaining items: \(usageData.count)")
    }

    // MARK: - Persistence

    private func loadUsageData() {
        guard let data = userDefaults.data(forKey: storageKey) else {
            print("📊 No existing usage data found")
            return
        }

        do {
            usageData = try JSONDecoder().decode([String: UsageRecord].self, from: data)
            print("📊 Loaded usage data for \(usageData.count) items")
        } catch {
            print("❌ Failed to load usage data: \(error)")
        }
    }

    private func saveUsageData() {
        do {
            let data = try JSONEncoder().encode(usageData)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            print("❌ Failed to save usage data: \(error)")
        }
    }
}

