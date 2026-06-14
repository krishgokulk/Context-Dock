import Foundation

// MARK: - Usage Data Model

struct UsageRecord: Codable {
    var lastAccessDate: Date
    var accessCount: Int
    var totalScore: Double

    mutating func recordAccess() {
        lastAccessDate = Date()
        accessCount += 1
        totalScore = calculateFrecencyScore()
    }

    func calculateFrecencyScore() -> Double {
        let daysSince = -lastAccessDate.timeIntervalSinceNow / 86400

        let recency: Double
        if      daysSince < 1  { recency = 100.0 }
        else if daysSince < 7  { recency = 70.0  }
        else if daysSince < 30 { recency = 40.0  }
        else if daysSince < 90 { recency = 20.0  }
        else                   { recency = 5.0   }

        return recency + log10(Double(accessCount) + 1) * 10
    }
}

// MARK: - Usage Tracker

class UsageTracker {
    static let shared = UsageTracker()

    private var usageData: [String: UsageRecord] = [:]
    private let storageKey = "usageTrackerData"
    private let userDefaults = UserDefaults.standard

    // Serial queue — all reads and writes go through here for thread safety
    private let queue = DispatchQueue(label: "com.contextdock.usagetracker", qos: .utility)
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        loadUsageData()
    }

    // MARK: - Public API

    func recordAccess(for identifier: String) {
        queue.async { [self] in
            if var record = usageData[identifier] {
                record.recordAccess()
                usageData[identifier] = record
            } else {
                var r = UsageRecord(lastAccessDate: Date(), accessCount: 1, totalScore: 0)
                r.recordAccess()
                usageData[identifier] = r
            }
            scheduleSave()
        }
    }

    // Single lookup — safe to call from any thread
    func getScore(for identifier: String) -> Double {
        queue.sync { usageData[identifier]?.calculateFrecencyScore() ?? 0.0 }
    }

    // Batch snapshot — one lock acquisition for all candidates in a search pass.
    // Call this once before the scoring loop instead of getScore() per item.
    func snapshotScores(for identifiers: [String]) -> [String: Double] {
        queue.sync {
            var scores = [String: Double](minimumCapacity: identifiers.count)
            for id in identifiers {
                if let record = usageData[id] {
                    scores[id] = record.calculateFrecencyScore()
                }
            }
            return scores
        }
    }

    func getAccessCount(for identifier: String) -> Int {
        queue.sync { usageData[identifier]?.accessCount ?? 0 }
    }

    func getTopItems(limit: Int = 20) -> [(identifier: String, score: Double)] {
        queue.sync {
            usageData
                .map { ($0.key, $0.value.calculateFrecencyScore()) }
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map { $0 }
        }
    }

    func cleanupOldData() {
        queue.async { [self] in
            let cutoff = Date().addingTimeInterval(-180 * 86400)
            usageData = usageData.filter { $0.value.lastAccessDate > cutoff }
            scheduleSave()
        }
    }

    // MARK: - Persistence

    private func loadUsageData() {
        // Called from init (before shared is accessible) — no queue needed yet
        guard let data = userDefaults.data(forKey: storageKey) else { return }
        do {
            usageData = try JSONDecoder().decode([String: UsageRecord].self, from: data)
        } catch {
            #if DEBUG
            print("❌ UsageTracker: failed to load — \(error)")
            #endif
        }
    }

    // Debounced: coalesces rapid successive writes (e.g. launching multiple items quickly)
    // into a single disk write 500 ms after the last recordAccess call.
    // Must be called from within `queue`.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let data = try JSONEncoder().encode(usageData)
                userDefaults.set(data, forKey: storageKey)
            } catch {
                #if DEBUG
                print("❌ UsageTracker: failed to save — \(error)")
                #endif
            }
        }
        saveWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
