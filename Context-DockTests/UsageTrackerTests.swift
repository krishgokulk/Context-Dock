//
//  UsageTrackerTests.swift
//  Context-DockTests
//
//  Unit tests for UsageRecord and UsageTracker.
//

import XCTest
@testable import Context_Dock

// MARK: - UsageRecord tests

final class UsageRecordTests: XCTestCase {

    // MARK: Recency buckets

    func testFrecencyScore_today() {
        // Accessed just now → recencyScore = 100
        let record = UsageRecord(lastAccessDate: Date(), accessCount: 1, totalScore: 0)
        let score = record.calculateFrecencyScore()
        // recencyScore = 100, frequencyScore = log10(2)*10 ≈ 3.01
        XCTAssertGreaterThanOrEqual(score, 100, "Score should be at least 100 for today's access")
        XCTAssertLessThanOrEqual(score, 120, "Score should not exceed 120 for a single access today")
    }

    func testFrecencyScore_thisWeek() {
        // Accessed 3 days ago → recencyScore = 70
        let threeDaysAgo = Date().addingTimeInterval(-3 * 86_400)
        let record = UsageRecord(lastAccessDate: threeDaysAgo, accessCount: 1, totalScore: 0)
        let score = record.calculateFrecencyScore()
        XCTAssertGreaterThanOrEqual(score, 70, "Score should be at least 70 for this-week access")
        XCTAssertLessThan(score, 100, "Score should be below the 'today' tier")
    }

    func testFrecencyScore_thisMonth() {
        // Accessed 15 days ago → recencyScore = 40
        let fifteenDaysAgo = Date().addingTimeInterval(-15 * 86_400)
        let record = UsageRecord(lastAccessDate: fifteenDaysAgo, accessCount: 1, totalScore: 0)
        let score = record.calculateFrecencyScore()
        XCTAssertGreaterThanOrEqual(score, 40, "Score should be at least 40 for this-month access")
        XCTAssertLessThan(score, 70, "Score should be below the 'this-week' tier")
    }

    func testFrecencyScore_lastThreeMonths() {
        // Accessed 60 days ago → recencyScore = 20
        let sixtyDaysAgo = Date().addingTimeInterval(-60 * 86_400)
        let record = UsageRecord(lastAccessDate: sixtyDaysAgo, accessCount: 1, totalScore: 0)
        let score = record.calculateFrecencyScore()
        XCTAssertGreaterThanOrEqual(score, 20, "Score should be at least 20 for last-3-months access")
        XCTAssertLessThan(score, 40, "Score should be below the 'this-month' tier")
    }

    func testFrecencyScore_old() {
        // Accessed 120 days ago → recencyScore = 5
        let oldDate = Date().addingTimeInterval(-120 * 86_400)
        let record = UsageRecord(lastAccessDate: oldDate, accessCount: 1, totalScore: 0)
        let score = record.calculateFrecencyScore()
        XCTAssertGreaterThanOrEqual(score, 5, "Score should be at least 5 for old access")
        XCTAssertLessThan(score, 20, "Score should be below the 'last-3-months' tier")
    }

    // MARK: Frequency component

    func testFrecencyScore_frequencyIncreases() {
        // Higher access count should yield a higher total score for the same recency
        let date = Date()
        let low  = UsageRecord(lastAccessDate: date, accessCount: 1,   totalScore: 0)
        let high = UsageRecord(lastAccessDate: date, accessCount: 100, totalScore: 0)
        XCTAssertLessThan(low.calculateFrecencyScore(), high.calculateFrecencyScore(),
                          "Higher access count should produce a higher frecency score")
    }

    func testFrecencyScore_minimumIsPositive() {
        let veryOld = Date().addingTimeInterval(-365 * 86_400)
        let record = UsageRecord(lastAccessDate: veryOld, accessCount: 1, totalScore: 0)
        XCTAssertGreaterThan(record.calculateFrecencyScore(), 0, "Score should always be positive")
    }

    // MARK: recordAccess mutation

    func testRecordAccess_incrementsCount() {
        var record = UsageRecord(lastAccessDate: Date().addingTimeInterval(-10_000),
                                 accessCount: 2,
                                 totalScore: 0)
        let countBefore = record.accessCount
        record.recordAccess()
        XCTAssertEqual(record.accessCount, countBefore + 1)
    }

    func testRecordAccess_updatesLastAccessDate() {
        var record = UsageRecord(lastAccessDate: Date().addingTimeInterval(-10_000),
                                 accessCount: 1,
                                 totalScore: 0)
        let before = Date()
        record.recordAccess()
        XCTAssertGreaterThanOrEqual(record.lastAccessDate, before)
    }

    func testRecordAccess_updatesTotalScore() {
        var record = UsageRecord(lastAccessDate: Date().addingTimeInterval(-10_000),
                                 accessCount: 1,
                                 totalScore: 0)
        record.recordAccess()
        XCTAssertGreaterThan(record.totalScore, 0, "recordAccess() should store a positive totalScore")
    }
}

// MARK: - UsageTracker integration tests

final class UsageTrackerTests: XCTestCase {

    /// Each test gets a fresh identifier to avoid cross-test interference with the shared singleton.
    private var identifier: String!

    override func setUp() {
        super.setUp()
        identifier = "test-\(UUID().uuidString)"
    }

    func testGetScore_unknownIdentifier_returnsZero() {
        let score = UsageTracker.shared.getScore(for: "nonexistent-\(UUID().uuidString)")
        XCTAssertEqual(score, 0.0)
    }

    func testRecordAccess_thenGetScore_returnsPositive() {
        UsageTracker.shared.recordAccess(for: identifier)
        XCTAssertGreaterThan(UsageTracker.shared.getScore(for: identifier), 0)
    }

    func testGetTopItems_includesRecentlyTrackedItem() {
        UsageTracker.shared.recordAccess(for: identifier)
        let top = UsageTracker.shared.getTopItems(limit: 50)
        let found = top.contains { $0.identifier == identifier }
        XCTAssertTrue(found, "getTopItems should include a recently recorded item")
    }

    func testGetTopItems_respectedLimit() {
        // Record more identifiers than the limit
        for i in 0..<10 {
            UsageTracker.shared.recordAccess(for: "topitem-\(identifier!)-\(i)")
        }
        let top = UsageTracker.shared.getTopItems(limit: 3)
        XCTAssertLessThanOrEqual(top.count, 3)
    }

    func testGetTopItems_sortedDescending() {
        let top = UsageTracker.shared.getTopItems(limit: 100)
        for i in 0..<max(0, top.count - 1) {
            XCTAssertGreaterThanOrEqual(top[i].score, top[i + 1].score,
                                        "getTopItems() must return scores in descending order")
        }
    }
}
