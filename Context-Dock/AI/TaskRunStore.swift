import Foundation

/// Durable execution journal for provider tool loops. Chat history records conversation;
/// this records machine work and is intentionally independent from any chat surface.
@MainActor
final class TaskRunStore {
    static let shared = TaskRunStore()

    enum Status: String, Codable {
        case running, completed, failed, interrupted
    }

    /// The one receipt shape, shared with the surfaces that draw it. Persisted files
    /// already carry these keys, so the type moved out without a migration.
    typealias Receipt = DoraXActionReceipt

    struct Budget: Codable, Equatable {
        let maxToolCalls: Int
        let maxAttempts: Int
        let maxWallClockSeconds: Int
        var usedToolCalls: Int = 0
    }

    enum FailureKind: String, Codable, Equatable {
        case transient, staleState, routeUnavailable, permissionRequired
        case validationFailed, repeatedFailure, terminal
    }

    enum FailurePolicy: String, Codable, Equatable {
        case retry, refreshContext, fallback, requestApproval, repair, stop
    }

    struct FailureEvent: Codable, Equatable {
        let node: String
        let kind: FailureKind
        let policy: FailurePolicy
        let observation: String
        let recordedAt: Date
    }

    struct ActionCheckpoint: Codable, Equatable {
        let key: String
        let output: String
        let recordedAt: Date
    }

    struct Run: Codable, Identifiable {
        let id: UUID
        let request: String
        let provider: String
        let createdAt: Date
        var updatedAt: Date
        var status: Status
        var receipts: [Receipt]
        var finalResponse: String?
        var failure: String?
        var resumedFrom: UUID?
        var objective: String
        var currentNode: String?
        var completedNodes: [String]
        var budget: Budget
        var failures: [FailureEvent]
        var actionCheckpoints: [ActionCheckpoint]

        enum CodingKeys: String, CodingKey {
            case id, request, provider, createdAt, updatedAt, status, receipts
            case finalResponse, failure, resumedFrom, objective, currentNode
            case completedNodes, budget, failures, actionCheckpoints
        }

        init(
            id: UUID, request: String, provider: String, createdAt: Date,
            updatedAt: Date, status: Status, receipts: [Receipt],
            finalResponse: String?, failure: String?, resumedFrom: UUID?,
            objective: String, currentNode: String?, completedNodes: [String],
            budget: Budget, failures: [FailureEvent],
            actionCheckpoints: [ActionCheckpoint]
        ) {
            self.id = id
            self.request = request
            self.provider = provider
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.status = status
            self.receipts = receipts
            self.finalResponse = finalResponse
            self.failure = failure
            self.resumedFrom = resumedFrom
            self.objective = objective
            self.currentNode = currentNode
            self.completedNodes = completedNodes
            self.budget = budget
            self.failures = failures
            self.actionCheckpoints = actionCheckpoints
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            request = try values.decode(String.self, forKey: .request)
            provider = try values.decode(String.self, forKey: .provider)
            createdAt = try values.decode(Date.self, forKey: .createdAt)
            updatedAt = try values.decode(Date.self, forKey: .updatedAt)
            status = try values.decode(Status.self, forKey: .status)
            receipts = try values.decodeIfPresent([Receipt].self, forKey: .receipts) ?? []
            finalResponse = try values.decodeIfPresent(String.self, forKey: .finalResponse)
            failure = try values.decodeIfPresent(String.self, forKey: .failure)
            resumedFrom = try values.decodeIfPresent(UUID.self, forKey: .resumedFrom)
            objective = try values.decodeIfPresent(String.self, forKey: .objective) ?? request
            currentNode = try values.decodeIfPresent(String.self, forKey: .currentNode)
            completedNodes = try values.decodeIfPresent(
                [String].self, forKey: .completedNodes) ?? []
            budget = try values.decodeIfPresent(Budget.self, forKey: .budget)
                ?? Budget(maxToolCalls: 5, maxAttempts: 1, maxWallClockSeconds: 120)
            failures = try values.decodeIfPresent([FailureEvent].self, forKey: .failures) ?? []
            actionCheckpoints = try values.decodeIfPresent(
                [ActionCheckpoint].self, forKey: .actionCheckpoints) ?? []
        }
    }

