// AppPetMemory.swift
// Context-Dock
//
// Three-tier memory architecture for App Pets (#340).
//
// Ref: docs/superpowers/specs/2026-10-27-app-pets-combined-chat-design.md §6
//
// 1. Tier 1: Per-Pet identity memory (loaded only for that anchored App Pet; inspect, edit, pin, delete).
// 2. Tier 2: Combined Chat shared working memory across connected participants (rolling decisions,
//    unresolved work, writeback of verified facts only).
// 3. Tier 3: Mac-wide Global Context memory (General Chat single-turn borrowing never writes into Pet identity memory).

import Foundation

/// Provenance metadata for a memory record (#340).
///
/// Long-memory admission is provenance-based:
/// - Explicit user requests save immediately (`userExplicit`).
/// - Stable facts verified by receipts save with tool/receipt provenance (`verifiedReceipt`).
/// - Combined Chat writes back verified facts to participating Pets (`combinedChatWriteback`).
/// - Inferred preferences and routines require user confirmation before entering long memory (`inferred`).
/// - Raw message bodies, credentials, secrets and assistant guesses NEVER enter long memory.
enum MemoryProvenance: Codable, Equatable, Sendable {
    case userExplicit(sourceApp: String?)
    case verifiedReceipt(receiptID: String, toolName: String)
    case combinedChatWriteback(workspaceID: String, receiptID: String?)
    case inferred(confidence: Double, confirmed: Bool)

    var sourceTag: String {
        switch self {
        case .userExplicit:
            return "explicit-user-request"
        case .verifiedReceipt:
            return "receipt"
        case .combinedChatWriteback:
            return "combined-chat-writeback"
        case .inferred:
            return "assistant-inference"
        }
    }

    var confidenceDescription: String {
        switch self {
        case .userExplicit:
            return "explicit"
        case .verifiedReceipt:
            return "receipt"
        case .combinedChatWriteback:
            return "verified-writeback"
        case .inferred(let confidence, let confirmed):
            return confirmed ? "inferred-confirmed (\(confidence))" : "inferred-pending (\(confidence))"
        }
    }

    /// Whether this record is actively admitted into provider context.
    /// Inferred records remain suggestions until confirmed by the user.
    var isAdmitted: Bool {
        switch self {
        case .userExplicit, .verifiedReceipt, .combinedChatWriteback:
            return true
        case .inferred(_, let confirmed):
            return confirmed
        }
    }
}

/// A structured memory entry belonging to an App Pet or workspace (#340).
struct PetMemoryRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var fact: String
    var petID: AppPetID
    var capturedAt: Date
    var isPinned: Bool
    var provenance: MemoryProvenance
    var tags: [String]

    init(
        id: String = UUID().uuidString.prefix(8).lowercased(),
        fact: String,
        petID: AppPetID,
        capturedAt: Date = Date(),
        isPinned: Bool = false,
        provenance: MemoryProvenance,
        tags: [String] = []
    ) {
        self.id = id
        self.fact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        self.petID = petID.normalized
        self.capturedAt = capturedAt
        self.isPinned = isPinned
        self.provenance = provenance
        self.tags = tags
    }
}

