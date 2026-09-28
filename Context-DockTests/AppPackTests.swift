import Testing
import Foundation
@testable import Context_Dock

// MARK: - App Packs: the Settings list, its switch, its counts, and "Sends data out"
//
// All pure: adapters, commands and each pack's linked resources are handed in, so nothing
// reads the adapter directory, the Global Commands registry or a running app.

@MainActor
struct AppPackTests {

    private func action(
        _ id: String, _ type: AdapterActionType, name: String? = nil,
        menuPath: [String]? = nil, script: String? = nil, url: String? = nil
    ) -> AdapterAction {
        AdapterAction(
            id: id, name: name ?? id, icon: "bolt", type: type,
            menuPath: menuPath, script: script, urlScheme: url)
    }

    private func adapter(
        _ bundleID: String, _ name: String, actions: [AdapterAction] = [], enabled: Bool = true
    ) -> AppAdapter {
        AppAdapter(
            id: bundleID, appName: name, bundleId: bundleID, icon: "app",
            isEnabled: enabled, isBuiltIn: false, actions: actions)
    }

    private func command(_ name: String, keywords: [String] = [], enabled: Bool = true,
                         script: String = "do shell script \"true\"") -> SystemCommand {
        SystemCommand(
            name: name, icon: "gear", keywords: keywords, scriptType: "applescript",
            script: script, enabled: enabled)
    }

    // MARK: The list

