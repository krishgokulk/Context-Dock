import Testing
import Foundation
@testable import Context_Dock

// MARK: - System packs: Global Commands as chat tools
//
// The Global Commands grouped by topic, each exposing a low-risk status read when it can
// report its value and an approval-gated write for the command itself. Nothing here runs a
// script: the runtime seam stands in for the registry and SystemCommandInteractiveRunner.

@MainActor
private final class RecordingRuntime {
    var commands: [SystemCommand]
    var values: [String: String] = [:]
    private(set) var runs: [String] = []
    private(set) var reads: [String] = []

    init(_ commands: [SystemCommand]) { self.commands = commands }

    var runtime: GlobalCommandRuntime {
        GlobalCommandRuntime(
            commands: { self.commands },
            readValue: { command in
                self.reads.append(command.name)
                return self.values[command.name]
            },
            run: { command, value in
                self.runs.append("\(command.name)=\(value)")
                return ""
            })
    }
}

@MainActor
struct SystemConnectorTests {

    private func defaultCommand(_ name: String) -> SystemCommand {
        SystemCommandsRegistry.defaults.first { $0.name == name }!
    }

    private func capabilities(_ runtime: RecordingRuntime) -> [AICapability] {
        GlobalCommandCapabilities.capabilities(runtime: runtime.runtime)
    }

    // MARK: Grouping

    @Test func defaultCommandsGroupIntoTopicPacks() {
        let group = { SystemConnectorGroup.group(for: self.defaultCommand($0)) }
        #expect(group("Bluetooth") == .bluetooth)
        #expect(group("Wi-Fi") == .wifi)
        #expect(group("Volume") == .sound)
        #expect(group("Appearance") == .appearance)
        #expect(group("Focus") == .focus)
        #expect(group("Windows") == .windows)
        #expect(group("Keep Awake") == .system)
        #expect(group("Empty Trash") == .system)
        // Whole keywords, not substrings: "power off" is not battery, and Process
        // Monitor is not a display.
        #expect(group("Shut Down...") == .system)
        #expect(group("Process Monitor") == .system)
    }

    /// Both radios say "wireless"; the name decides, not whichever pack is listed first.
    @Test func theNameOutranksASharedKeyword() {
        let wifi = SystemCommand(
            name: "Wi-Fi", icon: "wifi", keywords: ["wireless", "bluetooth-free"],
            scriptType: "bash", script: "echo")
        #expect(SystemConnectorGroup.group(for: wifi) == .wifi)
        let brightness = SystemCommand(
            name: "Screen Level", icon: "sun.max", keywords: ["brightness"],
            scriptType: "bash", script: "echo")
        #expect(SystemConnectorGroup.group(for: brightness) == .display)
    }

    @Test func disabledAndPickerCommandsAreNotExposed() {
        let connectors = SystemConnectors.connectors(from: SystemCommandsRegistry.defaults)
        let names = connectors.flatMap(\.commands).map(\.name)
        #expect(names.contains("Bluetooth"))
        #expect(!names.contains("Focus"))  // shipped disabled
        #expect(!names.contains("Top Memory"))  // shipped disabled
        #expect(!names.contains("Windows"))  // a picker, nothing to run
        #expect(!connectors.contains { $0.group == .focus || $0.group == .windows })

        let ids = capabilities(RecordingRuntime(SystemCommandsRegistry.defaults)).map(\.id)
        #expect(!ids.contains { $0.contains("focus") || $0.contains("top-memory") })
    }

    @Test func disablingACommandRemovesBothOfItsCapabilities() {
        var appearance = defaultCommand("Appearance")
        appearance.isEnabled = false
        #expect(capabilities(RecordingRuntime([appearance])).isEmpty)
    }

    // MARK: Shape

    @Test func aToggleCommandYieldsOneReadAndOneWrite() {
        let caps = capabilities(RecordingRuntime([defaultCommand("Appearance")]))
        #expect(caps.map(\.id) == ["globalcmd.appearance.status", "globalcmd.appearance"])
        #expect(caps[0].riskLevel == .low)
        #expect(!caps[0].riskLevel.requiresApproval)
        #expect(caps[0].inputSchema.fields.isEmpty)
        #expect(caps[1].riskLevel == .medium)
        #expect(caps[1].riskLevel.requiresApproval)
        #expect(caps[1].inputSchema.fields.map(\.name) == ["value"])
    }

