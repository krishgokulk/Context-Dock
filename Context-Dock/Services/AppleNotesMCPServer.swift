import Foundation

// Lazy-loaded, first-party coordinator for all Apple Notes MCP operations.
// Not started at app launch. Only active when noteMCPEnabled is true.
// All approval logic lives in AppleNotesMCPCapabilities executor closures.
// This layer handles: gating, audit, metadata index access, and execution delegation.
@MainActor
final class AppleNotesMCPServer {
    static let shared = AppleNotesMCPServer()

    private init() {}

    // MARK: - Gate

    var isEnabled: Bool { AppSettings.shared.noteMCPEnabled }

    func assertEnabled() throws {
        guard isEnabled else { throw AppleNotesError.notEnabled }
    }

    // MARK: - Search (metadata only — no approval, no body reads)

    func search(query: String, maxResults: Int = 20) async throws -> [NoteMetadata] {
        try assertEnabled()
        guard AppSettings.shared.noteMCPAllowMetadataSearch else {
            throw AppleNotesError.permissionDenied("Metadata search is disabled.")
        }
        // If index is cold (never loaded or empty), block and fill it first
        let count = await AppleNotesMetadataIndex.shared.cachedCount
        if count == 0 {
            try await AppleNotesMetadataIndex.shared.forceRefresh()
        } else {
            Task.detached(priority: .background) {
                try? await AppleNotesMetadataIndex.shared.refreshIfNeeded()
            }
        }
        let results = await AppleNotesMetadataIndex.shared.search(query: query, maxResults: maxResults)
        AppleNotesMCPAuditLogger.shared.record(
            toolName: "notes.search",
            noteIDs: results.map(\.id),
            riskLevel: .low,
            approvalStatus: .notRequired
        )
        return results
    }

    /// Live count via a single Apple Event — instant, never triggers a metadata refresh.
    /// Falls back to the cached index size if the script fails but a cache exists.
    func noteCount() async throws -> Int {
        try assertEnabled()
        guard AppSettings.shared.noteMCPAllowMetadataSearch else {
            throw AppleNotesError.permissionDenied("Metadata search is disabled.")
        }
        do {
            let count = try await AppleNotesExecutionService.shared.noteCount()
            AppleNotesMCPAuditLogger.shared.record(
                toolName: "notes.count",
                noteIDs: [],
                riskLevel: .low,
                approvalStatus: .notRequired
            )
            return count
        } catch {
            let cached = await AppleNotesMetadataIndex.shared.cachedCount
            if cached > 0 { return cached }
            throw error
        }
    }

    func allMetadata(maxResults: Int = 10_000) async throws -> [NoteMetadata] {
        try assertEnabled()
        guard AppSettings.shared.noteMCPAllowMetadataSearch else {
            throw AppleNotesError.permissionDenied("Metadata search is disabled.")
        }
        try await AppleNotesMetadataIndex.shared.refreshIfNeeded()
        return await AppleNotesMetadataIndex.shared.search(query: "", maxResults: maxResults)
    }

    func selectedNoteID() async throws -> String {
        try assertEnabled()
        return try await AppleNotesExecutionService.shared.selectedNoteID()
    }

    // MARK: - Deep search (full note body scan via AppleScript — slower but thorough)

    func deepSearch(query: String, maxResults: Int = 20) async throws -> [NoteMetadata] {
        try assertEnabled()
        guard AppSettings.shared.noteMCPAllowMetadataSearch else {
            throw AppleNotesError.permissionDenied("Metadata search is disabled.")
        }
        let results = try await AppleNotesExecutionService.shared.deepSearchBodies(
            query: query, maxResults: maxResults
        )
        AppleNotesMCPAuditLogger.shared.record(
            toolName: "notes.search",
            noteIDs: results.map(\.id),
            riskLevel: .low,
            approvalStatus: .notRequired
        )
        return results
    }

    // MARK: - Read (approval handled by executor based on persistent-read setting)

    func readNote(id: String, providerName: String) async throws -> (title: String, folder: String, body: String, modified: Date) {
        try assertEnabled()
        let result = try await AppleNotesExecutionService.shared.readNote(id: id)
        AppleNotesMCPAuditLogger.shared.record(
            toolName: "notes.read",
            noteIDs: [id],
            riskLevel: .medium,
            approvalStatus: AppSettings.shared.noteMCPAllowPersistentFullRead ? .persistent : .approved,
            providerName: providerName
        )
        return result
    }

    // MARK: - Create (approval handled by executor at .medium risk)

    func createNote(title: String, body: String, folder: String?, providerName: String) async throws -> String {
        try assertEnabled()
        let newID = try await AppleNotesExecutionService.shared.createNote(title: title, body: body, folder: folder)
        AppleNotesMCPAuditLogger.shared.record(
            toolName: "notes.create",
            noteIDs: [newID],
            riskLevel: .medium,
            approvalStatus: .approved,
            providerName: providerName
        )
        return newID
    }

    // MARK: - Append (approval handled by executor at .medium risk)

    func appendToNote(id: String, text: String, providerName: String) async throws {
        try assertEnabled()
        try await AppleNotesExecutionService.shared.appendToNote(id: id, text: text)
        AppleNotesMCPAuditLogger.shared.record(
            toolName: "notes.append",
            noteIDs: [id],
            riskLevel: .medium,
            approvalStatus: .approved,
            providerName: providerName
        )
    }

    // MARK: - Update (approval handled by executor at .medium risk)

    func updateNote(id: String, title: String?, body: String?, providerName: String) async throws {
        try assertEnabled()
        try await AppleNotesExecutionService.shared.updateNote(id: id, title: title, body: body)
        AppleNotesMCPAuditLogger.shared.record(
            toolName: "notes.update",
            noteIDs: [id],
            riskLevel: .medium,
            approvalStatus: .approved,
            providerName: providerName
        )
    }

    // MARK: - Delete (approval and delete-gate handled by executor at .high risk)

    func deleteNote(id: String, providerName: String) async throws {
        try assertEnabled()
        guard AppSettings.shared.noteMCPAllowDelete else {
            AppleNotesMCPAuditLogger.shared.record(
                toolName: "notes.delete",
                noteIDs: [id],
                riskLevel: .critical,
                approvalStatus: .denied,
                providerName: providerName
            )
            throw AICapabilityError.blocked(
                "Note deletion is disabled. Enable it in Settings › Apple Notes › Advanced › Allow Delete Tools."
            )
        }
        try await AppleNotesExecutionService.shared.deleteNote(id: id)
        AppleNotesMCPAuditLogger.shared.record(
            toolName: "notes.delete",
            noteIDs: [id],
            riskLevel: .high,
            approvalStatus: .approved,
            providerName: providerName
        )
    }

    // MARK: - Scope check (for surfacing in Context Dock)

    func isAvailableForCurrentApp(bundleID: String?) -> Bool {
        guard isEnabled else { return false }
        if AppSettings.shared.noteMCPAllowGlobalAccess { return true }
        return bundleID == "com.apple.Notes"
    }
}
