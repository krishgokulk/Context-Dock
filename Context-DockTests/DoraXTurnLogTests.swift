import Foundation
import Testing

@testable import Context_Dock

/// The diagnostic that replaces an OSLog nobody can read.
///
/// Each test owns its switch and its file: a private UserDefaults suite and a temporary log,
/// written through its own `DoraXTurnLog.Sink`. Nothing here reads or writes
/// `UserDefaults.standard` or the app's own turns.log, so no other suite can reach it (#169).
@Suite("Turn log")
struct DoraXTurnLogTests {

    /// A sink nobody else can see, switched on or off.
    private struct OwnedSink {
        let sink: DoraXTurnLog.Sink
        let fileURL: URL
        let suiteName: String

        init(enabled: Bool) {
            suiteName = "DoraXTurnLogTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.set(enabled, forKey: DoraXTurnLog.enabledKey)
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("turn-log-\(UUID().uuidString).log")
            sink = DoraXTurnLog.Sink(defaults: defaults, fileURL: fileURL)
        }

        func remove() {
            try? FileManager.default.removeItem(at: fileURL)
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }

    /// Off unless asked for: a turn log names the apps and questions a person asks, so it is
    /// not something to start writing because it might be useful later.
    @Test func nothingIsWrittenUnlessItIsSwitchedOn() {
        let owned = OwnedSink(enabled: false)
        defer { owned.remove() }

        owned.sink.record("must not appear")
        owned.sink.flush()

        #expect(!FileManager.default.fileExists(atPath: owned.fileURL.path))
    }

    @Test func aLineIsWrittenWhenItIsOn() throws {
        let owned = OwnedSink(enabled: true)
        defer { owned.remove() }

        owned.sink.record("turn prepared — provider=test")
        owned.sink.flush()

        let contents = try String(contentsOf: owned.fileURL, encoding: .utf8)
        #expect(contents.contains("provider=test"))
    }
}
