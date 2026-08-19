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
        operation: () async throws -> T
    ) async throws -> T {
        let run = start(request: request, provider: provider, resumedFrom: resumedFrom)
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

    private func start(request: String, provider: String, resumedFrom: UUID?) -> Run {
        let now = Date()
        let run = Run(
            id: UUID(), request: request, provider: provider, createdAt: now,
            updatedAt: now, status: .running, receipts: [], finalResponse: nil,
            failure: nil, resumedFrom: resumedFrom)
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
                  let run = try? JSONDecoder().decode(Run.self, from: data)
            else { continue }
            runs[run.id] = run
        }
    }
}

private extension JSONEncoder {
    static var taskRun: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
