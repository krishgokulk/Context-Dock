import Foundation
import Testing

@testable import Context_Dock

/// The diagnostic that replaces an OSLog nobody can read.
///
/// Serialized because both tests share one file and one default: run in parallel, the test
/// asserting nothing is written watches the other one write it.
@Suite("Turn log", .serialized)
struct DoraXTurnLogTests {
    private var fileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Context-Dock/turns.log")
    }

    /// Off unless asked for: a turn log names the apps and questions a person asks, so it is
    /// not something to start writing because it might be useful later.
    @Test func nothingIsWrittenUnlessItIsSwitchedOn() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.bool(forKey: DoraXTurnLog.enabledKey)
        defaults.set(false, forKey: DoraXTurnLog.enabledKey)
        defer { defaults.set(previous, forKey: DoraXTurnLog.enabledKey) }

        let url = try #require(fileURL)
        try? FileManager.default.removeItem(at: url)
        DoraXTurnLog.record("must not appear")
        // The write is queued; give it the chance it would have had.
        Thread.sleep(forTimeInterval: 0.2)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aLineIsWrittenWhenItIsOn() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.bool(forKey: DoraXTurnLog.enabledKey)
        defaults.set(true, forKey: DoraXTurnLog.enabledKey)
        defer {
            defaults.set(previous, forKey: DoraXTurnLog.enabledKey)
            try? FileManager.default.removeItem(at: fileURL!)
        }

        let url = try #require(fileURL)
        try? FileManager.default.removeItem(at: url)
        DoraXTurnLog.record("turn prepared — provider=test")
        Thread.sleep(forTimeInterval: 0.3)

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("provider=test"))
    }
}
