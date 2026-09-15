// Context-DockTests/PluginMigrationTests.swift
// Nothing a user built may be lost in the move. Every built-in converts with zero errors;
// a representative of each legacy shape converts to the manifest the table in the plan
// describes; and keywords the user typed survive while the meta keywords do not.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin migration")
@MainActor
struct PluginMigrationTests {

    @Test("Every built-in Global Command converts with zero schema errors")
    func allBuiltInsConvert() {
        for command in SystemCommandsRegistry.defaults {
            let m = PluginMigration.manifest(from: command)
            let errors = PluginSchema.validate(m).filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(command.name): \(errors.map(\.message))")
            #expect(m.name == command.name)
            #expect(m.icon == command.icon)
        }
    }

    @Test("Names become slugs")
    func slugs() {
        #expect(PluginMigration.slug("Wi-Fi") == "wi-fi")
        #expect(PluginMigration.slug("Restart...") == "restart")
        #expect(PluginMigration.slug("Top CPU") == "top-cpu")
        #expect(PluginMigration.slug("  Keep   Awake ") == "keep-awake")
    }

    @Test("Meta keywords are consumed; user keywords survive")
    func keywordsSurvive() throws {
        let cmd = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Top Memory" })
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.keywords.contains("ram"))
        #expect(!m.keywords.contains { $0.hasPrefix("provider:") || $0.hasPrefix("refresh:") })
    }

    @Test("A provider:custom command becomes a jsonl list with its refresh")
    func customListBecomesList() throws {
        let cmd = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Top Memory" })
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.data?.format == .jsonl)
        #expect(m.data?.refresh[.panel] == 3)
        #expect(m.views.panel?.root.component == "list")
        #expect(m.views.panel?.root.props["filter"] == .string("local"))
    }

    @Test("query:live makes the list filter by query")
    func queryLive() throws {
        let cmd = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Scratch Notes" })
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.views.panel?.root.props["filter"] == .string("query"))
    }

    @Test("A native provider keeps its Swift panel through the native component")
    func nativeProvider() throws {
        let cmd = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Wi-Fi" })
        #expect(PluginMigration.nativeProvider(of: cmd) == "wifi")
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.views.panel?.root.component == "native")
        #expect(m.views.panel?.root.props["provider"] == .string("wifi"))
        #expect(m.data == nil)
    }

    @Test("A slider command becomes a slider panel and a small widget over a raw value script")
    func sliderCommand() throws {
        let cmd = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Volume" })
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.views.widget?.family == .small)
        #expect(m.views.widget?.root.component == "slider")
        #expect(m.views.panel?.root.component == "slider")
        #expect(m.views.panel?.root.props["action"] == .string("set"))
        #expect(m.actions["set"] != nil)
        if !cmd.valueScript.isEmpty { #expect(m.data?.format == .raw) }
    }

    @Test("A one-shot command becomes a primaryAction; destructive ones carry medium risk")
    func oneShot() throws {
        let trash = try #require(SystemCommandsRegistry.defaults.first { $0.name == "Empty Trash" })
        let m = PluginMigration.manifest(from: trash)
        #expect(m.declaredPresentations.isEmpty)
        #expect(m.primaryAction == "run")
        #expect(m.actions["run"]?.risk == .medium)
        #expect(m.actions["run"]?.type == "applescript")
    }

    @Test("Undo becomes a second action the first one points at")
    func undoPreserved() {
        let cmd = SystemCommand(name: "Hide Desktop", icon: "eye.slash", keywords: ["desktop"],
                                scriptType: "bash", script: "defaults write com.apple.finder CreateDesktop false; killall Finder",
                                successTitle: "Desktop hidden", successMessage: "Icons are gone",
                                undoTitle: "Show Desktop", undoScriptType: "bash",
                                undoScript: "defaults write com.apple.finder CreateDesktop true; killall Finder")
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.actions["run"]?.undo == "undo")
        #expect(m.actions["undo"]?.title == "Show Desktop")
        #expect(m.actions["run"]?.success?.title == "Desktop hidden")
    }

    @Test("URL and file commands become open actions")
    func urlBecomesOpen() {
        let cmd = SystemCommand(name: "Bluetooth Settings", icon: "gear", keywords: ["bt"],
                                scriptType: "url", script: "x-apple.systempreferences:com.apple.BluetoothSettings")
        let m = PluginMigration.manifest(from: cmd)
        #expect(m.actions["run"]?.type == "open")
        #expect(m.actions["run"]?.value == "x-apple.systempreferences:com.apple.BluetoothSettings")
    }

    @Test("A Global Extension becomes a lines list; AI on makes it a window with an agent")
    func routeB() {
        let ext = UserGlobalExtension(name: "Branches", icon: "arrow.triangle.branch", keywords: ["git"],
                                      rowsScript: "git branch --format='%(refname:short) | %(upstream:short)'",
                                      rowActionScript: "git switch \"$CD_ROW_TITLE\"",
                                      aiEnabled: true, aiPrompt: "You help with git branches.")
        let m = PluginMigration.manifest(from: ext)
        #expect(m.id == "branches")
        #expect(m.data?.format == .lines)
        #expect(m.views.panel?.root.component == "list")
        #expect(m.actions["rowAction"]?.script == "git switch \"$CD_ROW_TITLE\"")
        #expect(m.views.window?.root.flattened.contains { $0.component == "ai" } == true)
        #expect(m.agent?.instructions == "You help with git branches.")
        #expect(PluginSchema.validate(m).filter { $0.severity == .error }.isEmpty)
    }
}