    @Test func listHasAppPacksThenSystemPacks() {
        let packs = AppPacks.all(
            adapters: [adapter("com.apple.Safari", "Safari"), adapter("com.apple.Notes", "Notes")],
            commands: [command("Bluetooth", keywords: ["bluetooth"]), command("Volume")],
            resources: { _ in .none })
        #expect(packs.map(\.id) == [
            "app:com.apple.Safari", "app:com.apple.Notes", "system:bluetooth", "system:sound",
        ])
        #expect(packs.filter(\.isSystem).map(\.name) == ["Bluetooth", "Sound"])
    }

    @Test func aSystemPackThatIsOffIsStillListed() {
        let packs = AppPacks.all(
            adapters: [],
            commands: [command("Bluetooth", keywords: ["bluetooth"], enabled: false)],
            resources: { _ in .none })
        #expect(packs.map(\.id) == ["system:bluetooth"])
        #expect(packs.first?.isEnabled == false)
    }

    @Test func aCommandWithNothingToRunMakesNoPack() {
        let packs = AppPacks.all(
            adapters: [],
            commands: [command("Windows", keywords: ["provider:windows"])],
            resources: { _ in .none })
        #expect(packs.isEmpty)
    }

    // MARK: The switch

    @Test func theAppSwitchTogglesOnlyThatAdapter() {
        let adapters = [adapter("com.apple.Safari", "Safari"), adapter("com.apple.Notes", "Notes")]
        let off = AppPacks.adapters(adapters, settingBundleID: "com.apple.Safari", enabled: false)
        #expect(off.map(\.isEnabled) == [false, true])
        let packs = AppPacks.all(adapters: off, commands: [], resources: { _ in .none })
        #expect(packs.map(\.isEnabled) == [false, true])
        let on = AppPacks.adapters(off, settingBundleID: "com.apple.Safari", enabled: true)
        #expect(on.map(\.isEnabled) == [true, true])
    }

    @Test func theSystemSwitchTogglesEveryCommandInItsPackAndNoOther() {
        let commands = [
            command("Bluetooth", keywords: ["bluetooth"]),
            command("Bluetooth Devices", keywords: ["bluetooth"]),
            command("Volume"),
            command("Windows", keywords: ["provider:windows"]),
        ]
        let off = AppPacks.commands(commands, settingGroup: .bluetooth, enabled: false)
        #expect(off.map(\.isEnabled) == [false, false, true, true])
        let bluetooth = AppPacks.all(adapters: [], commands: off, resources: { _ in .none })
            .first { $0.id == "system:bluetooth" }
        #expect(bluetooth?.isEnabled == false)

        // A pack with any command on reads as on; switching it on turns all of them on.
        var partly = off
        partly[0].isEnabled = true
        #expect(AppPacks.all(adapters: [], commands: partly, resources: { _ in .none })
            .first { $0.id == "system:bluetooth" }?.isEnabled == true)
        let on = AppPacks.commands(off, settingGroup: .bluetooth, enabled: true)
        #expect(on.map(\.isEnabled) == [true, true, true, true])
    }

    @Test func aSwitchedOffSystemPackIsGoneFromChat() {
        let off = AppPacks.commands(
            [command("Bluetooth", keywords: ["bluetooth"]), command("Volume")],
            settingGroup: .bluetooth, enabled: false)
        #expect(SystemConnectors.connectors(from: off).map(\.group) == [.sound])
    }

    // MARK: Counts

    @Test func countsReadFromTheAdapterAndItsResources() {
        var safari = adapter("com.apple.Safari", "Safari", actions: (1...12).map {
            action("a\($0)", .menubar, menuPath: ["File", "Item \($0)"])
        })
        safari.contextReaders = [AdapterContextReader(id: "r", name: "Tab", type: "applescript", script: "")]
        let pack = AppPacks.appPack(
            safari, resources: AppPackResources(skills: 2, menuCommands: 29, tools: 3))
        #expect(pack.counts == AppPackCounts(
            actions: 12, skills: 2, menuCommands: 29, tools: 3, contextReaders: 1))
        #expect(pack.counts.summary
            == "12 actions · 2 skills · 29 menu commands · 3 tools · 1 context reader")
    }

    @Test func countSummaryLeavesOutZerosAndSingularises() {
        #expect(AppPackCounts(actions: 1, tools: 1).summary == "1 action · 1 tool")
        #expect(AppPackCounts().summary == "Nothing yet")
    }

    @Test func aSystemPackCountsItsCommandsAsActions() {
        let pack = AppPacks.all(
            adapters: [],
            commands: [command("Bluetooth", keywords: ["bluetooth"]),
                       command("Bluetooth Devices", keywords: ["bluetooth"])],
            resources: { _ in .none }).first
        #expect(pack?.counts.summary == "2 actions")
    }

    // MARK: Sends data out

    @Test func sendsDataOutWhenAnActionCanReachOffTheMac() {
        #expect(AppPack.sendsDataOut(actions: [action("ask", .aiPrompt)]))
        #expect(AppPack.sendsDataOut(actions: [action("web", .urlScheme, url: "https://example.com/?q=$SELECTION")]))
        #expect(AppPack.sendsDataOut(actions: [action("share", .menubar, menuPath: ["File", "Share…"])]))
        #expect(AppPack.sendsDataOut(actions: [action("k", .shortcut, name: "Send to Kindle")]))
        #expect(AppPack.sendsDataOut(actions: [action("up", .shell, script: "curl -F f=@x https://x.io")]))
        #expect(AppPack.sendsDataOut(actions: [action("js", .pageJS, script: "fetch('/api')")]))
        let remote = MCPServerConfig(name: "remote", command: "https://mcp.example.com", transport: "http")
        #expect(AppPack.sendsDataOut(actions: [], mcpServers: [remote]))
    }

    @Test func staysLocalWhenNothingLeavesTheMac() {
        #expect(!AppPack.sendsDataOut(actions: [
            action("tab", .menubar, menuPath: ["File", "New Tab"]),
            action("shared", .menubar, menuPath: ["View", "Shared Albums"]),
            action("maps", .urlScheme, url: "x-apple.systempreferences:com.apple.preference"),
            action("say", .shell, script: "say hello"),
            action("md", .savePageMarkdown),
        ]))
        let local = MCPServerConfig(name: "local", command: "npx", args: ["server"])
        #expect(!AppPack.sendsDataOut(actions: [], mcpServers: [local]))
        #expect(!AppPack.sendsDataOut(actions: []))
    }

    @Test func aSystemPackSendsDataOutOnlyWhenAScriptReachesTheNetwork() {
        #expect(!AppPack.sendsDataOut(commands: [command("Volume")]))
        #expect(AppPack.sendsDataOut(commands: [
            command("Weather", script: "do shell script \"curl wttr.in\""),
        ]))
    }

    @Test func thePackRowCarriesTheLabel() {
        let pack = AppPacks.appPack(
            adapter("com.apple.Safari", "Safari", actions: [action("ask", .aiPrompt)]),
            resources: .none)
        #expect(pack.sendsDataOut)
    }
}
