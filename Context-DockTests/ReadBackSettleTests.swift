import Foundation
import Testing
@testable import Context_Dock

/// A scripted sequence of readings, one per re-read, counting how often it is asked.
private final class Readings: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String?]
    private(set) var count = 0
    init(_ readings: [String?]) { queue = readings }
    func next() -> String? {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

struct ReadBackSettleTests {
    private func command(_ name: String) -> SystemCommand {
        SystemCommandsRegistry.defaults.first { $0.name == name }!
    }

    @Test func staleThenFreshSucceedsWithTheFreshValue() async {
        let readings = Readings(["0", "50"])
        let settled = await ReadBackComparison.settle(
            requested: "50", first: "0", delay: .zero, reread: { readings.next() })
        #expect(settled.outcome == .matches)
        #expect(settled.reading == "50")
        #expect(readings.count == 2)
    }

    @Test func alwaysStaleFailsWithBothValuesAndTheLastReading() async {
        let readings = Readings(["0", "0", "0", "7"])
        let result = await GlobalCommandCapabilities.readBackResult(
            command: command("Volume"), requested: "50", readBack: "0",
            attempts: 4, delay: .zero, reread: { readings.next() })
        #expect(!result.success)
        #expect(result.output.contains("asked for 50"))
        #expect(result.output.contains("the Mac reports 7"))
        #expect(result.readBack == "7")
        #expect(readings.count == 4)
    }

    @Test func matchOnTheFirstReadDoesNotReread() async {
        let readings = Readings(["99"])
        let settled = await ReadBackComparison.settle(
            requested: "50", first: "50", delay: .zero, reread: { readings.next() })
        #expect(settled.outcome == .matches)
        #expect(readings.count == 0)
    }

    @Test func notComparableDoesNotRereadAndIsNotAFailure() async {
        let readings = Readings(["x"])
        let result = await GlobalCommandCapabilities.readBackResult(
            command: command("Wi-Fi"), requested: "Home", readBack: "Office",
            delay: .zero, reread: { readings.next() })
        #expect(result.success)
        #expect(readings.count == 0)
    }

    @Test func cancellationIsNotAFailure() async {
        let task = Task {
            await ReadBackComparison.settle(
                requested: "50", first: "0", attempts: 4, delay: .seconds(30),
                reread: { "0" })
        }
        task.cancel()
        let settled = await task.value
        #expect(settled.outcome != .differs)
    }

    @Test func oneAndZeroAreOnAndOffNotNumbers() {
        #expect(ReadBackComparison.compare(requested: "1", readBack: "0") == .differs)
        #expect(ReadBackComparison.compare(requested: "0", readBack: "1") == .differs)
        #expect(ReadBackComparison.compare(requested: "1", readBack: "1") == .matches)
        #expect(ReadBackComparison.compare(requested: "0", readBack: "0") == .matches)
        #expect(ReadBackComparison.compare(requested: "on", readBack: "0") == .differs)
        #expect(ReadBackComparison.compare(requested: "30", readBack: "31") == .matches)
        #expect(ReadBackComparison.compare(requested: "30", readBack: "50") == .differs)
    }
}
