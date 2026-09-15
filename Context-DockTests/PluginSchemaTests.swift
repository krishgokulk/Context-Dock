// Context-DockTests/PluginSchemaTests.swift
// A manifest that decodes is not a manifest that works. These pin every rule the schema
// enforces, one test each, so a rule cannot be dropped without a test naming it.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin schema")
@MainActor
struct PluginSchemaTests {

    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private func errors(_ m: PluginManifest) -> [String] {
        PluginSchema.validate(m).filter { $0.severity == .error }.map(\.message)
    }

    private func warnings(_ m: PluginManifest) -> [String] {
        PluginSchema.validate(m).filter { $0.severity == .warning }.map(\.message)
    }

    @Test("The Sonos manifest is clean")
    func sonosIsClean() throws {
        let m = try manifest(PluginManifestTests.sonos)
        #expect(PluginSchema.validate(m).filter { $0.severity == .error }.isEmpty)
    }

    @Test("An unknown component is an error that names it")
    func unknownComponent() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "hologram": {} } } }"#)
        #expect(errors(m).contains { $0.contains("unknown component \"hologram\"") })
    }

    @Test("A leaf may not carry children")
    func leafWithChildren() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "title": [ { "divider": {} } ] } } }"#)
        #expect(errors(m).contains { $0.contains("\"title\" does not take children") })
    }

    @Test("A binding the sample does not have is a warning, not an error")
    func bindingMissingFromSample() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "sample": { "a": 1 }, "views": { "panel": { "title": "{{b}}" } } }"#)
        #expect(errors(m).isEmpty)
        #expect(warnings(m).contains { $0.contains("\"b\" is not in sample") })
    }

    @Test("item.*, lines and value bindings never warn")
    func implicitBindings() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}" } } } } }"#)
        #expect(warnings(m).isEmpty)
    }

    @Test("A view naming an action that does not exist is an error")
    func undeclaredActionInView() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "widget": { "family": "small", "root": { "toggle": { "action": "flip" } } } } }"#)
        #expect(errors(m).contains { $0.contains("action \"flip\" is not declared") })
    }

    @Test("agent.tools must be declared actions")
    func toolsMustBeActions() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "actions": { "a": { "type": "bash", "script": "true" } }, "agent": { "tools": ["a", "b"] } }"#)
        #expect(errors(m).contains { $0.contains("tool \"b\" is not a declared action") })
    }

    @Test("A plugin with nothing to show or run is an error")
    func nothingToShowOrRun() throws {
        let m = try manifest(#"{ "id": "x", "name": "X" }"#)
        #expect(errors(m).contains { $0.contains("nothing to show or run") })
    }

    @Test("primaryAction alone is enough, and must exist")
    func primaryAction() throws {
        let ok = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "bash", "script": "true" } }, "primaryAction": "run" }"#)
        #expect(errors(ok).isEmpty)
        let bad = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "bash", "script": "true" } }, "primaryAction": "go" }"#)
        #expect(errors(bad).contains { $0.contains("primaryAction \"go\" is not declared") })
    }

    @Test("http data needs a network permission and a URL")
    func httpNeedsPermission() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "data": { "type": "http", "script": "https://api.example.com/x" }, "views": { "panel": { "title": "{{v}}" } } }"#)
        #expect(errors(m).contains { $0.contains("network:api.example.com") })
        let ok = try manifest(#"{ "id": "x", "name": "X", "permissions": ["network:api.example.com"], "data": { "type": "http", "script": "https://api.example.com/x" }, "views": { "panel": { "title": "{{v}}" } } }"#)
        #expect(errors(ok).isEmpty)
        let notURL = try manifest(#"{ "id": "x", "name": "X", "permissions": ["network:local"], "data": { "type": "http", "script": "curl x" }, "views": { "panel": { "title": "{{v}}" } } }"#)
        #expect(errors(notURL).contains { $0.contains("is not a URL") })
    }

    @Test("push targets a declared presentation")
    func pushTarget() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "actions": { "more": { "type": "push:window" } }, "views": { "panel": { "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}", "action": "more" } } } } }"#)
        #expect(errors(m).contains { $0.contains("push:window") && $0.contains("not declared") })
    }

    @Test("A shortcut action without the shortcuts permission is a warning, not an error")
    func shortcutNeedsPermission() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "shortcut", "script": "My Shortcut" } }, "primaryAction": "run" }"#)
        #expect(errors(m).isEmpty)
        #expect(warnings(m).contains { $0.contains("system:shortcuts") })

        let ok = try manifest(#"{ "id": "x", "name": "X", "permissions": ["system:shortcuts"], "actions": { "run": { "type": "shortcut", "script": "My Shortcut" } }, "primaryAction": "run" }"#)
        #expect(errors(ok).isEmpty)
        #expect(warnings(ok).isEmpty)
    }

    @Test("An action's undo must name a declared action")
    func undoMustBeDeclared() throws {
        let bad = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "bash", "script": "true", "undo": "revert" } }, "primaryAction": "run" }"#)
        #expect(errors(bad).contains { $0.contains("undo \"revert\" is not a declared action") })

        let ok = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "bash", "script": "true", "undo": "reverse" }, "reverse": { "type": "bash", "script": "false" } }, "primaryAction": "run" }"#)
        #expect(errors(ok).isEmpty)
    }

    @Test("inputs come from the fixed set, optional with a question mark")
    func inputsSet() throws {
        let ok = try manifest(#"{ "id": "x", "name": "X", "inputs": ["query", "selection.text?", "clipboard.history"], "views": { "panel": { "title": "a" } } }"#)
        #expect(errors(ok).isEmpty)
        let bad = try manifest(#"{ "id": "x", "name": "X", "inputs": ["mood"], "views": { "panel": { "title": "a" } } }"#)
        #expect(errors(bad).contains { $0.contains("input \"mood\"") })
    }

    @Test("refresh and timeout bounds")
    func bounds() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "data": { "type": "bash", "script": "true", "refresh": { "panel": 0 }, "timeout": 61 }, "views": { "panel": { "title": "{{v}}" } } }"#)
        let e = errors(m)
        #expect(e.contains { $0.contains("refresh.panel") })
        #expect(e.contains { $0.contains("timeout") })
    }

    @Test("ids are lowercase slugs")
    func idSlug() throws {
        let m = try manifest(#"{ "id": "My Plugin", "name": "X", "views": { "panel": { "title": "a" } } }"#)
        #expect(errors(m).contains { $0.contains("id") && $0.contains("slug") })
    }
}
