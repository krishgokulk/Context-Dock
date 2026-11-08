import Foundation
import Testing

@testable import Context_Dock

@MainActor
@Suite("Pending approval journal", .serialized)
struct PendingApprovalJournalTests {

    private func makeJournal() -> (PendingApprovalJournal, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return (PendingApprovalJournal(directory: dir), dir)
    }

    private func makeRecord(
        id: String = "req-\(UUID().uuidString)",
        title: String = "Test approval",
        kindTag: String = "command",
        commandText: String? = "echo hello",
        createdAt: Date = Date()
    ) -> PendingApprovalRecord {
        PendingApprovalRecord(
            id: id, title: title, subtitle: nil, requesterClaim: nil, body: nil,
            riskRaw: ApprovalRisk.medium.rawValue, createdAt: createdAt,
            kindTag: kindTag, commandText: commandText)
    }

    // MARK: - Persistence

    /// save → reload → same request is present in the restored set.
    @Test func saveAndReloadRestoresSameRequest() throws {
        let (journal1, dir) = makeJournal()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord(id: "req-persist", title: "Run script?",
                                commandText: "echo world")
        journal1.save(record)

        let journal2 = PendingApprovalJournal(directory: dir)
        let restored = journal2.restored()

        #expect(restored.count == 1)
        let r = try #require(restored.first)
        #expect(r.id == "req-persist")
        #expect(r.title == "Run script?")
        #expect(r.kindTag == "command")
        #expect(r.commandText == "echo world")
    }

    /// A cleared record is not restored.
    @Test func clearedRecordIsNotRestored() {
        let (journal, dir) = makeJournal()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = makeRecord(id: "req-clear")
        journal.save(record)
        journal.clear(id: "req-clear")

        let journal2 = PendingApprovalJournal(directory: dir)
        #expect(journal2.restored().isEmpty)
    }

    // MARK: - Stale cancellation

    /// Records older than the threshold are cancelled on the reload, not shown.
    @Test func staleRequestIsCancelledWithReason() {
        let (journal, dir) = makeJournal()
        defer { try? FileManager.default.removeItem(at: dir) }

        let staleDate = Date(timeIntervalSinceNow: -(PendingApprovalJournal.stalenessInterval + 60))
        let old = makeRecord(id: "req-old", title: "Old approval",
                             kindTag: "capability", commandText: nil, createdAt: staleDate)
        journal.save(old)

        let cancelled = journal.cancelStale()

        #expect(cancelled.count == 1)
        #expect(cancelled.first?.0.id == "req-old")
        #expect(cancelled.first?.reason.contains("Cancelled") == true)
        #expect(journal.restored().isEmpty)
    }

    /// A fresh record is not cancelled by cancelStale.
    @Test func freshRequestIsNotCancelledByStaleCheck() {
        let (journal, _) = makeJournal()
        let fresh = makeRecord(id: "req-fresh")
        journal.save(fresh)

        let cancelled = journal.cancelStale()
        #expect(cancelled.isEmpty)
        #expect(journal.restored().count == 1)
    }

    // MARK: - Idempotency receipts

    /// First recordExecution writes a receipt (isNew == true); a second call for the
    /// same requestID returns the original receipt without writing a new one.
    @Test func approvalAfterReloadExecutesOnce() {
        let (journal, _) = makeJournal()

        let (r1, isNew1) = journal.recordExecution(
            requestID: "req-once", success: true, summary: "First run")
        let (r2, isNew2) = journal.recordExecution(
            requestID: "req-once", success: true, summary: "Second run")

        #expect(isNew1 == true)
        #expect(isNew2 == false)
        #expect(r1.requestID == r2.requestID)
        #expect(r1.ranAt == r2.ranAt)
    }

    /// Idempotency receipts survive an app restart: a second journal loaded from the
    /// same directory returns isNew == false for a request that already ran.
    @Test func receiptDeduplicationSurvivesReload() {
        let (j1, dir) = makeJournal()
        defer { try? FileManager.default.removeItem(at: dir) }

        j1.recordExecution(requestID: "req-reload", success: true, summary: "First run")

        let j2 = PendingApprovalJournal(directory: dir)
        let (_, isNew) = j2.recordExecution(
            requestID: "req-reload", success: true, summary: "Second run after reload")

        #expect(isNew == false)
        #expect(j2.receipt(for: "req-reload") != nil)
    }

    // MARK: - ApprovalRequest helpers

    /// A live command approval round-trips through asPendingRecord / fromRecord.
    @Test func liveCommandApprovalRoundTrips() {
        // Build a minimal PendingApprovalRecord for a command and reconstruct a
        // display-only ApprovalRequest from it.
        let record = makeRecord(
            id: "req-rt", title: "Move file?", kindTag: "command", commandText: "mv a b")
        let request = ApprovalRequest.fromRecord(record)

        #expect(request.id == "req-rt")
        #expect(request.title == "Move file?")
        #expect(request.wasRestored == true)
        if case .restored(let cmd) = request.kind {
            #expect(cmd == "mv a b")
        } else {
            Issue.record("expected .restored kind")
        }
    }

    /// A non-command restored request has no commandForReplay.
    @Test func nonCommandRestoredRequestHasNoReplay() {
        let record = makeRecord(id: "req-cap", kindTag: "capability", commandText: nil)
        let request = ApprovalRequest.fromRecord(record)

        #expect(request.wasRestored == true)
        if case .restored(let cmd) = request.kind {
            #expect(cmd == nil)
        } else {
            Issue.record("expected .restored kind")
        }
    }
}