/// Shared working memory for a Combined Chat workspace (#340).
///
/// Preserves task summary, decisions and unresolved work across connected participants.
/// Only verified facts are written back to individual participating Pets.
struct CombinedWorkspaceMemory: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var workspaceID: String
    var participantPetIDs: [AppPetID]
    var taskSummary: String
    var decisions: [String]
    var unresolvedWork: [String]
    var verifiedFacts: [PetMemoryRecord]
    var createdAt: Date
    var updatedAt: Date

    init(
        workspaceID: String,
        participantPetIDs: [AppPetID],
        taskSummary: String = "",
        decisions: [String] = [],
        unresolvedWork: [String] = [],
        verifiedFacts: [PetMemoryRecord] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = workspaceID
        self.workspaceID = workspaceID
        self.participantPetIDs = participantPetIDs.map(\.normalized)
        self.taskSummary = taskSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.decisions = decisions
        self.unresolvedWork = unresolvedWork
        self.verifiedFacts = verifiedFacts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Memory tier classification according to the App Pets specification (#340).
enum AppPetMemoryTier: Equatable, Sendable {
    /// Tier 1: Stored in `apps/<petID>.md`. Loaded only when anchored to that App Pet.
    case perPetIdentity(AppPetID)
    /// Tier 2: Stored in `workspaces/<workspaceID>.md`. Loaded across connected participants.
    case combinedWorkspace(workspaceID: String, participants: ParticipantSet)
    /// Tier 3: Stored in root vault markdown files (`preferences.md`, `tasks.md`, etc.). Loaded Mac-wide.
    case globalContext
}

/// Pure parser and serializer for Markdown memory records with HTML comment provenance (#340).
enum PetMemoryMarkdownCodec {
    private static let isoFormatter = ISO8601DateFormatter()

    /// Serializes a list of memory records to human-readable Markdown with provenance comments.
    static func render(records: [PetMemoryRecord], headerTitle: String) -> String {
        var lines: [String] = ["# \(headerTitle)", ""]
        for record in records {
            let pinPrefix = record.isPinned ? "[pinned] " : ""
            lines.append("- \(pinPrefix)\(record.fact)")
            lines.append("  <!-- dorax-provenance")
            lines.append("  id: \(record.id)")
            lines.append("  source: \(record.provenance.sourceTag)")
            lines.append("  confidence: \(record.provenance.confidenceDescription)")
            lines.append("  captured-at: \(isoFormatter.string(from: record.capturedAt))")
            if record.isPinned {
                lines.append("  pinned: true")
            }
            switch record.provenance {
            case .userExplicit(let sourceApp):
                if let sourceApp, !sourceApp.isEmpty {
                    lines.append("  source-app: \(sourceApp)")
                }
            case .verifiedReceipt(let receiptID, let toolName):
                lines.append("  receipt-id: \(receiptID)")
                lines.append("  tool-name: \(toolName)")
            case .combinedChatWriteback(let workspaceID, let receiptID):
                lines.append("  workspace-id: \(workspaceID)")
                if let receiptID, !receiptID.isEmpty {
                    lines.append("  receipt-id: \(receiptID)")
                }
            case .inferred(let confidence, let confirmed):
                lines.append("  inferred-confidence: \(confidence)")
                lines.append("  confirmed: \(confirmed)")
            }
            if !record.tags.isEmpty {
                lines.append("  tags: \(record.tags.joined(separator: ", "))")
            }
            lines.append("  -->")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Parses memory records from Markdown text.
    static func parse(markdown: String, petID: AppPetID) -> [PetMemoryRecord] {
        var records: [PetMemoryRecord] = []
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") {
                var factRaw = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                var isPinned = false
                if factRaw.hasPrefix("[pinned] ") {
                    isPinned = true
                    factRaw = String(factRaw.dropFirst("[pinned] ".count)).trimmingCharacters(in: .whitespaces)
                }

                // Check for trailing HTML comment block
                var commentLines: [String] = []
                var j = i + 1
                var inComment = false

                while j < lines.count {
                    let sub = lines[j].trimmingCharacters(in: .whitespaces)
                    if sub.contains("<!-- dorax-provenance") {
                        inComment = true
                    } else if inComment {
                        if sub.contains("-->") {
                            inComment = false
                            j += 1
                            break
                        }
                        commentLines.append(sub)
                    } else if sub.hasPrefix("- ") || sub.hasPrefix("# ") {
                        break
                    }
                    j += 1
                }

                let provenance = parseProvenance(commentLines: commentLines, defaultPetID: petID)
                let id = parseMetadataValue(key: "id", lines: commentLines)
                    ?? UUID().uuidString.prefix(8).lowercased()
                let capturedAt = parseMetadataDate(key: "captured-at", lines: commentLines) ?? Date()
                let pinnedComment = parseMetadataValue(key: "pinned", lines: commentLines) == "true"
                let tags = parseMetadataValue(key: "tags", lines: commentLines)?
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []

                let record = PetMemoryRecord(
                    id: String(id),
                    fact: factRaw,
                    petID: petID,
                    capturedAt: capturedAt,
                    isPinned: isPinned || pinnedComment,
                    provenance: provenance,
                    tags: tags
                )
                records.append(record)
                i = j
                continue
            }
            i += 1
        }

        return records
    }

    private static func parseMetadataValue(key: String, lines: [String]) -> String? {
        let prefix = "\(key):"
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                let val = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return val.isEmpty ? nil : val
            }
        }
        return nil
    }

    private static func parseMetadataDate(key: String, lines: [String]) -> Date? {
        guard let val = parseMetadataValue(key: key, lines: lines) else { return nil }
        return isoFormatter.date(from: val)
    }

    private static func parseProvenance(commentLines: [String], defaultPetID: AppPetID) -> MemoryProvenance {
        let source = parseMetadataValue(key: "source", lines: commentLines)?.lowercased() ?? ""
        switch source {
        case "receipt":
            let receiptID = parseMetadataValue(key: "receipt-id", lines: commentLines) ?? "unknown-receipt"
            let toolName = parseMetadataValue(key: "tool-name", lines: commentLines) ?? "tool"
            return .verifiedReceipt(receiptID: receiptID, toolName: toolName)

        case "combined-chat-writeback":
            let workspaceID = parseMetadataValue(key: "workspace-id", lines: commentLines) ?? "combined"
            let receiptID = parseMetadataValue(key: "receipt-id", lines: commentLines)
            return .combinedChatWriteback(workspaceID: workspaceID, receiptID: receiptID)

        case "assistant-inference":
            let confVal = Double(parseMetadataValue(key: "inferred-confidence", lines: commentLines) ?? "") ?? 0.7
            let confirmed = parseMetadataValue(key: "confirmed", lines: commentLines) == "true"
            return .inferred(confidence: confVal, confirmed: confirmed)

        default:
            let app = parseMetadataValue(key: "source-app", lines: commentLines)
            return .userExplicit(sourceApp: app)
        }
    }
}

