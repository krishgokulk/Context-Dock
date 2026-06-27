import Combine
import Foundation

// MARK: - Audit entry model

struct NotesMCPAuditEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let toolName: String
    let noteIDs: [String]
    let riskLevel: String
    let approvalStatus: ApprovalStatus
    let providerName: String
    let sourceSurface: String

    enum ApprovalStatus: String, Codable {
        case notRequired
        case approved
        case denied
        case persistent  // persistent full-read grant
    }
}

// MARK: - Audit logger

@MainActor
final class AppleNotesMCPAuditLogger: ObservableObject {
    static let shared = AppleNotesMCPAuditLogger()

    @Published private(set) var entries: [NotesMCPAuditEntry] = []
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Context-Dock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("notes-mcp-audit.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([NotesMCPAuditEntry].self, from: data) {
            entries = decoded
        }
    }

    func record(
        toolName: String,
        noteIDs: [String] = [],
        riskLevel: AICapabilityRiskLevel,
        approvalStatus: NotesMCPAuditEntry.ApprovalStatus,
        providerName: String = "local",
        sourceSurface: String = "contextDock"
    ) {
        entries.append(
            NotesMCPAuditEntry(
                id: UUID(),
                timestamp: Date(),
                toolName: toolName,
                noteIDs: noteIDs,
                riskLevel: riskLevel.rawValue,
                approvalStatus: approvalStatus,
                providerName: providerName,
                sourceSurface: sourceSurface
            )
        )
        if entries.count > 1_000 { entries.removeFirst(entries.count - 1_000) }
        let snapshot = entries
        let url = fileURL
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
