// AppDictionaryQueryBuilderTests.swift
// Context-DockTests
//
// The rung's typed-request guarantee, as tests (P13 #208). The model may name a class,
// properties and a filter — nothing else. Each test validates the plan against a learned
// manifest, then inspects the Apple Event descriptor that plan would send: the event
// class and id, the object specifier's want/form/seld/from, and the typed operand.
//
// No test sends an event. The test host swizzles `sendEvent` on purpose; the descriptor
// structure is the offline proof that no script text and no free-form identifier can reach
// the app.

import AppKit
import Carbon
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

    // MARK: Reads — plans

    @Test func readPlanTargetsTheWhoseCollection() throws {
        let plan = try AppDictionaryQuery.plan(
            DictionaryRequest(
                verb: .query, className: "track", propertiesRaw: "name, artist",
                filterProperty: "artist", filterOperator: "is", filterValue: "A.R. Rahman",
                limit: 10),
            for: Self.spotify)
        guard case .read(let target, let properties, let limit) = plan else {
            Issue.record("expected a read plan")
            return
        }
        #expect(limit == 10)
        #expect(properties.map(\.name) == ["name", "artist"])
        guard case .collection(let className, let filter) = target else {
            Issue.record("expected a collection target")
            return
        }
        #expect(className.name == "track")
        #expect(className.code == "spTr")
        #expect(filter?.property.name == "artist")
        #expect(filter?.comparison == .isEqual)
        #expect(filter?.value == "A.R. Rahman")
    }

    @Test func readDefaultsToIdentityThenSixAtMost() throws {
        let plan = try AppDictionaryQuery.plan(
            DictionaryRequest(verb: .query, className: "track"), for: Self.spotify)
        guard case .read(_, let properties, _) = plan else {
            Issue.record("expected a read plan")
            return
        }
        #expect(properties.map(\.name).prefix(2) == ["id", "name"])
        #expect(properties.count <= 6)
        #expect(properties.allSatisfy { $0.code != nil })
    }

    @Test func readCapIsTwentyFiveWhateverTheModelAsked() throws {
        let plan = try AppDictionaryQuery.plan(
            DictionaryRequest(verb: .query, className: "track", limit: 500),
            for: Self.spotify)
        guard case .read(_, _, let limit) = plan else {
            Issue.record("expected a read plan")
            return
        }
        #expect(limit == 25)
    }

    @Test func rootReadsOneItemTheAppNames() throws {
        let plan = try AppDictionaryQuery.plan(
            DictionaryRequest(
                verb: .query, className: "track", propertiesRaw: "name, artist",
                root: "current track"),
            for: Self.spotify)
        guard case .read(let target, let properties, let limit) = plan else {
            Issue.record("expected a read plan")
            return
        }
        guard case .singleItem(let className, let root) = target else {
            Issue.record("expected a single-item target")
            return
        }
        #expect(className.name == "track")
        #expect(root.name == "current track")
        #expect(root.code == "pTrk")
        #expect(limit == 1)
        #expect(properties.map(\.name) == ["name", "artist"])
    }

    @Test func applicationReadUsesTheSingleton() throws {
        let plan = try AppDictionaryQuery.plan(
            DictionaryRequest(
                verb: .query, className: "application",
                propertiesRaw: "player state, sound volume"),
            for: Self.spotify)
        guard case .read(let target, let properties, let limit) = plan else {
            Issue.record("expected a read plan")
            return
        }
        guard case .application = target else {
            Issue.record("expected the application singleton")
            return
        }
        #expect(properties.map(\.name) == ["player state", "sound volume"])
        #expect(limit == 1)
    }

    @Test func countPlansACountOfTheMatchingCollection() throws {
        let plan = try AppDictionaryQuery.plan(
            DictionaryRequest(
                verb: .count, className: "track", filterProperty: "starred",
                filterOperator: "is", filterValue: "true"),
            for: Self.spotify)
        guard case .count(let target) = plan else {
            Issue.record("expected a count plan")
            return
        }
        guard case .collection(_, let filter) = target else {
            Issue.record("expected a collection target")
            return
        }
        #expect(filter?.property.name == "starred")
        #expect(filter?.value == "true")
    }

    // MARK: Writes — plans

    @Test func setPlansOnePropertyOnAFilteredCollection() throws {
        let plan = try AppDictionaryQuery.plan(
            DictionaryRequest(
                verb: .set, className: "track", propertiesRaw: "spotify url",
                value: "spotify:track:1", filterProperty: "name", filterValue: "One"),
            for: Self.spotify)
        guard case .set(let target, let property, let value) = plan else {
            Issue.record("expected a set plan")
            return
        }
        #expect(property.name == "spotify url")
        #expect(value == "spotify:track:1")
        guard case .collection(_, let filter) = target else {
            Issue.record("expected a collection target")
            return
        }
        #expect(filter?.value == "One")
    }

    @Test func makePlansTheClassAndItsAssignments() throws {
        let plan = try AppDictionaryQuery.plan(
            DictionaryRequest(
                verb: .make, className: "track",
                propertiesRaw: "spotify url=spotify:track:1"),
            for: Self.spotify)
        guard case .make(let className, let assignments) = plan else {
            Issue.record("expected a make plan")
            return
        }
        #expect(className.name == "track")
        #expect(className.code == "spTr")
        #expect(assignments.map(\.property.name) == ["spotify url"])
        #expect(assignments.first?.value == "spotify:track:1")
    }

    @Test func deletePlansTheFilteredCollection() throws {
        let plan = try AppDictionaryQuery.plan(
            DictionaryRequest(
                verb: .delete, className: "track", filterProperty: "name",
                filterValue: "One"),
            for: Self.spotify)
        guard case .delete(let target) = plan else {
            Issue.record("expected a delete plan")
            return
        }
        guard case .collection(_, let filter) = target else {
            Issue.record("expected a collection target")
            return
        }
        #expect(filter?.property.name == "name")
    }

    // MARK: Refusals, before any event exists

    @Test func unknownClassRefused() {
        #expect(
            throws: DictionaryQueryError.unknownClass("playlists", ["application", "track"])
        ) {
            try AppDictionaryQuery.plan(
                DictionaryRequest(verb: .query, className: "playlists"), for: Self.spotify)
        }
    }

    @Test func emptilyLearnedAppRefusesEverything() {
        #expect(throws: DictionaryQueryError.unknownClass("track", [])) {
            try AppDictionaryQuery.plan(
                DictionaryRequest(verb: .query, className: "track"), for: Self.empty)
        }
    }

    @Test func unknownPropertyRefused() {
        #expect(
            throws: DictionaryQueryError.unknownProperty(
                "isrc", "track", Self.spotify.class(named: "track")!.readablePropertyNames)
        ) {
            try AppDictionaryQuery.plan(
                DictionaryRequest(verb: .query, className: "track", propertiesRaw: "isrc"),
                for: Self.spotify)
        }
    }

    @Test func unknownOperatorRefused() {
        #expect(
            throws: DictionaryQueryError.unsupportedOperator(
                "MATCHES", DictionaryRequest.filterOperators)
        ) {
            try AppDictionaryQuery.plan(
                DictionaryRequest(
                    verb: .query, className: "track", filterProperty: "name",
                    filterOperator: "MATCHES", filterValue: "x"),
                for: Self.spotify)
        }
    }

    @Test func unknownRootRefused() {
        #expect(
            throws: DictionaryQueryError.unknownRoot(
                "the one playing", "track", ["current track"])
        ) {
            try AppDictionaryQuery.plan(
                DictionaryRequest(
                    verb: .query, className: "track", root: "the one playing"),
                for: Self.spotify)
        }
    }

    @Test func rootIsOnlyForReads() {
        #expect(throws: DictionaryQueryError.rootOnlyForReads("set")) {
            try AppDictionaryQuery.plan(
                DictionaryRequest(
                    verb: .set, className: "track", propertiesRaw: "spotify url",
                    value: "x", filterProperty: "name", filterValue: "One",
                    root: "current track"),
                for: Self.spotify)
        }
    }

    @Test func writeWithoutAFilterRefused() {
        #expect(throws: DictionaryQueryError.writeWithoutTarget("track")) {
            try AppDictionaryQuery.plan(
                DictionaryRequest(
                    verb: .delete, className: "track"),
                for: Self.spotify)
        }
        #expect(throws: DictionaryQueryError.writeWithoutTarget("track")) {
            try AppDictionaryQuery.plan(
                DictionaryRequest(
                    verb: .set, className: "track", propertiesRaw: "spotify url",
                    value: "x"),
                for: Self.spotify)
        }
    }

    @Test func readOnlyPropertyCannotBeSet() {
        #expect(
            throws: DictionaryQueryError.unknownProperty(
                "artist", "track", Self.spotify.class(named: "track")!.writablePropertyNames)
        ) {
            try AppDictionaryQuery.plan(
                DictionaryRequest(
                    verb: .set, className: "track", propertiesRaw: "artist", value: "x",
                    filterProperty: "name", filterValue: "One"),
                for: Self.spotify)
        }
    }

    @Test func aTermWithoutAFourCharacterCodeIsRefused() {
        // Music's recorded excerpt declares `album` with a type but no code (and `finish`
        // likewise): a typed Apple Event cannot address those, so the plan says so instead
        // of falling back to a made-up code.
        let music = AppSdefParser.parse(
            AppScriptingDictionaryParserTests.musicExcerpt,
            bundleID: "com.apple.Music", appName: "Music", version: "1")
        #expect(throws: DictionaryQueryError.self) {
            try AppDictionaryQuery.plan(
                DictionaryRequest(
                    verb: .query, className: "track", propertiesRaw: "album"),
                for: music)
        }
    }

    // MARK: Commands — plans

    @Test func commandPlanAcceptsANoArgumentCommand() throws {
        let command = try #require(Self.spotify.command(named: "pause"))
        let plan = try AppDictionaryQuery.commandPlan(command, value: "")
        guard case .command(let planned, let value) = plan else {
            Issue.record("expected a command plan")
            return
        }
        #expect(planned.name == "pause")
        #expect(value.isEmpty)
    }

    @Test func commandPlanRefusesNamedParameters() throws {
        let command = try #require(Self.spotify.command(named: "play track"))
        #expect(throws: DictionaryQueryError.self) {
            try AppDictionaryQuery.commandPlan(command, value: "spotify:track:1")
        }
    }

    @Test func commandPlanRefusesANonTextDirectParameter() throws {
        let command = try #require(Self.mail.command(named: "send"))
        #expect(throws: DictionaryQueryError.self) {
            try AppDictionaryQuery.commandPlan(command, value: "x")
        }
    }

    @Test func commandPlanRefusesAnArgumentWhenTheCommandTakesNone() throws {
        let command = try #require(Self.spotify.command(named: "pause"))
        #expect(throws: DictionaryQueryError.self) {
            try AppDictionaryQuery.commandPlan(command, value: "please")
        }
    }

    // MARK: Descriptor structure

    private static func specifier(_ plan: DictionaryPlan) throws -> NSAppleEventDescriptor {
        guard case .read(let target, _, _) = plan else {
            throw DictionaryQueryError.unknownClass("", [])
        }
        return try AppDictionaryEvents(dictionary: Self.spotify).specifier(for: target)
    }

    /// The object-specifier record is keyed, not positional: the four items are `want`,
    /// `from`, `form` and `seld`, in whatever order `CreateObjSpecifier` lays them out.
    private func item(
        _ keyword: AEKeyword, in descriptor: NSAppleEventDescriptor
    ) throws -> NSAppleEventDescriptor {
        guard descriptor.numberOfItems > 0 else {
            throw DictionaryQueryError.unknownClass("", [])
        }
        for index in 1...descriptor.numberOfItems
        where descriptor.keywordForDescriptor(at: index) == keyword {
            return try #require(descriptor.atIndex(index))
        }
        throw DictionaryQueryError.unknownClass("", [])
    }

    /// A comparison descriptor's three items, through Carbon: operator, left operand,
    /// right operand. `NSAppleEventDescriptor.data` cannot re-open a composite, so the
    /// `AEDesc` itself is asked.
    private func comparisonItems(
        _ specifier: NSAppleEventDescriptor
    ) throws -> [NSAppleEventDescriptor] {
        let seld = try item(AEKeyword(keyAEKeyData), in: specifier)
        #expect(seld.descriptorType == typeCompDescriptor)
        var comparison = try #require(seld.aeDesc?.pointee)
        var count = 0
        let counted = AECountItems(&comparison, &count)
        #expect(counted == noErr)
        #expect(count == 3)
        guard count == 3 else { return [] }
        return try (1...count).map { index in
            var item = AEDesc()
            var keyword: AEKeyword = 0
            let status = AEGetNthDesc(
                &comparison, index, DescType(typeWildCard), &keyword, &item)
            #expect(status == noErr)
            guard status == noErr else {
                throw DictionaryQueryError.unknownClass("", [])
            }
            return NSAppleEventDescriptor(aeDescNoCopy: &item)
        }
    }

    @Test func readEventIsATypedCoreGetData() throws {
        let events = AppDictionaryEvents(dictionary: Self.spotify)
        let target = try events.specifier(
            for: .collection(
                className: Self.spotify.class(named: "track")!,
                filter: nil))
        let event = try events.readEvent(specifier: target)
        #expect(event.eventClass == OSType(kAECoreSuite))
        #expect(event.eventID == OSType(kAEGetData))
        let direct = try #require(
            event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        #expect(direct.descriptorType == typeObjectSpecifier)
    }

    @Test func collectionSpecifierIsEveryTrackFromTheApplication() throws {
        let specifier = try Self.specifier(
            try AppDictionaryQuery.plan(
                DictionaryRequest(verb: .query, className: "track"),
                for: Self.spotify))
        #expect(specifier.descriptorType == typeObjectSpecifier)
        #expect(
            try item(AEKeyword(keyAEDesiredClass), in: specifier).typeCodeValue
                == fourCharCode("spTr"))
        #expect(
            try item(AEKeyword(keyAEKeyForm), in: specifier).enumCodeValue
                == OSType(formAbsolutePosition))
        let keyData = try item(AEKeyword(keyAEKeyData), in: specifier)
        #expect(keyData.descriptorType == typeAbsoluteOrdinal)
        #expect(keyData.enumCodeValue == OSType(0x616C6C20))  // 'all '
        #expect(
            try item(AEKeyword(keyAEContainer), in: specifier).descriptorType
                == typeNull)
    }

    @Test func filterSpecifierIsATestWhoseComparisonIsTyped() throws {
        let specifier = try Self.specifier(
            try AppDictionaryQuery.plan(
                DictionaryRequest(
                    verb: .query, className: "track", filterProperty: "artist",
                    filterOperator: "is", filterValue: "A.R. Rahman"),
                for: Self.spotify))
        #expect(
            try item(AEKeyword(keyAEKeyForm), in: specifier).enumCodeValue
                == OSType(formTest))
        let parts = try comparisonItems(specifier)
        guard parts.count == 3 else { return }
        // Operator first, then the two typed operands (Apple's comparison descriptor).
        #expect(parts[0].enumCodeValue == OSType(kAEEquals))
        #expect(parts[1].descriptorType == typeObjectSpecifier)
        #expect(parts[2].stringValue == "A.R. Rahman")
        #expect(parts[2].descriptorType == typeUnicodeText)
    }

    @Test func isNotIsALogicalNotOfEquality() throws {
        let specifier = try Self.specifier(
            try AppDictionaryQuery.plan(
                DictionaryRequest(
                    verb: .query, className: "track", filterProperty: "artist",
                    filterOperator: "is not", filterValue: "A.R. Rahman"),
                for: Self.spotify))
        let logical = try item(AEKeyword(keyAEKeyData), in: specifier)
        #expect(logical.descriptorType == typeLogicalDescriptor)
        var record = try #require(logical.aeDesc?.pointee)
        var op = AEDesc()
        let opStatus = AEGetParamDesc(
            &record, AEKeyword(keyAELogicalOperator), DescType(typeWildCard), &op)
        #expect(opStatus == noErr)
        #expect(NSAppleEventDescriptor(aeDescNoCopy: &op).enumCodeValue == OSType(kAENOT))
        var terms = AEDesc()
        let termsStatus = AEGetParamDesc(
            &record, AEKeyword(keyAELogicalTerms), DescType(typeAEList), &terms)
        #expect(termsStatus == noErr)
        var count = 0
        _ = AECountItems(&terms, &count)
        #expect(count == 1)
    }

    @Test func countEventIsCoreCountWithTheCollectionAsItsObject() throws {
        let events = AppDictionaryEvents(dictionary: Self.spotify)
        let specifier = try events.specifier(
            for: .collection(
                className: Self.spotify.class(named: "track")!,
                filter: nil))
        let event = try events.countEvent(specifier)
        #expect(event.eventClass == OSType(kAECoreSuite))
        #expect(event.eventID == OSType(kAECountElements))
        #expect(
            event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
                .descriptorType == typeObjectSpecifier)
    }

    @Test func setEventCarriesTheTypedValueUnderKeyData() throws {
        let events = AppDictionaryEvents(dictionary: Self.spotify)
        let track = try #require(Self.spotify.class(named: "track"))
        let item = try events.specifier(for: .collection(className: track, filter: nil))
        let property = try #require(track.property(named: "spotify url"))
        let event = try events.setEvent(
            events.propertySpecifier(property, of: item),
            value: "spotify:track:1", type: property.type)
        #expect(event.eventClass == OSType(kAECoreSuite))
        #expect(event.eventID == OSType(kAESetData))
        let data = try #require(
            event.paramDescriptor(forKeyword: AEKeyword(keyAEData)))
        #expect(data.descriptorType == typeUnicodeText)
        #expect(data.stringValue == "spotify:track:1")
    }

    @Test func integerFilterValueIsSentAsAnInteger() throws {
        let specifier = try Self.specifier(
            try AppDictionaryQuery.plan(
                DictionaryRequest(
                    verb: .query, className: "track", filterProperty: "duration",
                    filterOperator: "is greater than", filterValue: "100"),
                for: Self.spotify))
        let parts = try comparisonItems(specifier)
        guard parts.count == 3 else { return }
        #expect(parts[0].enumCodeValue == OSType(kAEGreaterThan))
        #expect(parts[2].descriptorType == typeSInt32)
        #expect(parts[2].int32Value == 100)
    }

    @Test func makeEventIsCoreCreateElementWithTypedProperties() throws {
        let events = AppDictionaryEvents(dictionary: Self.spotify)
        let track = try #require(Self.spotify.class(named: "track"))
        let property = try #require(track.property(named: "spotify url"))
        let event = try events.makeEvent(
            className: track,
            assignments: [
                DictionaryAssignment(property: property, value: "spotify:track:1")
            ])
        #expect(event.eventClass == OSType(kAECoreSuite))
        #expect(event.eventID == OSType(kAECreateElement))
        #expect(
            event.paramDescriptor(forKeyword: AEKeyword(keyAEObjectClass))?
                .typeCodeValue == fourCharCode("spTr"))
        let properties = try #require(
            event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)))
        #expect(properties.descriptorType == typeAERecord)
        #expect(properties.numberOfItems == 1)
    }

    @Test func deleteEventIsCoreDelete() throws {
        let events = AppDictionaryEvents(dictionary: Self.spotify)
        let track = try #require(Self.spotify.class(named: "track"))
        let item = try events.specifier(for: .collection(className: track, filter: nil))
        let event = try events.deleteEvent(item)
        #expect(event.eventClass == OSType(kAECoreSuite))
        #expect(event.eventID == OSType(kAEDelete))
    }

    @Test func commandEventIsTheAppOwnClassAndCode() throws {
        let events = AppDictionaryEvents(dictionary: Self.spotify)
        let command = try #require(Self.spotify.command(named: "pause"))
        let event = try events.commandEvent(command, value: "")
        #expect(event.eventClass == fourCharCode("spfy"))
        #expect(event.eventID == fourCharCode("Paus"))
        #expect(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) == nil)
    }

    @Test func commandWithATextArgumentCarriesItAsTheDirectObject() throws {
        let events = AppDictionaryEvents(dictionary: Self.mail)
        let command = try #require(Self.mail.command(named: "extract name from"))
        let event = try events.commandEvent(command, value: "Ada Lovelace <ada@example.com>")
        #expect(event.eventClass == fourCharCode("emal"))
        #expect(event.eventID == fourCharCode("eafn"))
        #expect(
            event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
                .stringValue == "Ada Lovelace <ada@example.com>")
    }

    // MARK: Output shape

    @Test func rowFieldsPutTheFirstThreeValuesToWork() {
        let row = DictionaryQueryRow(values: ["Blue in Green", "Miles Davis", "Kind of Blue", ""])
        let fields = AppDictionaryQuery.rowFields(row)
        #expect(fields.title == "Blue in Green")
        #expect(fields.subtitle == "Miles Davis")
        #expect(fields.detail == "Kind of Blue")
    }

    @Test func answerLineIsNumberOfRowsThenAList() {
        let rows = [
            DictionaryQueryRow(values: ["One", "Artist"]),
            DictionaryQueryRow(values: ["Two", "Artist"]),
        ]
        let text = AppDictionaryQuery.answerLine(for: rows, className: "track")
        #expect(text.hasPrefix("2 tracks so far:"))
        #expect(text.contains("1. One — Artist"))
        #expect(text.contains("2. Two — Artist"))
    }

    @Test func emptyAnswerSaysSo() {
        #expect(
            AppDictionaryQuery.answerLine(for: [], className: "track")
                == "No tracks matched.")
    }
}