/// Three-tier memory controller for App Pets and Combined Chat (#340).
final class AppPetMemoryController {
    static let shared = AppPetMemoryController()

    private let fileManager = FileManager.default
    private let rootOverride: URL?

    init(rootOverride: URL? = nil) {
        self.rootOverride = rootOverride
    }

    var root: URL {
        rootOverride ?? MarkdownMemoryStore.shared.root
    }

    // MARK: - Paths

    func fileURL(for petID: AppPetID) -> URL {
        let filename: String
        switch petID.normalized {
        case .app(let bundleID):
            filename = "\(MarkdownMemoryStore.safeFilename(bundleID)).md"
        case .cli(let command):
            filename = "cli_\(MarkdownMemoryStore.safeFilename(command)).md"
        }
        return root.appendingPathComponent("apps/\(filename)")
    }

    func workspaceFileURL(workspaceID: String) -> URL {
        let safeID = MarkdownMemoryStore.safeFilename(workspaceID)
        return root.appendingPathComponent("workspaces/\(safeID).md")
    }

    // MARK: - Tier 1: Per-Pet Identity Memory Operations (Inspect, Edit, Pin, Delete)

    /// Loads all memory records for an App Pet.
    func loadRecords(for petID: AppPetID) -> [PetMemoryRecord] {
        let url = fileURL(for: petID)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return PetMemoryMarkdownCodec.parse(markdown: content, petID: petID)
    }

