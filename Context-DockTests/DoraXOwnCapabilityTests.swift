import Foundation
import Testing

@testable import Context_Dock

/// DoraX's own surfaces, as things the ranker can find.
///
/// The gap this closes, from the owner's report: Claude Desktop has a linked `claude` CLI, and
/// asked to start a new chat DoraX could neither use it well nor say it was there. Global
/// Commands, the clipboard, the preview window and the CLI scope were registered for execution
/// and described in prose, and indexed nowhere — so "given this sentence, what can I do about
/// it?" could never answer with one of them.
@Suite("DoraX's own capabilities")
struct DoraXOwnCapabilityTests {

    @Test func itsOwnSurfacesBelongToNoApp() {
        for record in DoraXOwnCapabilities.surfaces() {
            #expect(record.app.isEmpty, "\(record.id) is DoraX's, not an app's")
        }
    }

    /// The clipboard reads and the preview shows a window. Both are DoraX's, and they differ
    /// in what they cost — which is the whole reason surface exists.
    @Test func theirCostsAreStatedAndDiffer() throws {
        let byID = Dictionary(
            uniqueKeysWithValues: DoraXOwnCapabilities.surfaces().map { ($0.id, $0) })

        #expect(try #require(byID["dorax.clipboard"]).surface == .headless)
        #expect(try #require(byID["dorax.preview"]).surface == .opensApp)
        #expect(try #require(byID["dorax.cliScope"]).surface == .headless)
    }

    @Test func aGlobalCommandIsReachableFromEverywhereAndSaysSo() throws {
        let records = DoraXOwnCapabilities.globalCommands(named: ["Dark Mode", "Empty Trash"])

        #expect(records.map(\.id) == [
            "dorax.globalCommand.dark-mode", "dorax.globalCommand.empty-trash",
        ])
        #expect(try #require(records.first).surface == .headless)
        #expect(try #require(records.first).keywords == ["dark", "mode"])
    }

    // MARK: - The suggestion the report asked for

    /// A CLI linked to one app's scope is reachable only there. Saying so is the answer the
    /// owner wanted when "new chat on claude" found nothing useful.
    @Test func aLinkedCLIThatIsNotGlobalIsWorthSuggesting() throws {
        let suggestions = DoraXOwnCapabilities.linkCLISuggestions(
            appName: "Claude", linkedCLINames: ["claude"], existingGlobalCommands: [])

        let only = try #require(suggestions.first)
        #expect(only.title == "Add claude to Global Commands")
        #expect(only.description.contains("reachable only"))
        #expect(only.app == "Claude")
    }

    /// Advisory, and that is load-bearing: it runs nothing. Acting on it would be the same
    /// mistake as the URL action that started this — offering a thing that does not do what
    /// was asked, as though it did.
    @Test func theSuggestionRunsNothing() throws {
        let only = try #require(
            DoraXOwnCapabilities.linkCLISuggestions(
                appName: "Claude", linkedCLINames: ["claude"], existingGlobalCommands: []
            ).first)

        #expect(only.surface == .advisory)
        #expect(only.isWrite == false)
    }

    /// Telling somebody to add a thing they have added is noise, and noise is how advice gets
    /// ignored.
    @Test func nothingIsSuggestedWhenItIsAlreadyGlobal() {
        #expect(
            DoraXOwnCapabilities.linkCLISuggestions(
                appName: "Claude", linkedCLINames: ["claude"],
                existingGlobalCommands: ["Claude"]
            ).isEmpty)
    }

    @Test func noLinkedCLIMeansNoSuggestion() {
        #expect(
            DoraXOwnCapabilities.linkCLISuggestions(
                appName: "Calculator", linkedCLINames: [], existingGlobalCommands: []
            ).isEmpty)
    }
}
