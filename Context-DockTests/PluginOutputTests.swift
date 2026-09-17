// Context-DockTests/PluginOutputTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginOutputTests {
    private func value(_ text: String, _ format: PluginDataFormat) throws -> PluginValue {
        switch PluginOutput.decode(text, format: format) {
        case .success(let value): return value
        case .failure(let diagnostic): throw PluginOutputTestError(message: diagnostic.message)
        }
    }

    struct PluginOutputTestError: Error { let message: String }

    @Test func jsonBecomesItsObject() throws {
        let out = try value(#"{ "room": "Kitchen", "playing": true }"#, .json)
        #expect(out.objectValue?["room"] == .string("Kitchen"))
        #expect(out.objectValue?["playing"] == .bool(true))
    }

    @Test func brokenJsonIsADiagnosticNamingTheFormat() {
        switch PluginOutput.decode("{ not json", format: .json) {
        case .success: Issue.record("broken JSON decoded")
        case .failure(let diagnostic):
            #expect(diagnostic.severity == .error)
            #expect(diagnostic.message.contains("JSON"))
        }
    }

    @Test func linesBecomeItemsWithTitleAndSubtitle() throws {
        // What every Global Extension prints today: "Title | subtitle", one per line.
        let out = try value("main | origin/main\nfix-91 | \n\n", .lines)
        let items = try #require(out.objectValue?["lines"]?.arrayValue)
        #expect(items.count == 2)
        #expect(items[0].objectValue?["title"] == .string("main"))
        #expect(items[0].objectValue?["subtitle"] == .string("origin/main"))
        #expect(items[1].objectValue?["title"] == .string("fix-91"))
        #expect(items[1].objectValue?["subtitle"] == .string(""))
    }

    @Test func aLineKeepsItsWholeSelfForCD_ROW() throws {
        // The row action is handed `CD_ROW` verbatim, so the raw line has to survive decoding.
        let out = try value("main | origin/main", .lines)
        let items = try #require(out.objectValue?["lines"]?.arrayValue)
        #expect(items[0].objectValue?["raw"] == .string("main | origin/main"))
    }

    @Test func jsonlBecomesOneItemPerLineAndSkipsBlanks() throws {
        let out = try value("{\"title\":\"a\"}\n\n{\"title\":\"b\"}\n", .jsonl)
        let items = try #require(out.objectValue?["lines"]?.arrayValue)
        #expect(items.map { $0.objectValue?["title"] } == [.string("a"), .string("b")])
    }

    @Test func oneBadLineInJsonlDoesNotLoseTheGoodOnes() {
        // A long-running list must not go blank because one row is malformed.
        switch PluginOutput.decode("{\"title\":\"a\"}\nnot json\n", format: .jsonl) {
        case .failure(let diagnostic): Issue.record("lost the whole list: \(diagnostic.message)")
        case .success(let value):
            #expect(value.objectValue?["lines"]?.arrayValue?.count == 1)
        }
    }

    @Test func rawIsTheTrimmedTextUnderValue() throws {
        let out = try value("  42\n", .raw)
        #expect(out.objectValue?["value"] == .string("42"))
    }

    @Test func emptyOutputIsEmptyDataNotAFailure() throws {
        // A list with nothing in it is the empty state, which Phase 2 already draws. It is
        // not an error, and must not be reported as one.
        #expect(try value("", .lines).objectValue?["lines"]?.arrayValue?.isEmpty == true)
        #expect(try value("", .jsonl).objectValue?["lines"]?.arrayValue?.isEmpty == true)
        #expect(try value("", .raw).objectValue?["value"] == .string(""))
    }
}
