// Context-DockTests/PluginEnvironmentTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginEnvironmentTests {
    @Test func theHostAndWidthAreAlwaysPresent() {
        let env = PluginEnvironment.build(
            inputs: PluginInputs(), host: .panel, widthClass: .compact)
        #expect(env["CD_HOST"] == "panel")
        #expect(env["CD_WIDTH"] == "compact")
    }

    @Test func anAbsentInputSetsNoVariableAtAll() {
        // Not "" — a script tests `[ -n "$CD_TEXT" ]`, and an empty string that exists is a
        // different answer from a variable that does not.
        let env = PluginEnvironment.build(inputs: PluginInputs(), host: .panel, widthClass: .regular)
        #expect(env["CD_TEXT"] == nil)
        #expect(env["CD_QUERY"] == nil)
    }

    @Test func theNamesTodaysScriptsReadAreUnchanged() {
        var inputs = PluginInputs()
        inputs.query = "ports"
        inputs.selectionText = "hello"
        inputs.selectionURL = "https://example.com"
        inputs.frontmostApp = "Safari"
        inputs.rowID = "t1"
        inputs.rowTitle = "Jungle"
        inputs.rowRaw = "Jungle | Casio"
        let env = PluginEnvironment.build(inputs: inputs, host: .panel, widthClass: .regular)
        #expect(env["CD_QUERY"] == "ports")
        #expect(env["CD_TEXT"] == "hello")
        #expect(env["CD_URL"] == "https://example.com")
        #expect(env["CD_APP"] == "Safari")
        #expect(env["CD_ROW_ID"] == "t1")
        #expect(env["CD_ROW_TITLE"] == "Jungle")
        #expect(env["CD_ROW"] == "Jungle | Casio")
    }

    @Test func fileListsAreNewlineSeparated() {
        var inputs = PluginInputs()
        inputs.selectionFiles = ["/tmp/a.txt", "/tmp/b.txt"]
        inputs.clipboardFiles = ["/tmp/c.txt"]
        let env = PluginEnvironment.build(inputs: inputs, host: .window, widthClass: .regular)
        #expect(env["CD_FILES"] == "/tmp/a.txt\n/tmp/b.txt")
        #expect(env["CD_CLIP_FILES"] == "/tmp/c.txt")
    }

    @Test func aControlValueBecomesAStringWhateverItsType() {
        var slider = PluginInputs()
        slider.value = .number(35)
        #expect(PluginEnvironment.build(inputs: slider, host: .panel, widthClass: .regular)["CD_VALUE"] == "35")
        var toggle = PluginInputs()
        toggle.value = .bool(true)
        #expect(PluginEnvironment.build(inputs: toggle, host: .panel, widthClass: .regular)["CD_VALUE"] == "true")
        var field = PluginInputs()
        field.value = .string("kitchen")
        #expect(PluginEnvironment.build(inputs: field, host: .panel, widthClass: .regular)["CD_VALUE"] == "kitchen")
    }

    @Test func aWholeNumberValueHasNoDecimalPoint() {
        // `CD_VALUE=35.0` breaks `[ "$CD_VALUE" -gt 30 ]` in every shell script that does arithmetic.
        var inputs = PluginInputs()
        inputs.value = .number(35)
        #expect(PluginEnvironment.build(inputs: inputs, host: .panel, widthClass: .regular)["CD_VALUE"] == "35")
    }

    @Test func theProcessEnvironmentIsNotInHere() {
        // build() returns only the plugin's own variables; merging with the process
        // environment is the runner's job, so this stays a pure function of its inputs.
        let env = PluginEnvironment.build(inputs: PluginInputs(), host: .icon, widthClass: .compact)
        #expect(env["PATH"] == nil)
        #expect(env.keys.allSatisfy { $0.hasPrefix("CD_") })
    }
}
