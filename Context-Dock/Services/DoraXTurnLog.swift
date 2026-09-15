import Foundation

/// A record of what each AI turn was given, written where it can actually be read.
///
/// The pipeline already logs its stages through OSLog, and on the machine this was written
/// for, none of it arrives: a marker emitted from a separate process under the same subsystem
/// never reaches the store either, while `log`'s own entries do. Notice-level logging from
/// third-party processes is switched off system-wide, which is a `sudo log config` decision
/// belonging to whoever owns the Mac — not something an app should quietly work around, and
/// not something it should depend on either.
///
/// The cost of depending on it was a day: a chat insisted it had no menu tool, four separate
/// checks said the tool was there, and the answer — that the provider returns before the tool
/// loop and never asks for tools at all — was invisible until a file recorded it.
///
/// Off by default, because a turn log names the apps and questions a person asks:
///
///     defaults write com.krishgokul.ContextDock doraxTurnLogEnabled -bool YES
///     tail -f ~/Library/Application\ Support/Context-Dock/turns.log
enum DoraXTurnLog {
    static let enabledKey = "doraxTurnLogEnabled"

    private static let queue = DispatchQueue(label: "com.krishgokul.ContextDock.turnlog")
    /// Past this the file is started again. A diagnostic that grows without limit becomes a
    /// second problem on a disk somebody has to notice.
    private static let maximumBytes = 2_000_000

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private static var fileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Context-Dock/turns.log")
    }

    static func record(_ line: @autoclosure () -> String) {
        guard isEnabled, let fileURL else { return }
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line())\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            let size = (try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            if let handle = (size ?? 0) < maximumBytes
                ? try? FileHandle(forWritingTo: fileURL) : nil
            {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
