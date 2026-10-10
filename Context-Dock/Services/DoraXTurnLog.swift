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
    nonisolated static let enabledKey = "doraxTurnLogEnabled"

    nonisolated private static let queue = DispatchQueue(
        label: "com.krishgokul.ContextDock.turnlog")
    /// Past this the file is started again. A diagnostic that grows without limit becomes a
    /// second problem on a disk somebody has to notice.
    nonisolated private static let maximumBytes = 2_000_000

    /// Where a line goes, and whether it goes at all.
    ///
    /// A value rather than the two globals it used to be, so a test can own its switch and its
    /// file: a suite flipping `UserDefaults.standard` while another suite records a turn is the
    /// flake in #169, and a new writer must not add a second way to hit it.
    nonisolated struct Sink: Sendable {
        let defaults: UserDefaults
        let fileURL: URL?

        init(defaults: UserDefaults, fileURL: URL?) {
            self.defaults = defaults
            self.fileURL = fileURL
        }

        var isEnabled: Bool { defaults.bool(forKey: DoraXTurnLog.enabledKey) }

        func record(_ line: String) {
            guard isEnabled, let fileURL else { return }
            let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
            DoraXTurnLog.queue.async { DoraXTurnLog.append(stamped, to: fileURL) }
        }

        /// Returns once every line queued before it has reached the file. Writes stay off the
        /// caller's thread; this is for a reader that must see them, never for the app.
        func flush() {
            DoraXTurnLog.queue.sync {}
        }
    }

    /// The app's own switch and file.
    nonisolated static let standard = Sink(
        defaults: .standard,
        fileURL: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Context-Dock/turns.log"))

    static var isEnabled: Bool { standard.isEnabled }

    static func record(_ line: @autoclosure () -> String) {
        guard standard.isEnabled else { return }
        standard.record(line())
    }

    nonisolated private static func append(_ stamped: String, to fileURL: URL) {
        guard let data = stamped.data(using: .utf8) else { return }
        let size = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size < maximumBytes, let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
