// PendingApprovalJournal.swift
// Context-Dock
//
// Durable store for pending approval records and execution receipts.
//
// When an approval card is raised, its display info is written here before the user
// answers. If the app quits before they do, the record survives; on relaunch the
// card is shown again (or auto-cancelled if stale). An execution receipt is written
// when an action starts running, so a request restored after a crash cannot trigger
// a second run for the same requestID.

import Foundation

// MARK: - Persisted record

/// Serialisable snapshot of a pending approval — display info only.
/// The continuation is not stored; it cannot survive a process restart.
struct PendingApprovalRecord: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let requesterClaim: String?
    let body: String?
    let riskRaw: Int
    let createdAt: Date
    /// One of: "command" | "capability" | "general-action" | "adapter"
    let kindTag: String
    /// The shell command string when kindTag is "command", so the action can be
    /// re-run via runPreApprovedCommand after a relaunch. Nil for other kinds.
    let commandText: String?

    var risk: ApprovalRisk { ApprovalRisk(rawValue: riskRaw) ?? .medium }
}

// MARK: - Execution receipt

/// Proof that an action was approved and started running, keyed by the approval's
/// request ID. Written before execution starts; checked before re-executing a
/// restored request to prevent double-runs after a crash.
struct ApprovalExecutionReceipt: Codable, Sendable {
    let requestID: String
    let ranAt: Date
    let success: Bool
    let summary: String
}

// MARK: - Journal

@MainActor
final class PendingApprovalJournal {
    static let shared = PendingApprovalJournal()

    /// Approvals older than this are cancelled on relaunch rather than restored.
    static let stalenessInterval: TimeInterval = 600  // 10 minutes

    private let pendingURL: URL
    private let receiptsURL: URL

    private(set) var pending: [String: PendingApprovalRecord] = [:]
    private(set) var receipts: [String: ApprovalExecutionReceipt] = [:]

    private init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Context-Dock", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true)
        pendingURL  = support.appendingPathComponent("pending-approvals.json")
        receiptsURL = support.appendingPathComponent("approval-receipts.json")
        load()
    }

    /// Testable init that writes to `directory` instead of Application Support.
    init(directory: URL) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        pendingURL  = directory.appendingPathComponent("pending-approvals.json")
        receiptsURL = directory.appendingPathComponent("approval-receipts.json")
        load()
    }

    // MARK: Pending records

    func save(_ record: PendingApprovalRecord) {
        pending[record.id] = record
        persistPending()
    }

    func clear(id: String) {
        guard pending[id] != nil else { return }
        pending.removeValue(forKey: id)
        persistPending()
    }

    /// Records carried over from a previous session that have not been answered.
    func restored() -> [PendingApprovalRecord] {
        pending.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Removes and returns records older than `interval`, each paired with a reason.
    func cancelStale(olderThan interval: TimeInterval = stalenessInterval)
        -> [(PendingApprovalRecord, reason: String)]
    {
        let cutoff = Date(timeIntervalSinceNow: -interval)
        let stale = pending.values.filter { $0.createdAt < cutoff }
        for record in stale { pending.removeValue(forKey: record.id) }
        if !stale.isEmpty { persistPending() }
        return stale.map { ($0, reason: "Cancelled — session ended while waiting") }
    }

    // MARK: Execution receipts (idempotency)

    /// Records that an action was approved and started running. If a receipt already
    /// exists for `requestID`, returns it without storing a second one — the caller
    /// must skip execution. `isNew` is true only when a new receipt was written.
    @discardableResult
    func recordExecution(
        requestID: String, success: Bool, summary: String
    ) -> (receipt: ApprovalExecutionReceipt, isNew: Bool) {
        if let existing = receipts[requestID] {
            return (existing, isNew: false)
        }
        let receipt = ApprovalExecutionReceipt(
            requestID: requestID, ranAt: Date(), success: success, summary: summary)
        receipts[requestID] = receipt
        persistReceipts()
        return (receipt, isNew: true)
    }

    func receipt(for requestID: String) -> ApprovalExecutionReceipt? {
        receipts[requestID]
    }

    // MARK: I/O

    private func load() {
        if let data = try? Data(contentsOf: pendingURL),
           let decoded = try? JSONDecoder().decode(
               [String: PendingApprovalRecord].self, from: data) {
            pending = decoded
        }
        if let data = try? Data(contentsOf: receiptsURL),
           let decoded = try? JSONDecoder().decode(
               [String: ApprovalExecutionReceipt].self, from: data) {
            receipts = decoded
        }
    }

    private func persistPending() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: pendingURL, options: .atomic)
    }

    private func persistReceipts() {
        guard let data = try? JSONEncoder().encode(receipts) else { return }
        try? data.write(to: receiptsURL, options: .atomic)
    }
}
