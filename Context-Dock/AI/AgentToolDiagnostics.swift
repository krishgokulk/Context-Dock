import Foundation

/// A temporary record of what each turn was handed, written where it can actually be read.
///
/// Added while chasing a chat that reported no run_menu_command when the plan, the filter and
/// the prompt all provided one. OSLog was the obvious instrument and turned out to be the
/// wrong one: this app's Logger output does not reach the unified log store on the machine
/// where the bug happens, so the first attempt produced silence and no information.
///
/// Delete this once the cause is known. It exists to answer one question.
enum AgentToolDiagnostics {
    private static let queue = DispatchQueue(label: "com.krishgokul.ContextDock.tooldiag")

    private static var fileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Context-Dock/agent-tools.log")
    }

    static func record(_ line: String) {
        guard let fileURL else { return }
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
