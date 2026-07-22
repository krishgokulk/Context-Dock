// ProcessMonitorService.swift
// Context-Dock
//
// Samples running processes for the built-in "Process Monitor" global command
// (provider:processes). Groups every process under its owning .app bundle so an
// app and all of its helper processes collapse into a single row (Dia + 46 helper
// processes → one "Dia" row), exactly like Activity Monitor / Raycast. Processes
// that don't live inside an .app bundle (WindowServer, ANECompilerService, other
// daemons) each stay as their own row.
//
// CPU% and RSS come from a single `ps` invocation — fast, no privileges, no
// private APIs. Bundle resolution uses libproc's proc_pidpath.
//
// CRITICAL: sampling runs `ps` via Process, whose waitUntilExit() pumps the run
// loop. That MUST NOT run inside the SwiftUI view-build path (it re-enters the
// view graph and aborts). So the pills builder reads ONLY the cached snapshot; a
// refresh is dispatched to a background queue and reports back on the main thread.

import AppKit
import Darwin

enum ProcessSortMode: String, CaseIterable, Identifiable {
    case memory
    case cpu

    var id: String { rawValue }
    var label: String { self == .memory ? "Memory Usage" : "CPU Usage" }
}

struct ProcessGroup: Identifiable {
    let id: String          // bundle id, or the executable name for un-bundled procs
    let name: String
    let bundlePath: String?  // outermost .app path when bundled
    let cpuPercent: Double   // summed %cpu (can exceed 100 on multi-core)
    let memoryBytes: UInt64  // summed RSS
    let pids: [pid_t]

    var processCount: Int { pids.count }
}

final class ProcessMonitorService {
    static let shared = ProcessMonitorService()
    private init() {}

    /// How long a snapshot stays "fresh"; the scope re-samples when older.
    static let stalenessInterval: TimeInterval = 2.0

    /// Current sort column for the Process Monitor scope. Toggled from the scope's
    /// sort row; persists for the session. Applied at read time so toggling needs
    /// no resample.
    var sortMode: ProcessSortMode = .memory

    // Latest sample + when it was taken. Only mutated on the main thread.
    private(set) var snapshot: [ProcessGroup] = []
    private var lastSampledAt: Date = .distantPast
    private var isRefreshing = false

    private let sampleQueue = DispatchQueue(label: "com.krishgokul.ContextDock.processMonitor", qos: .userInitiated)
    private var iconCache: [String: NSImage] = [:]

    var isSnapshotStale: Bool {
        snapshot.isEmpty || Date().timeIntervalSince(lastSampledAt) > Self.stalenessInterval
    }

    /// Cached groups, sorted by the current mode. Cheap + pure — safe to call while
    /// building the view.
    func cachedGroups() -> [ProcessGroup] {
        sortGroups(snapshot, by: sortMode)
    }

    /// Sample on a background queue, then update the cache and fire `completion` on
    /// the main thread. No-ops if a refresh is already in flight. NEVER blocks the
    /// caller (so it is safe to kick from the view-build path).
    func refresh(completion: @escaping () -> Void) {
        if isRefreshing { return }
        isRefreshing = true
        sampleQueue.async { [weak self] in
            guard let self else { return }
            let groups = self.sampleBlocking()
            DispatchQueue.main.async {
                self.snapshot = groups
                self.lastSampledAt = Date()
                self.isRefreshing = false
                completion()
            }
        }
    }

    func sortGroups(_ groups: [ProcessGroup], by sort: ProcessSortMode) -> [ProcessGroup] {
        switch sort {
        case .memory: return groups.sorted { $0.memoryBytes > $1.memoryBytes }
        case .cpu: return groups.sorted { $0.cpuPercent > $1.cpuPercent }
        }
    }

    /// Icon for a group — the real app icon when bundled, nil (SF fallback) otherwise.
    func icon(for group: ProcessGroup) -> NSImage? {
        guard let path = group.bundlePath else { return nil }
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 20, height: 20)
        iconCache[path] = icon
        return icon
    }

    /// Terminate every PID in the group. SIGTERM first (graceful) unless `force`.
    @discardableResult
    func kill(_ group: ProcessGroup, force: Bool = false) -> Int {
        let sig = force ? SIGKILL : SIGTERM
        var delivered = 0
        for pid in group.pids where pid > 0 {
            if Darwin.kill(pid, sig) == 0 { delivered += 1 }
        }
        return delivered
    }

    func formattedMemory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    // MARK: - Sampling (background only)

    private struct PSRow {
        let pid: pid_t
        let cpu: Double
        let rssKB: UInt64
        let comm: String
    }

    /// Blocking sample. MUST run off the main/view path (uses Process.waitUntilExit,
    /// which pumps the run loop).
    private func sampleBlocking() -> [ProcessGroup] {
        let rows = readPSRows()
        guard !rows.isEmpty else { return [] }

        struct Acc {
            var name: String
            var bundlePath: String?
            var cpu: Double = 0
            var rssKB: UInt64 = 0
            var pids: [pid_t] = []
        }
        var groups: [String: Acc] = [:]

        for row in rows {
            let key: String
            let name: String
            let bundlePath = outermostAppPath(forPID: row.pid)
            if let bundlePath {
                key = bundlePath
                name = (bundlePath as NSString).lastPathComponent
                    .replacingOccurrences(of: ".app", with: "")
            } else {
                key = row.comm
                name = (row.comm as NSString).lastPathComponent
            }
            var acc = groups[key] ?? Acc(name: name, bundlePath: bundlePath)
            acc.cpu += row.cpu
            acc.rssKB += row.rssKB
            acc.pids.append(row.pid)
            groups[key] = acc
        }

        return groups.map { key, acc in
            ProcessGroup(
                id: key,
                name: acc.name,
                bundlePath: acc.bundlePath,
                cpuPercent: acc.cpu,
                memoryBytes: acc.rssKB * 1024,
                pids: acc.pids
            )
        }
    }

    private func readPSRows() -> [PSRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,%cpu=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var rows: [PSRow] = []
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for line in text.split(separator: "\n") {
            let parts = line.split(
                maxSplits: 3, omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 4,
                let pid = pid_t(parts[0]),
                let cpu = Double(parts[1]),
                let rss = UInt64(parts[2])
            else { continue }
            if pid == selfPID { continue }
            rows.append(PSRow(pid: pid, cpu: cpu, rssKB: rss, comm: String(parts[3])))
        }
        return rows
    }

    // MARK: - Bundle resolution

    private func executablePath(forPID pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (= 4 * MAXPATHLEN) isn't bridged into Swift.
        let maxSize = Int(MAXPATHLEN) * 4
        var buffer = [CChar](repeating: 0, count: maxSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The OUTERMOST enclosing .app path, so helper apps nested inside a parent
    /// bundle (…/Dia.app/Contents/Frameworks/Dia Helper.app/…) group under Dia.app.
    private func outermostAppPath(forPID pid: pid_t) -> String? {
        guard let path = executablePath(forPID: pid) else { return nil }
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }
}
