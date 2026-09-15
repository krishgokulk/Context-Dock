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

    @Test("timeout bounds, and a negative refresh is an error while 0 (never) is not")
    func bounds() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "data": { "type": "bash", "script": "true", "refresh": { "panel": -1 }, "timeout": 61 }, "views": { "panel": { "title": "{{v}}" } } }"#)
        let e = errors(m)
        #expect(e.contains { $0.contains("refresh.panel") })
        #expect(e.contains { $0.contains("timeout") })

        // 0 means "never auto-refresh" (spec §7's Sonos manifest uses it for "panel") and
        // must not be flagged.
        let never = try manifest(#"{ "id": "x", "name": "X", "data": { "type": "bash", "script": "true", "refresh": { "panel": 0 } }, "views": { "panel": { "title": "{{v}}" } } }"#)
        #expect(errors(never).isEmpty)
    }

    @Test("ids are lowercase slugs")
    func idSlug() throws {
        let m = try manifest(#"{ "id": "My Plugin", "name": "X", "views": { "panel": { "title": "a" } } }"#)
        #expect(errors(m).contains { $0.contains("id") && $0.contains("slug") })
    }

    @Test("An unrecognised action type is an error that names it")
    func unknownActionType() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "opne", "script": "true" } }, "primaryAction": "run" }"#)
        #expect(errors(m).contains { $0.contains("action type \"opne\"") })
    }

    @Test("Every recognised action type validates: the script types, the built-ins, and push:<view>")
    func recognisedActionTypesAreClean() throws {
        for type in ["bash", "applescript", "jxa", "scriptFile", "shortcut", "http"] {
            let m = try manifest(#"{ "id": "x", "name": "X", "permissions": ["system:shortcuts", "network:local"], "actions": { "run": { "type": "\#(type)", "script": "true" } }, "primaryAction": "run" }"#)
            #expect(!errors(m).contains { $0.contains("action type") }, Comment(rawValue: type))
        }
        let copy = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "copy", "value": "hi" } }, "primaryAction": "run" }"#)
        #expect(!errors(copy).contains { $0.contains("action type") })
    }

    @Test("A script action with an empty or whitespace-only script is an error")
    func emptyScriptIsAnError() throws {
        let empty = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "bash", "script": "" } }, "primaryAction": "run" }"#)
        #expect(errors(empty).contains { $0.contains("non-empty script") })

        let whitespace = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "bash", "script": "   \n " } }, "primaryAction": "run" }"#)
        #expect(errors(whitespace).contains { $0.contains("non-empty script") })
    }

    @Test("An open action with neither value nor app is an error")
    func openNeedsValueOrApp() throws {
        let bad = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "open" } }, "primaryAction": "run" }"#)
        #expect(errors(bad).contains { $0.contains("open action needs a value or an app") })

        let byValue = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "open", "value": "https://x" } }, "primaryAction": "run" }"#)
        #expect(!errors(byValue).contains { $0.contains("open action needs") })

        let byApp = try manifest(#"{ "id": "x", "name": "X", "actions": { "run": { "type": "open", "app": "Sonos" } }, "primaryAction": "run" }"#)
        #expect(!errors(byApp).contains { $0.contains("open action needs") })
    }

    @Test("A row action that is not declared is an error the schema now sees")
    func rowActionMustBeDeclared() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}", "action": "nope" } } } } }"#)
        #expect(errors(m).contains { $0.contains("action \"nope\" is not declared") })
    }

    @Test("An action list inside a row is checked item by item")
    func rowActionListMustBeDeclared() throws {
        // A row's secondary actions are an ARRAY of objects, not a string prop, so the
        // action-prop rule above never saw them — #27 made the schema reach the row node
        // itself, not inside the arrays it carries. PluginMigration emits exactly this shape,
        // so an undeclared name here reaches a user as a row that does nothing.
        let m = try manifest(#"{ "id": "x", "name": "X", "actions": { "play": { "type": "bash", "script": "true" } }, "views": { "panel": { "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}", "actions": [ { "title": "Play", "action": "play" }, { "title": "Beam", "action": "teleport" } ] } } } } }"#)
        let found = errors(m).filter { $0.contains("is not declared") }
        #expect(found.count == 1)
        #expect(found[0].contains("teleport"))
    }

    @Test("An action list whose names are all declared is clean")
    func rowActionListThatIsDeclaredIsClean() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "actions": { "play": { "type": "bash", "script": "true" } }, "views": { "panel": { "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}", "actions": [ { "title": "Play", "action": "play" } ] } } } } }"#)
        #expect(errors(m).isEmpty)
    }

    @Test("An unknown component inside a row template is an error")
    func unknownComponentInsideARow() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "list": { "items": "{{lines}}", "row": { "hologram": {} } } } } }"#)
        #expect(errors(m).contains { $0.contains("unknown component \"hologram\"") })
    }
}
