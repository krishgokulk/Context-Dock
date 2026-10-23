// AppDictionaryQueryBuilderTests.swift
// Context-DockTests
//
// The rung's typed-expression guarantee, as tests (P13 #208). The model may name a
// class, properties and a filter — nothing else. Every script here is rendered from a
// learned manifest and checked against what it may and may not contain: unknown
// identifiers refused BEFORE any script exists, values escaping into literals, and no
// free-form AppleScript anywhere in the output.

import Foundation
import Testing
@testable import Context_Dock

@Suite
struct AppDictionaryQueryBuilderTests {

    /// Small learned manifests, from the parser suite's recorded fixtures — the same
    /// text the parser tests read, so both halves of the rung share one reality.
    private static let spotify = AppSdefParser.parse(
        AppScriptingDictionaryParserTests.spotifyExcerpt,
        bundleID: "com.spotify.client", appName: "Spotify", version: "1.2")
    private static let mail = AppSdefParser.parse(
        AppScriptingDictionaryParserTests.mailExcerpt,
        bundleID: "com.apple.mail", appName: "Mail", version: "17")
    private static let empty = AppScriptingDictionary(
        bundleID: "com.none.app", appName: "Nothing", version: "1",
        parsedAt: Date(), classes: [], commands: [])

    // MARK: Reads

    @Test func readNamesTheAppAndTheWhoseClause() throws {
        let script = try AppDictionaryQuery.render(
            DictionaryRequest(
                verb: .query, className: "track", propertiesRaw: "name, artist",
                filterProperty: "artist", filterOperator: "is", filterValue: "A.R. Rahman",
                limit: 10),
            for: Self.spotify)
        #expect(script.contains(#"tell application id "com.spotify.client""#))
        #expect(
            script.contains(#"set _recs to every track whose artist is "A.R. Rahman""#))
        #expect(script.contains(#"set _v0 to (name of _r) as text"#))
        #expect(script.contains(#"set _v1 to (artist of _r) as text"#))
        #expect(script.contains(#"_v0 & "|||" & _v1"#))
        #expect(script.contains("if _collected >= 10 then exit repeat"))
    }

    @Test func readEscapesQuotesAndBackslashes() throws {
        let script = try AppDictionaryQuery.render(
            DictionaryRequest(
                verb: .query, className: "track", propertiesRaw: "name",
                filterProperty: "album", filterValue: #"Say "Hi", \Now"#),
            for: Self.spotify)
        // The one place a model's value reaches the script text — quoted and escaped.
        #expect(script.contains(#"whose album is "Say \"Hi\", \\Now""#))
    }

    @Test func readDefaultsToIDAndNameThenSixAtMost() throws {
        let script = try AppDictionaryQuery.render(
            DictionaryRequest(verb: .query, className: "track"), for: Self.spotify)
        #expect(script.contains(#"(id of _r) as text"#))
        #expect(script.contains(#"(name of _r) as text"#))
        #expect(script.contains("set _v5 to"))
        #expect(!script.contains("set _v6 to"))
    }

    @Test func readCapIsTwentyFiveWhateverTheModelAsked() throws {
        let script = try AppDictionaryQuery.render(
            DictionaryRequest(verb: .query, className: "track", limit: 500), for: Self.spotify)
        #expect(script.contains("if _collected >= 25 then exit repeat"))
    }

    @Test func countAnswersHowMany() throws {
        let script = try AppDictionaryQuery.render(
            DictionaryRequest(
                verb: .count, className: "track", filterProperty: "starred",
                filterValue: "true"),
            for: Self.spotify)
        #expect(script.contains("count of"))
        #expect(script.contains("every track whose starred is true"))
    }

    // MARK: Refusals, before any script exists

    @Test func unknownClassRefused() {
        #expect(
            throws: DictionaryQueryError.unknownClass("playlists", ["application", "track"])
        ) {
            try AppDictionaryQuery.render(
                DictionaryRequest(verb: .query, className: "playlists"), for: Self.spotify)
        }
    }

    @Test func emptilyLearnedAppRefusesEverything() {
        #expect(throws: DictionaryQueryError.unknownClass("track", [])) {
            try AppDictionaryQuery.render(
                DictionaryRequest(verb: .query, className: "track"), for: Self.empty)
        }
    }

