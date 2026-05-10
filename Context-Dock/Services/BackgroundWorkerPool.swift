import Foundation
import SwiftUI
import Combine

// MARK: - Background Worker Pool
// Manages multiple concurrent background processes so the AI can "snap tools together".
// Each worker runs independently. TUI workers live in SwiftTerm; regular workers use Process().

// MARK: - Worker Status

enum WorkerStatus {
    case starting
    case running
    case completed(exitCode: Int32)
    case terminated
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .running: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .starting:              return "Starting"
        case .running:               return "Running"
        case .completed(let code):   return code == 0 ? "Done ✓" : "Failed (exit \(code))"
        case .terminated:            return "Stopped"
        case .failed(let msg):       return "Error: \(msg)"
        }
    }

    var color: Color {
        switch self {
        case .starting:              return .orange
        case .running:               return .green
        case .completed(let code):   return code == 0 ? .secondary : .red
        case .terminated:            return .secondary
        case .failed:                return .red
        }
    }
}

// MARK: - Active Worker

struct ActiveWorker: Identifiable {
    let id: UUID
    let command: String
    let purpose: String
    let startedAt: Date
    var status: WorkerStatus
    var outputBuffer: String
    var isPTY: Bool
    var intent: L2ToolIntent?    // the intent this worker satisfies
    fileprivate var process: Process?

    var isActive: Bool { status.isActive }

    var elapsedSeconds: Int {
        Int(Date().timeIntervalSince(startedAt))
    }

    var shortID: String { String(id.uuidString.prefix(6)) }

    var executableName: String {
        command.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first?
            .components(separatedBy: "/").last ?? command
    }
}

// MARK: - Pool

@MainActor
class BackgroundWorkerPool: ObservableObject {
    static let shared = BackgroundWorkerPool()

    @Published var workers: [UUID: ActiveWorker] = [:]

    // Ordered list for UI — most recent first
    var orderedWorkers: [ActiveWorker] {
        workers.values.sorted { $0.startedAt > $1.startedAt }
    }

    var activeWorkers: [ActiveWorker] {
        orderedWorkers.filter { $0.isActive }
    }

    // MARK: - Spawn (Background Process — non-blocking)

    /// Start a background process. Returns immediately — does NOT wait for completion.
    @discardableResult
    func spawn(command: String, purpose: String, intent: L2ToolIntent? = nil) -> UUID {
        let id = UUID()
        let worker = ActiveWorker(
            id: id,
            command: command,
            purpose: purpose,
            startedAt: Date(),
            status: .starting,
            outputBuffer: "",
            isPTY: false,
            intent: intent,
            process: nil
        )
        workers[id] = worker

        Task { await runProcess(id: id, command: command) }

        print("🚀 [WorkerPool] Spawned worker \(id.uuidString.prefix(6)) — \(command.prefix(60))")
        return id
    }

    // MARK: - Register PTY Worker (SwiftTerm — no Process object)

    /// Register a TUI process already running in the SwiftTerm terminal.
    @discardableResult
    func registerPTYWorker(command: String, purpose: String, intent: L2ToolIntent? = nil) -> UUID {
        let id = UUID()
        let worker = ActiveWorker(
            id: id,
            command: command,
            purpose: purpose,
            startedAt: Date(),
            status: .running,
            outputBuffer: "Running in SwiftTerm terminal.",
            isPTY: true,
            intent: intent,
            process: nil
        )
        workers[id] = worker
        print("📺 [WorkerPool] Registered PTY worker \(id.uuidString.prefix(6)) — \(command.prefix(60))")
        return id
    }

    // MARK: - Control

    func terminate(_ id: UUID) {
        workers[id]?.process?.terminate()
        workers[id]?.status = .terminated
        print("⏹ [WorkerPool] Terminated worker \(id.uuidString.prefix(6))")
    }

    func terminateAll() {
        for id in workers.keys where workers[id]?.isActive == true {
            terminate(id)
        }
    }

    func terminateAllWithIntent(_ intent: L2ToolIntent) {
        for (id, w) in workers where w.intent == intent && w.isActive {
            terminate(id)
        }
    }

    func removeCompleted() {
        workers = workers.filter { $0.value.isActive }
    }

    /// Send a line of text to a worker's stdin (e.g. interactive prompts).
    func sendStdin(_ text: String, to id: UUID) {
        guard let pipe = workers[id]?.process?.standardInput as? Pipe else { return }
        if let data = (text + "\n").data(using: .utf8) {
            pipe.fileHandleForWriting.write(data)
        }
    }

    // MARK: - Output

    func output(for id: UUID) -> String {
        workers[id]?.outputBuffer ?? ""
    }

    /// Latest N chars of output — for tool_use result injection.
    func recentOutput(for id: UUID, chars: Int = 2000) -> String {
        let buf = output(for: id)
        return buf.count > chars ? String(buf.suffix(chars)) : buf
    }

    /// Worker status summary for AI injection (e.g. "Worker abc123: Running — ymc play 'lo-fi'")
    func workerSummary(for id: UUID) -> String {
        guard let w = workers[id] else { return "Worker \(id.uuidString.prefix(6)): not found" }
        return "Worker \(w.shortID): \(w.status.label) — \(w.command)"
    }

    // MARK: - Private Execution

    private func runProcess(id: UUID, command: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["TERM"] = "dumb"
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe  = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe
        process.standardInput  = inPipe

        workers[id]?.process = process
        workers[id]?.status = .running

        // Async output capture
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendOutput(text, to: id)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendOutput("[stderr] " + text, to: id)
            }
        }

        do {
            try process.run()
        } catch {
            workers[id]?.status = .failed(error.localizedDescription)
            return
        }

        // Wait on a background thread without blocking Swift concurrency pool
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let code = process.terminationStatus
        workers[id]?.status = .completed(exitCode: code)
        print("✅ [WorkerPool] Worker \(id.uuidString.prefix(6)) finished — exit \(code)")
    }

    private func appendOutput(_ text: String, to id: UUID) {
        workers[id]?.outputBuffer += text
        // Cap at 100 KB to avoid memory growth for long-running processes
        if let buf = workers[id]?.outputBuffer, buf.count > 100_000 {
            workers[id]?.outputBuffer = "...(truncated)\n" + String(buf.suffix(80_000))
        }
    }
}

// MARK: - Workers Status Bar (shown in terminal panel header)

struct WorkersStatusBar: View {
    @ObservedObject var pool = BackgroundWorkerPool.shared
    @State private var isExpanded = false

    var activeCount: Int { pool.activeWorkers.count }

    var body: some View {
        if !pool.workers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Collapsed header
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    HStack(spacing: 8) {
                        // Animated pulse for active workers
                        if activeCount > 0 {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                        Text("\(activeCount) active · \(pool.workers.count - activeCount) done")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: { pool.removeCompleted() }) {
                            Text("Clear")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)

                // Expanded worker list
                if isExpanded {
                    Divider().opacity(0.5)
                    VStack(spacing: 2) {
                        ForEach(pool.orderedWorkers) { worker in
                            WorkerRow(worker: worker)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .background(.ultraThinMaterial.opacity(0.6))
        }
    }
}

struct WorkerRow: View {
    let worker: ActiveWorker
    @ObservedObject var pool = BackgroundWorkerPool.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(worker.status.color)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(worker.executableName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(worker.purpose)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(worker.elapsedSeconds)s")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            if worker.isActive {
                Button(action: { pool.terminate(worker.id) }) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}
