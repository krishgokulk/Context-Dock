import Foundation
import Testing

@testable import Context_Dock

/// Approvals for turns that reach DoraX through its own MCP server.
///
/// Every MCP run used to switch the whole app into "unattended": DoraX's own Claude CLI turn
/// asked "is bluetooth on?", got "approval refused unattended", and nothing ran — and while
/// that run was in flight, approvals from every other chat were refused as well. A turn DoraX
/// launched is attended and asks the user; an unknown caller stays unattended, and only its
/// own run is.
@MainActor
@Suite("MCP approval bridge", .serialized)
struct MCPApprovalBridgeTests {
    /// Its own center, not `shared`: other suites ask the shared one for approvals in parallel,
    /// and `.serialized` only orders the tests inside this suite.
    private let center = AICapabilityApprovalCenter()

    private func capability(_ id: String) -> AICapability {
        AICapability(
            id: id,
            title: "Test \(id)",
            appBundleID: "com.apple.systempreferences",
            inputSchema: .init(fields: []),
            riskLevel: .medium,
            runsWithoutAdapter: true,
            executor: { _ in throw AICapabilityError.blocked("not run in tests") })
    }

    private func ask(_ id: String) async -> Bool {
        await center.requestApproval(
            plan: AIActionPlan(capability: id, input: [:], explanation: "test"),
            capability: capability(id),
            context: .appFocused(name: "System Settings", bundleID: "com.apple.systempreferences"))
    }

    /// Waits for a sheet to be on screen, and says whether one arrived.
    private func waitForPending() async -> Bool {
        for _ in 0..<300 where center.pending == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return center.pending != nil
    }

    @Test func dorasOwnCLITurnIsAttendedAndAnyoneElseIsNot() throws {
        #expect(DoraXMCPServer.isAttendedCaller(turnKey: DoraXMCPServer.attendedTurnKey))
        #expect(!DoraXMCPServer.isAttendedCaller(turnKey: nil))
        #expect(!DoraXMCPServer.isAttendedCaller(turnKey: ""))
        #expect(!DoraXMCPServer.isAttendedCaller(turnKey: "a-key-from-an-earlier-launch"))

        // The key reaches the CLI only through the config DoraX writes for its own turns.
        let url = try #require(DoraXMCPServer.writeCLIConfig())
        defer { try? FileManager.default.removeItem(at: url) }
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains(DoraXMCPServer.attendedHeader))
        #expect(contents.contains(DoraXMCPServer.attendedTurnKey))
        #expect(!DoraXMCPServer.registrationCommand.contains(DoraXMCPServer.attendedTurnKey))
    }

    /// The attended CLI turn is told its approvals reach the user, not that they are refused.
    @Test func theAttendedToolListDoesNotPromiseARefusal() throws {
        func askDescription(attended: Bool) throws -> String {
            let tool = try #require(
                DoraXMCPServer.toolDefinitions(attended: attended)
                    .first { $0["name"] as? String == "dorax_ask" })
            return try #require(tool["description"] as? String)
        }
        #expect(try askDescription(attended: false).contains("Runs unattended"))
        #expect(!(try askDescription(attended: true).contains("unattended")))
    }

    /// A CLI turn launched by an attended `dorax_ask` is marked nested, and its own
    /// `dorax_ask` is refused at once instead of starting yet another CLI turn.
    @Test func aDoraxAskInsideADoraxAskIsRefusedAtOnce() throws {
        func config(nested: Bool) throws -> String {
            let url = try #require(
                DoraXMCPServer.$insideAttendedAsk.withValue(nested) {
                    DoraXMCPServer.writeCLIConfig()
                })
            // Only the test's own file goes; the plain one is the live app's.
            defer { if nested { try? FileManager.default.removeItem(at: url) } }
            return try String(contentsOf: url, encoding: .utf8)
        }
        #expect(try config(nested: true).contains(DoraXMCPServer.nestedHeader))
        #expect(!(try config(nested: false).contains(DoraXMCPServer.nestedHeader)))

        #expect(DoraXMCPServer.askRefusal(nested: false) == nil)
        #expect(DoraXMCPServer.askRefusal(nested: true)?.contains("not available") == true)
    }

    @Test func anAttendedCallerIsShownTheApprovalRatherThanRefused() async {
        #expect(!AICapabilityApprovalCenter.refusesEveryApprovalUnattended)
        let answer = Task { await ask("globalcmd.bluetooth") }

        #expect(await waitForPending())
        #expect(center.pending?.capability.id == "globalcmd.bluetooth")
        center.approve()
        #expect(await answer.value)
    }

    @Test func anUnknownCallerIsRefusedAndTheRefusalRecorded() async {
        let run = await AICapabilityApprovalCenter.withUnattendedRun { () async -> Bool in
            #expect(AICapabilityApprovalCenter.refusesEveryApprovalUnattended)
            let approved = await ask("globalcmd.bluetooth")
            AICapabilityApprovalCenter.recordUnattendedRefusal("adapter:notes.create")
            return approved
        }
        #expect(run.result == false)
        #expect(run.approvalsRequested == ["globalcmd.bluetooth", "adapter:notes.create"])
        #expect(center.pending == nil)
        #expect(!AICapabilityApprovalCenter.refusesEveryApprovalUnattended)
    }

    @Test func anUnattendedRunDoesNotRefuseAnotherChatsApproval() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let evalRun = Task {
            await AICapabilityApprovalCenter.withUnattendedRun { () async -> Bool in
                let approved = await ask("system.emptyTrash")
                // Still inside the run while the in-app chat asks below.
                for await _ in gate { break }
                return approved
            }
        }
        // Let the eval run start and make its refused request first.
        for _ in 0..<50 { await Task.yield() }

        let inApp = Task { await ask("globalcmd.volume") }
        #expect(await waitForPending())
        #expect(center.pending?.capability.id == "globalcmd.volume")
        center.approve()
        #expect(await inApp.value)

        open.yield()
        open.finish()
        let eval = await evalRun.value
        #expect(eval.result == false)
        #expect(eval.approvalsRequested == ["system.emptyTrash"])
    }

    /// Two chats can ask at once (an attended CLI turn while the user is in the dock). The
    /// second used to be assigned over the first, whose continuation was never resumed — its
    /// caller waited for an answer that could not come.
    @Test func aSecondApprovalWaitsInsteadOfDroppingTheFirst() async {
        let first = Task { await ask("globalcmd.volume") }
        #expect(await waitForPending())
        #expect(center.pending?.capability.id == "globalcmd.volume")

        let second = Task { await ask("globalcmd.bluetooth") }
        for _ in 0..<50 { await Task.yield() }
        // The sheet on screen is still the first request.
        #expect(center.pending?.capability.id == "globalcmd.volume")

        center.approve()
        #expect(await first.value)

        // The waiting request is promoted rather than lost, and answers on its own.
        #expect(await waitForPending())
        #expect(center.pending?.capability.id == "globalcmd.bluetooth")
        center.deny()
        #expect(await second.value == false)
        #expect(center.pending == nil)
    }
}