    @Test func unknownPropertyRefused() {
        #expect(
            throws: DictionaryQueryError.unknownProperty(
                "isrc", "track", Self.spotify.class(named: "track")!.readablePropertyNames)
        ) {
            try AppDictionaryQuery.render(
                DictionaryRequest(verb: .query, className: "track", propertiesRaw: "isrc"),
                for: Self.spotify)
        }
    }

    @Test func unknownOperatorRefused() {
        #expect(
            throws: DictionaryQueryError.unsupportedOperator(
                "MATCHES", DictionaryRequest.filterOperators)
        ) {
            try AppDictionaryQuery.render(
                DictionaryRequest(
                    verb: .query, className: "track", filterProperty: "name",
                    filterOperator: "MATCHES", filterValue: "x"),
                for: Self.spotify)
        }
    }

    @Test func unknownFilterPropertyRefused() {
        #expect(
            throws: DictionaryQueryError.unknownFilterProperty(
                "tempo", "track", Self.spotify.class(named: "track")!.readablePropertyNames)
        ) {
            try AppDictionaryQuery.render(
                DictionaryRequest(
                    verb: .query, className: "track", filterProperty: "tempo",
                    filterValue: "120"),
                for: Self.spotify)
        }
    }

    // MARK: Writes — they render; the gate card is what asks

    @Test func setNeedsExactlyOnePropertyAndATarget() throws {
        #expect(throws: DictionaryQueryError.writeWithoutTarget("application")) {
            try AppDictionaryQuery.render(
                DictionaryRequest(
                    verb: .set, className: "application", propertiesRaw: "sound volume",
                    value: "50"),
                for: Self.spotify)
        }
        let script = try AppDictionaryQuery.render(
            DictionaryRequest(
                verb: .set, className: "application", propertiesRaw: "sound volume",
                value: "80", filterProperty: "sound volume", filterValue: "50"),
            for: Self.spotify)
        // An integer property arrives bare; the filter's value renders typed as well.
        #expect(
            script.contains(
                #"set sound volume of (every application whose sound volume is 50) to 80"#))
    }

    @Test func setRefusesAReadOnlyProperty() {
        // `id` is access="r" — the app's own constraint, learned, enforced here.
        #expect(
            throws: DictionaryQueryError.unknownProperty(
                "id", "track", Self.spotify.class(named: "track")!.writablePropertyNames)
        ) {
            try AppDictionaryQuery.render(
                DictionaryRequest(
                    verb: .set, className: "track", propertiesRaw: "id", value: "9",
                    filterProperty: "name", filterValue: "x"),
                for: Self.spotify)
        }
    }

    @Test func makeRendersTypedInitialProperties() throws {
        // Only writable properties may seed a make — the fixture track's writable ones
        // are text-typed, so they arrive quoted; `id` and `name` are access="r" and
        // refused (setRefusesAReadOnlyProperty covers that refusal).
        let script = try AppDictionaryQuery.render(
            DictionaryRequest(
                verb: .make, className: "track",
                propertiesRaw: "spotify url=https://open.spotify.com/track/demo"),
            for: Self.spotify)
        #expect(
            script.contains(
                "make new track with properties "
                    + "{spotify url: \"https://open.spotify.com/track/demo\"}"))
    }

    @Test func makeRefusesUnknownKeysRatherThanDroppingThem() {
        // The reminders lesson (undeclared inputs were dropped silently, and the created
        // reminder had no due date): the rung refuses instead of dropping.
        #expect(
            throws: DictionaryQueryError.unknownProperty(
                "tempo", "track", Self.spotify.class(named: "track")!.writablePropertyNames)
        ) {
            try AppDictionaryQuery.render(
                DictionaryRequest(
                    verb: .make, className: "track", propertiesRaw: "tempo=120"),
                for: Self.spotify)
        }
    }

    @Test func setRejectsTwoPropertiesAtOnce() {
        #expect(
            throws: DictionaryQueryError.unknownProperty(
                "set expects exactly one property (got 2)", "track",
                Self.spotify.class(named: "track")!.writablePropertyNames)
        ) {
            try AppDictionaryQuery.render(
                DictionaryRequest(
                    verb: .set, className: "track", propertiesRaw: "name, artist",
                    value: "x", filterProperty: "name", filterValue: "x"),
                for: Self.spotify)
        }
    }

    @Test func deleteNeedsATarget() throws {
        #expect(throws: DictionaryQueryError.writeWithoutTarget("track")) {
            try AppDictionaryQuery.render(
                DictionaryRequest(verb: .delete, className: "track"), for: Self.spotify)
        }
        let script = try AppDictionaryQuery.render(
            DictionaryRequest(
                verb: .delete, className: "track", filterProperty: "starred",
                filterValue: "false"),
            for: Self.spotify)
        #expect(script.contains("delete (every track whose starred is false)"))
    }

    // MARK: Commands — the app's own verbs, gated

    @Test func commandRendersALearnedVerb() throws {
        // "pause" is a Spotify command, not a property write — the route the hand check
        // asked for ("pause the song") without clicking a menu.
        let script = try AppDictionaryQuery.render(
            DictionaryRequest(verb: .command, className: "", propertiesRaw: "pause"),
            for: Self.spotify)
        #expect(script.contains(#"tell application id "com.spotify.client" to pause"#))
    }

    @Test func commandAcceptsATextDirectParameter() throws {
        // `extract name from` takes one text argument and no named ones, so it renders.
        let script = try AppDictionaryQuery.render(
            DictionaryRequest(
                verb: .command, className: "", propertiesRaw: "extract name from",
                value: "Asha <asha@example.com>"),
            for: Self.mail)
        #expect(script.contains(#"to extract name from "Asha <asha@example.com>""#))
    }

    @Test func commandRefusesWhatItCannotRender() throws {
        #expect(
            throws: DictionaryQueryError.unknownCommand("rewind", Self.spotify.commands.map(\.name))
        ) {
            try AppDictionaryQuery.render(
                DictionaryRequest(verb: .command, className: "", propertiesRaw: "rewind"),
                for: Self.spotify)
        }
        // Outbound commands are never rendered, even though the manifest knows them.
        #expect(throws: DictionaryQueryError.outboundCommand("send")) {
            try AppDictionaryQuery.render(
                DictionaryRequest(verb: .command, className: "", propertiesRaw: "send"),
                for: Self.mail)
        }
        // Named parameters are refused rather than guessed ("play track" takes "in context").
        #expect(
            throws: DictionaryQueryError.unsupportedCommand(
                "play track",
                "it takes named parameters (in context), which this rung does not render yet. "
                    + "Use the app itself.")
        ) {
            try AppDictionaryQuery.render(
                DictionaryRequest(verb: .command, className: "", propertiesRaw: "play track"),
                for: Self.spotify)
        }
    }

    // MARK: Literals

    @Test func literalsAreTypedToTheProperty() {
        #expect(AppDictionaryQuery.literal("42", type: "integer") == "42")
        #expect(AppDictionaryQuery.literal("true", type: "boolean") == "true")
        #expect(AppDictionaryQuery.literal("TRUE", type: "boolean") == "true")
        #expect(AppDictionaryQuery.literal("3.5", type: "real") == "3.5")
        // Anything not shapeable falls back to a quoted string, escaped.
        #expect(
            AppDictionaryQuery.literal("don't worry", type: "integer") == "\"don't worry\"")
        #expect(
            AppDictionaryQuery.literal("a \"quote\"", type: "text") == #""a \"quote\"""#)
        #expect(AppDictionaryQuery.literal(#"back\slash"#) == #""back\\slash""#)
    }

    // MARK: Output parsing

    @Test func parseRowsSplitsAndPads() {
        let output =
            "Track One|||Asha Bhosle|||2:59|||\nTrack Two|||R. D. Burman|||3:41|||\n\n"
        let rows = AppDictionaryQuery.parseRows(output, propertyCount: 3)
        #expect(rows.count == 2)
        #expect(rows[0].values == ["Track One", "Asha Bhosle", "2:59"])
        #expect(rows[1].values == ["Track Two", "R. D. Burman", "3:41"])
    }

    @Test func parseRowsSkipsAnAllEmptyRecord() {
        // The shape the read script prints: `_line` is always three values joined by
        // separators, then the trailing separator — an all-empty record is nine pipes —
        // and it is not a record.
        let output = "|||||||||\nTrack One|||Asha Bhosle|||\n"
        let rows = AppDictionaryQuery.parseRows(output, propertyCount: 3)
        #expect(rows.count == 1)
        #expect(rows[0].values == ["Track One", "Asha Bhosle", ""])
    }

    @Test func answerLineCountsAndTitles() {
        let rows = [
            DictionaryQueryRow(values: ["One", "a", ""]),
            DictionaryQueryRow(values: ["Two", "b", ""]),
        ]
        #expect(AppDictionaryQuery.answerLine(for: rows, className: "track").hasPrefix("2 tracks"))
        #expect(
            AppDictionaryQuery.answerLine(for: [], className: "track") == "No tracks matched.")
    }
}
