import Foundation
import Testing

@testable import Context_Dock

// Plan §2a: data requests never bring an app forward; only interface requests are UI lane.

struct TwoLaneTests {

    @Test func dataSentencesStayInTheDataLane() {
        for text in [
            "find mail from SBI today", "check my recent mail from Gokula kannan J",
            "read my latest email", "how many unread emails do I have",
            "archive the newest bank email",
        ] {
            #expect(RequestLane.decide(text) == .data, "\"\(text)\"")
        }
    }

    @Test func interfaceSentencesGoToTheUILane() {
        for text in [
            "minimize this window", "open a new tab", "show the mailbox list",
            "zoom in", "open settings", "show sidebar",
        ] {
            #expect(RequestLane.decide(text) == .ui, "\"\(text)\"")
        }
    }

    @Test func wordsInsideOtherWordsDoNotCount() {
        #expect(RequestLane.decide("tabulate the viewer totals") == .data)
    }

    private final class FakeLauncher: DataLaneLauncher {
        var running: Bool
        var launchedHidden: [String] = []
        init(running: Bool) { self.running = running }
        func isRunning(bundleID: String) -> Bool { running }
        func launchHidden(bundleID: String) async { launchedHidden.append(bundleID) }
    }

    @Test func closedAppStartsHidden() async {
        let launcher = FakeLauncher(running: false)
        let started = await DataLane.prepare(bundleID: "com.apple.mail", launcher: launcher)
        #expect(started)
        #expect(launcher.launchedHidden == ["com.apple.mail"])
    }

    @Test func runningAppIsLeftAlone() async {
        let launcher = FakeLauncher(running: true)
        let started = await DataLane.prepare(bundleID: "com.apple.mail", launcher: launcher)
        #expect(!started)
        #expect(launcher.launchedHidden.isEmpty)
    }
}