    struct ResumeRequest {
        let message: String
        let source: Run?
    }

    @TaskLocal static var activeRunID: UUID?

    private let directory = ContextDockStore.root
        .appendingPathComponent("task-runs", isDirectory: true)
    private var runs: [UUID: Run] = [:]

    private init() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        loadRuns()
        // A process cannot still own a run loaded from disk. Preserve it for resume instead
        // of pretending it completed or silently discarding it.
        for id in runs.keys where runs[id]?.status == .running {
            runs[id]?.status = .interrupted
            runs[id]?.updatedAt = Date()
            persist(id)
        }
    }

    func resolve(_ message: String) -> ResumeRequest {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["resume last task", "resume the last task", "continue last task"].contains(normalized),
              let source = latestTaskRun()
        else { return ResumeRequest(message: message, source: nil) }

        let completed = source.receipts.filter { $0.success && !$0.isVerification }
            .map { "- \($0.command): \($0.output.isEmpty ? "succeeded with no output" : $0.output)" }
            .joined(separator: "\n")
        return ResumeRequest(message: """
            Resume this interrupted task: \(source.request)

            Durable receipts already completed (do not repeat these actions):
            \(completed.isEmpty ? "- none" : completed)

            Continue only unfinished work, then perform fresh read-only verification.
            """, source: source)
    }

    func track<T>(
        request: String,
        provider: String,
        resumedFrom: UUID?,
        maxToolCalls: Int,
        operation: () async throws -> T
    ) async throws -> T {
        let run = start(
            request: request, provider: provider, resumedFrom: resumedFrom,
            maxToolCalls: maxToolCalls)
        return try await Self.$activeRunID.withValue(run.id) {
            do {
                let result = try await operation()
                let status: Status
                if Task.isCancelled || hasRunningBackgroundWorker(run.id) {
                    status = .interrupted
                } else {
                    status = .completed
                }
                finish(run.id, status: status)
                return result
            } catch is CancellationError {
                finish(run.id, status: .interrupted)
                throw CancellationError()
            } catch {
                finish(run.id, status: .failed, failure: error.localizedDescription)
                throw error
            }
        }
    }

    func record(_ command: AIProviderService.ExecutedCommand) {
        guard let id = Self.activeRunID, var run = runs[id] else { return }
        run.receipts.append(Receipt(
            command: command.command,
            output: command.output,
            success: command.success,
            isVerification: command.isVerification,
            recordedAt: Date()
        ))
        run.updatedAt = Date()
        runs[id] = run
        persist(id)
    }

    func cachedSuccessfulCommand(_ command: String, from source: Run?) -> Receipt? {
        source?.receipts.last { $0.success && !$0.isVerification && $0.command == "run_command(\(command))" }
    }

    /// Reserves one bounded tool slot before execution. Provider iterations are not a tool
    /// budget: one response can contain several calls. This is the deterministic outer stop.
    func reserveToolCall(_ node: String) -> String? {
        guard let id = Self.activeRunID, var run = runs[id] else { return nil }
        guard run.budget.usedToolCalls < run.budget.maxToolCalls else {
            return "Tool budget reached (\(run.budget.maxToolCalls) calls). Stop and report "
                + "the completed work and the remaining unmet criterion."
        }
        run.budget.usedToolCalls += 1
        run.currentNode = node
        run.updatedAt = Date()
        runs[id] = run
        persist(id)
        return nil
    }

    func finishToolCall(node: String, success: Bool, output: String) {
        guard let id = Self.activeRunID, var run = runs[id] else { return }
        if success {
            if !run.completedNodes.contains(node) { run.completedNodes.append(node) }
        } else {
            let classification = Self.classifyFailure(output)
            run.failures.append(FailureEvent(
                node: node, kind: classification.kind, policy: classification.policy,
                observation: String(output.prefix(800)), recordedAt: Date()))
        }
        run.currentNode = nil
        run.updatedAt = Date()
        runs[id] = run
        persist(id)
    }

    func checkpointAction(key: String, output: String) {
        guard let id = Self.activeRunID, var run = runs[id] else { return }
        guard !run.actionCheckpoints.contains(where: { $0.key == key }) else { return }
        run.actionCheckpoints.append(ActionCheckpoint(
            key: key, output: String(output.prefix(1200)), recordedAt: Date()))
        run.updatedAt = Date()
        runs[id] = run
        persist(id)
    }

    func resumedAction(key: String) -> ActionCheckpoint? {
        guard let id = Self.activeRunID, let sourceID = runs[id]?.resumedFrom else { return nil }
        return runs[sourceID]?.actionCheckpoints.last { $0.key == key }
    }

    static func classifyFailure(_ observation: String) -> (
        kind: FailureKind, policy: FailurePolicy
    ) {
        let lower = observation.lowercased()
        if lower.contains("permission") || lower.contains("not granted")
            || lower.contains("approval") || lower.contains("access is blocked")
        { return (.permissionRequired, .requestApproval) }
        if lower.contains("stale") || lower.contains("no longer exists")
            || lower.contains("refresh context")
        { return (.staleState, .refreshContext) }
        if lower.contains("timed out") || lower.contains("timeout")
            || lower.contains("temporarily") || lower.contains("rate limit")
        { return (.transient, .retry) }
        if lower.contains("not available") || lower.contains("not found")
            || lower.contains("no route") || lower.contains("unsupported")
        { return (.routeUnavailable, .fallback) }
        if lower.contains("verify") || lower.contains("criterion")
            || lower.contains("mismatch")
        { return (.validationFailed, .repair) }
        if lower.contains("already called") || lower.contains("repeated")
        { return (.repeatedFailure, .stop) }
        return (.terminal, .stop)
    }

    private func start(
        request: String, provider: String, resumedFrom: UUID?, maxToolCalls: Int
    ) -> Run {
        let now = Date()
        let run = Run(
            id: UUID(), request: request, provider: provider, createdAt: now,
            updatedAt: now, status: .running, receipts: [], finalResponse: nil,
            failure: nil, resumedFrom: resumedFrom, objective: request,
            currentNode: nil, completedNodes: [],
            budget: Budget(
                maxToolCalls: max(1, maxToolCalls), maxAttempts: 1,
                maxWallClockSeconds: 120),
            failures: [], actionCheckpoints: [])
        runs[run.id] = run
        persist(run.id)
        return run
    }

    private func finish(_ id: UUID, status: Status, failure: String? = nil) {
        guard var run = runs[id] else { return }
        run.status = status
        run.failure = failure
        run.updatedAt = Date()
        runs[id] = run
        persist(id)
    }

    private func latestTaskRun() -> Run? {
        runs.values
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func hasRunningBackgroundWorker(_ id: UUID) -> Bool {
        guard let run = runs[id] else { return false }
        return run.receipts.contains {
            $0.success && $0.command.hasPrefix("spawn_worker(")
                && $0.output.contains("\"status\": \"running\"")
        }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ id: UUID) {
        guard let run = runs[id], let data = try? JSONEncoder.taskRun.encode(run) else { return }
        try? data.write(to: url(for: id), options: .atomic)
    }

    private func loadRuns() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let run = try? JSONDecoder.taskRun.decode(Run.self, from: data)
            else { continue }
            runs[run.id] = run
        }
    }
}

extension JSONEncoder {
    static var taskRun: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    /// The other half of `JSONEncoder.taskRun`, and it has to exist.
    ///
    /// Runs are written with `.iso8601` dates and were read back with a plain decoder,
    /// whose default strategy expects a number. Every decode therefore threw, and every
    /// caller swallowed it with `try?` — so the store loaded zero runs at launch however
    /// many were on disk. Nothing crashed; "resume last task" simply never found anything
    /// after a restart, and the dashboard reported no runs beside a folder of hundreds.
    static var taskRun: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
