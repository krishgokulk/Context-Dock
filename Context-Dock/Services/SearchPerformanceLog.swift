import Foundation
import os

// Lightweight perf instrumentation for the global search pipeline.
// Uses os.Logger so disabled-level messages cost ~nanoseconds.
// View logs in Console.app with subsystem "com.krishgokul.ContextDock" category "SearchPerf".
final class SearchPerformanceLog {

    nonisolated static let shared = SearchPerformanceLog()
    nonisolated private init() {}

    private let log = Logger(subsystem: "com.krishgokul.ContextDock", category: "SearchPerf")
    private let signpostLog = OSLog(subsystem: "com.krishgokul.ContextDock", category: .pointsOfInterest)

    // Record a single timed event.
    // label: e.g. "deferred pill rebuild", "global grouped phase2", "app index query"
    nonisolated func record(label: String, elapsedMS: Double, query: String, pills: Int = 0) {
        if pills > 0 {
            log.debug("[\(label, privacy: .public)] \(String(format: "%.1f", elapsedMS), privacy: .public) ms q='\(query, privacy: .public)' pills=\(pills)")
        } else {
            log.debug("[\(label, privacy: .public)] \(String(format: "%.1f", elapsedMS), privacy: .public) ms q='\(query, privacy: .public)'")
        }
        // Also write to stderr for Xcode console during dev builds only.
        #if DEBUG
        if elapsedMS >= 8 {
            fputs("[SearchPerf] [\(label)] \(String(format: "%.1f", elapsedMS)) ms q='\(query)' pills=\(pills)\n", stderr)
        }
        #endif
    }

    // Convenience: wrap a synchronous block and log its duration.
    nonisolated func measure<T>(_ label: String, query: String = "", body: () -> T) -> T {
        let start = Date()
        let result = body()
        let ms = Date().timeIntervalSince(start) * 1_000
        if ms >= 8 { record(label: label, elapsedMS: ms, query: query) }
        return result
    }

    nonisolated func signpost<T>(
        _ name: StaticString,
        query: String = "",
        body: () -> T
    ) -> T {
        let state = beginInterval(name, query: query)
        let result = body()
        endInterval(name, state: state)
        return result
    }

    nonisolated func signpostAsync<T>(
        _ name: StaticString,
        query: String = "",
        body: () async -> T
    ) async -> T {
        let state = beginInterval(name, query: query)
        let result = await body()
        endInterval(name, state: state)
        return result
    }

    nonisolated func beginInterval(
        _ name: StaticString,
        query: String = ""
    ) -> (id: OSSignpostID, detail: String) {
        let signpostID = OSSignpostID(log: signpostLog)
        let detail = "qLen=\(query.count)"
        os_signpost(.begin, log: signpostLog, name: name, signpostID: signpostID, "%{public}s", detail)
        return (signpostID, detail)
    }

    nonisolated func endInterval(
        _ name: StaticString,
        state: (id: OSSignpostID, detail: String)
    ) {
        os_signpost(.end, log: signpostLog, name: name, signpostID: state.id, "%{public}s", state.detail)
    }
}