    @Test func aSliderWriteTakesItsRange() {
        let caps = capabilities(RecordingRuntime([defaultCommand("Volume")]))
        #expect(caps.map(\.id) == ["globalcmd.sound.volume.status", "globalcmd.volume"])
        #expect(caps[1].riskLevel == .medium)
        #expect(caps[1].inputSchema.fields.first?.description == "a number from 0 to 100")
        #expect(caps[1].title.contains("Sound pack"))
    }

    /// No value to read means no status capability, and a one-shot script keeps the high
    /// risk that puts Empty Trash behind the approval card.
    @Test func aOneShotCommandYieldsOnlyItsWrite() {
        let caps = capabilities(RecordingRuntime([defaultCommand("Empty Trash")]))
        #expect(caps.map(\.id) == ["globalcmd.empty-trash"])
        #expect(caps[0].riskLevel == .high)
    }

    @Test func radioStatusIdsAreThePackItself() {
        #expect(GlobalCommandCapabilities.statusCapabilityID(for: defaultCommand("Bluetooth"))
            == "globalcmd.bluetooth.status")
        #expect(GlobalCommandCapabilities.statusCapabilityID(for: defaultCommand("Wi-Fi"))
            == "globalcmd.wifi.status")
        #expect(GlobalCommandCapabilities.statusCapabilityID(for: defaultCommand("Keep Awake"))
            == "globalcmd.system.keep-awake.status")
    }

    // MARK: Execution goes through the shared runtime

    @Test func readingGoesThroughTheSharedReaderAndRunsNothing() async throws {
        let recorder = RecordingRuntime([defaultCommand("Volume")])
        recorder.values["Volume"] = "42"
        let status = try #require(capabilities(recorder).first(where: { $0.id.hasSuffix(".status") }))

        let result = try await status.executor(
            AICapabilityExecutionRequest(input: [:], context: .none))

        #expect(result.success)
        #expect(result.output == "Volume is currently 42.")
        #expect(recorder.reads == ["Volume"])
        #expect(recorder.runs.isEmpty)
    }

    @Test func writingGoesThroughTheSharedRunner() async throws {
        let recorder = RecordingRuntime([defaultCommand("Volume"), defaultCommand("Appearance")])
        let caps = capabilities(recorder)
        let volume = try #require(caps.first(where: { $0.id == "globalcmd.volume" }))
        let appearance = try #require(caps.first(where: { $0.id == "globalcmd.appearance" }))

        _ = try await volume.executor(
            AICapabilityExecutionRequest(input: ["value": "30"], context: .none))
        _ = try await appearance.executor(
            AICapabilityExecutionRequest(input: ["value": "on"], context: .none))

        #expect(recorder.runs == ["Volume=30", "Appearance=on"])
    }

    /// Disabled after the capabilities were registered, before the refresh — the status
    /// read re-resolves the command and refuses rather than reading a switched-off one.
    @Test func aStatusReadRefusesACommandDisabledSinceRegistration() async throws {
        let recorder = RecordingRuntime([defaultCommand("Appearance")])
        let status = try #require(capabilities(recorder).first)
        recorder.commands[0].isEnabled = false

        let result = try await status.executor(
            AICapabilityExecutionRequest(input: [:], context: .none))

        #expect(!result.success)
        #expect(recorder.reads.isEmpty)
    }

    // MARK: find_capability

    @Test func findCapabilityFindsBluetoothAndVolume() {
        let catalogue = capabilities(RecordingRuntime(SystemCommandsRegistry.defaults))
            .map { (id: $0.id, title: $0.title) }

        let bluetooth = AgentToolRegistry.rankedCapabilityIDs(
            query: "is bluetooth on?", catalogue: catalogue)
        #expect(bluetooth.first == "globalcmd.bluetooth.status")
        #expect(bluetooth.contains("globalcmd.bluetooth"))

        let volume = AgentToolRegistry.rankedCapabilityIDs(
            query: "set volume to 30", catalogue: catalogue)
        #expect(Set(volume.prefix(2)) == ["globalcmd.sound.volume.status", "globalcmd.volume"])
    }

    // MARK: Activity rows follow-ups

    /// A picker — one of a fixed set of presets — moves a setting the user can move back.
    /// Saved copies of Appearance carry only their presets, no interaction type.
    @Test func aPickerStyleCommandIsMediumRisk() {
        var picker = defaultCommand("Appearance")
        picker.interaction = ""
        #expect(picker.interactionType == .none)
        #expect(!GlobalCommandCapabilities.presetValues(for: picker).isEmpty)
        #expect(GlobalCommandCapabilities.riskLevel(for: picker) == .medium)
        // A one-shot script without presets is still high.
        #expect(GlobalCommandCapabilities.riskLevel(for: defaultCommand("Empty Trash")) == .high)
    }

    /// Ranked over the registry's own order — sorted by id, which puts the write first.
    @Test func aStatusQuestionRanksTheStatusReadFirst() {
        let catalogue = capabilities(RecordingRuntime(SystemCommandsRegistry.defaults))
            .map { (id: $0.id, title: $0.title) }
            .sorted { $0.id < $1.id }
        let ranked = AgentToolRegistry.rankedCapabilityIDs(
            query: "is bluetooth on?", catalogue: catalogue)
        #expect(ranked.first == "globalcmd.bluetooth.status")

        #expect(GlobalCommandCapabilities.asksForCurrentState("is bluetooth on?"))
        #expect(GlobalCommandCapabilities.asksForCurrentState("what's the volume"))
        #expect(!GlobalCommandCapabilities.asksForCurrentState("turn bluetooth off"))
        #expect(AgentToolRegistry.statusQuestionBonus(
            asksState: false, capabilityID: "globalcmd.bluetooth.status") == 0)
    }

    @Test func aWriteThatCanBeReadIsReadBack() async throws {
        let recorder = RecordingRuntime([defaultCommand("Volume")])
        recorder.values["Volume"] = "30"
        let volume = try #require(capabilities(recorder).first(where: { $0.id == "globalcmd.volume" }))

        let result = try await volume.executor(
            AICapabilityExecutionRequest(input: ["value": "30"], context: .none))

        #expect(result.success)
        #expect(result.output == "Volume 30 ✓ (read back 30)")
        #expect(result.readBack == "30")
        #expect(recorder.runs == ["Volume=30"])
        #expect(!result.output.contains("independent"))
    }

    @Test func aReadBackThatDisagreesSaysSo() {
        #expect(ReadBackComparison.compare(requested: "off", readBack: "false") == .matches)
        #expect(ReadBackComparison.compare(requested: "dark", readBack: "true") == .matches)
        #expect(ReadBackComparison.compare(requested: "30", readBack: "55") == .differs)
    }

    // MARK: Read-back that disagrees fails the step

    @Test func aReadBackThatDisagreesFailsTheStepWithBothValues() async throws {
        let recorder = RecordingRuntime([defaultCommand("Volume")])
        recorder.values["Volume"] = "0"  // muted: the Mac ignores the write
        let volume = try #require(capabilities(recorder).first(where: { $0.id == "globalcmd.volume" }))

        let result = try await volume.executor(
            AICapabilityExecutionRequest(input: ["value": "50"], context: .none))

        #expect(!result.success)
        #expect(result.output.contains("asked for 50"))
        #expect(result.output.contains("the Mac reports 0"))
        #expect(!result.output.contains("✓"))
    }

    @Test func aReadBackWithinToleranceStillSucceeds() async throws {
        let recorder = RecordingRuntime([defaultCommand("Volume")])
        recorder.values["Volume"] = "31"
        let volume = try #require(capabilities(recorder).first(where: { $0.id == "globalcmd.volume" }))

        let result = try await volume.executor(
            AICapabilityExecutionRequest(input: ["value": "30"], context: .none))

        #expect(result.success)
        #expect(result.output == "Volume 30 ✓ (read back 31)")
    }

    @Test func aSettingThatCannotBeReadIsNotAFailure() async throws {
        let recorder = RecordingRuntime([defaultCommand("Volume")])  // no value to read back
        let volume = try #require(capabilities(recorder).first(where: { $0.id == "globalcmd.volume" }))

        let result = try await volume.executor(
            AICapabilityExecutionRequest(input: ["value": "30"], context: .none))

        #expect(result.success)
        #expect(result.readBack == nil)
        #expect(!result.output.contains("✓"))
    }

    @Test func theStepFlagAndTheTextTheModelSeesAgree() async {
        let command = defaultCommand("Volume")
        let bad = await GlobalCommandCapabilities.readBackResult(
            command: command, requested: "50", readBack: "0", delay: .zero)
        let good = await GlobalCommandCapabilities.readBackResult(
            command: command, requested: "50", readBack: "50", delay: .zero)
        #expect(!bad.success)
        #expect(bad.output.contains("asked for 50") && bad.output.contains("reports 0"))
        #expect(good.success)
        #expect(good.output.contains("read back 50"))
        // The unified result never adds a tick to a failure, and never calls it verified.
        let line = ActivitySummary.resultLine(
            result: bad.output, isWrite: true, verification: .unverified, readBack: bad.readBack)
        #expect(!line.contains("✓"))
    }
}