    /// Loads only admitted memory records (excluding unconfirmed inferences).
    /// Pinned records are sorted first.
    func loadAdmittedRecords(for petID: AppPetID) -> [PetMemoryRecord] {
        let all = loadRecords(for: petID)
        let admitted = all.filter(\.provenance.isAdmitted)
        return admitted.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return $0.capturedAt > $1.capturedAt
        }
    }

    /// Appends or updates a memory record for an App Pet.
    ///
    /// Respects conversation identity: General Chat single-turn borrowing NEVER writes into Pet identity memory.
    @discardableResult
    func saveRecord(
        _ record: PetMemoryRecord,
        conversationKind: ConversationKind
    ) -> (success: Bool, message: String) {
        // Enforce invariant: General Chat single-turn borrowing never writes into Pet identity memory.
        guard conversationKind != .general else {
            return (false, "Refused: General Chat single-turn borrowing never writes into Pet identity memory.")
        }

        var records = loadRecords(for: record.petID)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            // Check for exact text duplicate
            if records.contains(where: { $0.fact.caseInsensitiveCompare(record.fact) == .orderedSame }) {
                return (false, "Already remembered: \(record.fact)")
            }
            records.append(record)
        }

        let headerTitle = "\(record.petID.dockBundleID) Pet Memory"
        let rendered = PetMemoryMarkdownCodec.render(records: records, headerTitle: headerTitle)
        let url = fileURL(for: record.petID)

        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            return (true, "Saved in \(record.petID.dockBundleID) memory: \(record.fact)")
        } catch {
            return (false, "Could not save memory: \(error.localizedDescription)")
        }
    }

    /// Toggles or sets the pinned status of a Pet memory record (#340).
    @discardableResult
    func pinRecord(id: String, for petID: AppPetID, pinned: Bool) -> Bool {
        var records = loadRecords(for: petID)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        records[index].isPinned = pinned

        let url = fileURL(for: petID)
        let rendered = PetMemoryMarkdownCodec.render(records: records, headerTitle: "\(petID.dockBundleID) Pet Memory")
        do {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Edits the text of an existing Pet memory record (#340).
    @discardableResult
    func editRecord(id: String, for petID: AppPetID, newFact: String) -> Bool {
        let trimmed = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var records = loadRecords(for: petID)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        records[index].fact = trimmed

        let url = fileURL(for: petID)
        let rendered = PetMemoryMarkdownCodec.render(records: records, headerTitle: "\(petID.dockBundleID) Pet Memory")
        do {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Deletes a Pet memory record (#340).
    @discardableResult
    func deleteRecord(id: String, for petID: AppPetID) -> Bool {
        var records = loadRecords(for: petID)
        let originalCount = records.count
        records.removeAll(where: { $0.id == id })
        guard records.count < originalCount else { return false }

        let url = fileURL(for: petID)
        let rendered = PetMemoryMarkdownCodec.render(records: records, headerTitle: "\(petID.dockBundleID) Pet Memory")
        do {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Confirms an inferred preference or routine so it becomes active long memory (#340).
    @discardableResult
    func confirmInferredRecord(id: String, for petID: AppPetID) -> Bool {
        var records = loadRecords(for: petID)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        guard case .inferred(let confidence, _) = records[index].provenance else { return false }

        records[index].provenance = .inferred(confidence: confidence, confirmed: true)
        let url = fileURL(for: petID)
        let rendered = PetMemoryMarkdownCodec.render(records: records, headerTitle: "\(petID.dockBundleID) Pet Memory")
        do {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Tier 2: Combined Chat Shared Working Memory & Writeback

    /// Loads shared working memory for a Combined Chat workspace.
    func loadWorkspaceMemory(workspaceID: String) -> CombinedWorkspaceMemory? {
        let url = workspaceFileURL(workspaceID: workspaceID)
        guard let data = try? Data(contentsOf: url),
              let memory = try? JSONDecoder().decode(CombinedWorkspaceMemory.self, from: data)
        else {
            return nil
        }
        return memory
    }

    /// Saves shared working memory for a Combined Chat workspace.
    func saveWorkspaceMemory(_ memory: CombinedWorkspaceMemory) {
        let url = workspaceFileURL(workspaceID: memory.workspaceID)
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(memory)
            try data.write(to: url, options: .atomic)
        } catch {
            // Fallback non-fatal
        }
    }

    /// Writes back ONLY verified facts from Combined Chat to a participating Pet (#340).
    ///
    /// Rules:
    /// - Only verified facts with provenance (e.g. from an action receipt or explicit confirmation) write back.
    /// - Must target a participating Pet in that workspace.
    /// - Tagged with `.combinedChatWriteback`.
    /// - Unverified assistant guesses or transient cross-app state are refused.
    @discardableResult
    func writebackVerifiedFact(
        fact: String,
        targetPet: AppPetID,
        workspaceID: String,
        participants: ParticipantSet,
        receiptID: String?
    ) -> (success: Bool, message: String) {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "Empty fact cannot be written back.")
        }
        guard participants.contains(targetPet) else {
            return (false, "Target Pet \(targetPet.dockBundleID) is not a connected participant in \(workspaceID).")
        }

        let record = PetMemoryRecord(
            fact: trimmed,
            petID: targetPet,
            provenance: .combinedChatWriteback(workspaceID: workspaceID, receiptID: receiptID)
        )

        return saveRecord(record, conversationKind: .combined)
    }

    // MARK: - Prompt Context Blocks

    /// Builds the memory context block appropriate for the given scope and conversation kind (#340).
    ///
    /// - `.general`: loads ONLY Tier 3 (Global Context). Mail/Safari Pet memory is NEVER loaded.
    /// - `.appPet`: loads Tier 1 (that Pet's admitted memories, pinned first) + Tier 3 (Global Context).
    /// - `.combined`: loads Tier 2 (shared working memory) + Tier 1 for participating Pets + Tier 3 (Global Context).
    func promptContextBlock(
        query: String,
        scope: GeneralChatScope,
        participants: ParticipantSet = .empty
    ) -> (contextBlock: String, sourceChips: [String]) {
        let kind = GeneralChatSessionStore.conversationKind(for: scope, participants: participants)
        var chips: [String] = []
        var sections: [String] = []

        switch kind {
        case .general:
            // Tier 3 ONLY.
            let global = MarkdownMemoryStore.shared.contextBlock(query: query, appBundleID: nil)
            if !global.isEmpty {
                sections.append(global)
            }
            chips.append(contentsOf: MarkdownMemoryStore.shared.relevantSourceChips(query: query, appBundleID: nil))

        case .appPet(let petID):
            // Tier 1 + Tier 3.
            let records = loadAdmittedRecords(for: petID)
            if !records.isEmpty {
                var petLines = ["### \(petID.dockBundleID) Memory"]
                for rec in records.prefix(8) {
                    let pinBadge = rec.isPinned ? "★ " : ""
                    petLines.append("- \(pinBadge)\(rec.fact)")
                }
                sections.append(petLines.joined(separator: "\n"))
                chips.append("\(petID.dockBundleID) memory")
            }
            let global = MarkdownMemoryStore.shared.contextBlock(query: query, appBundleID: petID.bundleID)
            if !global.isEmpty {
                sections.append(global)
            }
            chips.append(contentsOf: MarkdownMemoryStore.shared.relevantSourceChips(query: query, appBundleID: petID.bundleID))

        case .combined:
            // Tier 2 + Tier 1 (participating Pets) + Tier 3.
            if let workspaceMem = loadWorkspaceMemory(workspaceID: participants.combinedThreadID) {
                var wsLines = ["### Combined Workspace Context (\(participants.headerTitle))"]
                if !workspaceMem.taskSummary.isEmpty {
                    wsLines.append("Task: \(workspaceMem.taskSummary)")
                }
                if !workspaceMem.decisions.isEmpty {
                    wsLines.append("Decisions: " + workspaceMem.decisions.joined(separator: "; "))
                }
                if !workspaceMem.unresolvedWork.isEmpty {
                    wsLines.append("Unresolved: " + workspaceMem.unresolvedWork.joined(separator: "; "))
                }
                sections.append(wsLines.joined(separator: "\n"))
                chips.append("Combined workspace memory")
            }

            for petID in participants.petIDs {
                let admitted = loadAdmittedRecords(for: petID)
                if !admitted.isEmpty {
                    var lines = ["### \(petID.dockBundleID) Context"]
                    for rec in admitted.prefix(4) {
                        lines.append("- \(rec.fact)")
                    }
                    sections.append(lines.joined(separator: "\n"))
                    chips.append("\(petID.dockBundleID) memory")
                }
            }

            let global = MarkdownMemoryStore.shared.contextBlock(query: query, appBundleID: nil)
            if !global.isEmpty {
                sections.append(global)
            }
            chips.append(contentsOf: MarkdownMemoryStore.shared.relevantSourceChips(query: query, appBundleID: nil))
        }

        return (sections.joined(separator: "\n\n"), chips)
    }
}
