import Foundation
import Testing

@testable import Context_Dock

// File search with Spotlight off: a temp-directory fixture, an injected Spotlight runner, no
// dependence on the machine's index.

struct FileSearchServiceTests {

    private static func makeFixture() throws -> (home: String, docs: String, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("filesearch-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let fm = FileManager.default
        let docs = base.appendingPathComponent("Documents")
        try fm.createDirectory(at: docs.appendingPathComponent("Travel/Old"), withIntermediateDirectories: true)
        try fm.createDirectory(at: docs.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("Library/Stuff"), withIntermediateDirectories: true)
        func touch(_ url: URL, age: TimeInterval = 0) throws {
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try touch(docs.appendingPathComponent("Passport Scan.pdf"), age: 1000)
        try touch(docs.appendingPathComponent("Travel/passport-renewal.PDF"), age: 10)
        try touch(docs.appendingPathComponent("Travel/Old/old PASSPORT copy.pdf"), age: 5000)
        try touch(docs.appendingPathComponent("Travel/passport notes.txt"))
        try touch(docs.appendingPathComponent(".hidden/passport secret.pdf"))
        try touch(base.appendingPathComponent("Library/Stuff/passport cache.pdf"))
        return (base.path, docs.path, { try? fm.removeItem(at: base) })
    }

    private let spotlightOff: FileSearchService.SpotlightRunner = { _, _, _ in [] }

    @Test func tokensDropFillerAndFoldPlurals() {
        #expect(FileSearchService.tokens(from: "find my passport pdfs") == ["passport", "pdf"])
        #expect(FileSearchService.tokens(from: "the files") == [])
        #expect(FileSearchService.tokens(from: "Tax Return 2025") == ["tax", "return", "2025"])
    }

    @Test func scanFindsPassportPDFsWhenSpotlightIsOff() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let outcome = FileSearchService.search(
            query: "find my passport pdfs",
            options: .init(roots: [fixture.docs], homeDirectory: fixture.home),
            spotlight: spotlightOff)
        #expect(outcome.source == .scan)
        // Case-insensitive, nested, full absolute paths; hidden dirs and the .txt are out.
        #expect(outcome.paths.count == 3)
        #expect(outcome.paths.allSatisfy { $0.hasPrefix("/") })
        #expect(outcome.paths.contains(fixture.docs + "/Travel/Old/old PASSPORT copy.pdf"))
        #expect(!outcome.paths.contains { $0.contains(".hidden") || $0.hasSuffix(".txt") })
    }

    @Test func resultsAreNewestFirst() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let outcome = FileSearchService.search(
            query: "passport pdf",
            options: .init(roots: [fixture.docs], homeDirectory: fixture.home),
            spotlight: spotlightOff)
        #expect(outcome.paths.map { ($0 as NSString).lastPathComponent } == [
            "passport-renewal.PDF", "Passport Scan.pdf", "old PASSPORT copy.pdf",
        ])
    }

    @Test func spotlightHitsShortCircuitTheScan() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let hit = fixture.docs + "/Passport Scan.pdf"
        let outcome = FileSearchService.search(
            query: "passport pdf",
            options: .init(roots: [fixture.docs], homeDirectory: fixture.home),
            spotlight: { _, _, _ in [hit, "/nowhere/passport.pdf", fixture.docs + "/.hidden/passport secret.pdf"] })
        #expect(outcome.source == .spotlight)
        #expect(outcome.paths == [hit])
    }

    @Test func libraryIsSkippedWhenScanningTheHome() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let outcome = FileSearchService.search(
            query: "passport cache",
            options: .init(roots: [fixture.home], homeDirectory: fixture.home),
            spotlight: spotlightOff)
        #expect(outcome.paths.isEmpty)
        #expect(outcome.source == .none)
    }

    @Test func depthLimitStopsTheDescent() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        var options = FileSearchService.Options(roots: [fixture.docs], homeDirectory: fixture.home)
        options.maxDepth = 1
        let outcome = FileSearchService.search(
            query: "passport pdf", options: options, spotlight: spotlightOff)
        #expect(outcome.paths == [fixture.docs + "/Passport Scan.pdf"])
    }

    @Test func visitedCapMarksTheScanTruncated() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        var options = FileSearchService.Options(roots: [fixture.docs], homeDirectory: fixture.home)
        options.maxVisited = 2
        let outcome = FileSearchService.search(
            query: "passport", options: options, spotlight: spotlightOff)
        #expect(outcome.truncated)
    }

    @Test func timeBudgetStopsTheScan() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        var options = FileSearchService.Options(roots: [fixture.docs], homeDirectory: fixture.home)
        options.scanTimeBudget = 1
        // A clock that jumps 10 seconds per reading is past the budget by the first entry.
        let ticks = Ticker()
        let outcome = FileSearchService.search(
            query: "passport", options: options, spotlight: spotlightOff,
            now: { ticks.next() })
        #expect(outcome.truncated)
    }

    @Test func resultsAreCapped() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        var options = FileSearchService.Options(roots: [fixture.docs], homeDirectory: fixture.home)
        options.maxResults = 2
        let outcome = FileSearchService.search(
            query: "passport", options: options, spotlight: spotlightOff)
        #expect(outcome.paths.count == 2)
    }

    @Test func reportListsPathsOnePerLineAndTheExtractorReadsThem() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let outcome = FileSearchService.search(
            query: "passport pdf",
            options: .init(roots: [fixture.docs], homeDirectory: fixture.home),
            spotlight: spotlightOff)
        let report = FileSearchService.report(
            query: "passport pdf", outcome: outcome, homeDirectory: fixture.home)
        for path in outcome.paths { #expect(report.contains("\n" + path)) }
        let cards = TurnFileExtractor.files(answer: "", stepOutputs: [report])
        #expect(cards.map(\.path) == outcome.paths)
    }

    @Test func emptyOutcomeTellsTheModelNotToGuess() {
        let report = FileSearchService.report(
            query: "zzz",
            outcome: .init(paths: [], source: .none, truncated: false, searchedRoots: ["/tmp/x"]))
        #expect(report.contains("do not guess"))
    }

    @MainActor @Test func findFilesIsRegisteredAndReadOnly() {
        let tool = AgentToolRegistry.shared.tool(named: "find_files")
        #expect(tool != nil)
        #expect(tool?.required == ["query"])
        #expect(tool?.properties["requires_approval"] == nil)
    }

    @MainActor @Test func mcpServerListsTheTool() {
        let names = DoraXMCPServer.toolDefinitions(attended: false).compactMap { $0["name"] as? String }
        #expect(names.contains("dorax_find_files"))
    }

    @MainActor @Test func theFinderPackIsOfferedFindFiles() {
        let plan = FrontmostAppTaskPlan.make(
            query: "find my passport pdfs", bundleId: "com.apple.finder", appName: "Finder")
        #expect(plan.allowedToolNames.contains("find_files"))
    }
}

private final class Ticker: @unchecked Sendable {
    private var t = Date()
    func next() -> Date { t = t.addingTimeInterval(10); return t }
}
