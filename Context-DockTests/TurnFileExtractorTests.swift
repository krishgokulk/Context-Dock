import Foundation
import Testing
@testable import Context_Dock

// MARK: - Result cards: the files a finished turn named
//
// Task 16b. Finder App Chat found the passport PDFs and answered in prose; the paths were
// on screen and could not be opened. `TurnFileExtractor` reads them back out — from the
// answer and from what the steps returned — and keeps only what exists. The disk is a
// fake here: a set of paths that "exist", so nothing touches the real file system.

struct TurnFileExtractorTests {

    private let home = "/Users/me"

    private let disk: [String: TurnFileExtractor.Probe] = [
        "/Users/me/Documents/Travel/passport.pdf": .file,
        "/Users/me/Documents/Travel/passport scan.pdf": .file,
        "/Users/me/Documents/My Docs/visa.pdf": .file,
        "/Users/me/Documents/file(1).pdf": .file,
        "/Users/me/Documents/Travel": .directory,
        "/Users/me/Documents": .directory,
        "/tmp/report.csv": .file,
    ]

    private func probe(_ path: String) -> TurnFileExtractor.Probe? { disk[path] }

    private func files(
        _ answer: String, steps: [String] = [], limit: Int = TurnFileExtractor.defaultLimit
    ) -> [String] {
        TurnFileExtractor.files(
            answer: answer, stepOutputs: steps, limit: limit,
            homeDirectory: home, probe: probe
        ).map(\.path)
    }

    // MARK: Forms a path is written in

    @Test func aBarePathIsFound() {
        #expect(files("Found it: /Users/me/Documents/Travel/passport.pdf")
            == ["/Users/me/Documents/Travel/passport.pdf"])
    }

    @Test func aTildePathIsExpandedAgainstHome() {
        #expect(files("It is at ~/Documents/Travel/passport.pdf")
            == ["/Users/me/Documents/Travel/passport.pdf"])
    }

    @Test func backtickedAndQuotedPathsKeepTheirSpaces() {
        #expect(files("Open `~/Documents/Travel/passport scan.pdf` now")
            == ["/Users/me/Documents/Travel/passport scan.pdf"])
        #expect(files(#"Saved as "/Users/me/Documents/My Docs/visa.pdf"."#)
            == ["/Users/me/Documents/My Docs/visa.pdf"])
        #expect(files("See \u{201C}/Users/me/Documents/My Docs/visa.pdf\u{201D}")
            == ["/Users/me/Documents/My Docs/visa.pdf"])
        #expect(files("Try '/tmp/report.csv' first") == ["/tmp/report.csv"])
    }

    @Test func aBarePathWithASpaceIsReadToWhereTheFileEnds() {
        #expect(files("- /Users/me/Documents/Travel/passport scan.pdf (2 pages)")
            == ["/Users/me/Documents/Travel/passport scan.pdf"])
    }

    @Test func twoBarePathsOnOneLineStayTwo() {
        #expect(files("Both: /tmp/report.csv and ~/Documents/Travel/passport.pdf.")
            == ["/tmp/report.csv", "/Users/me/Documents/Travel/passport.pdf"])
    }

    @Test func trailingPunctuationIsNotPartOfThePath() {
        #expect(files("Saved to /tmp/report.csv.") == ["/tmp/report.csv"])
        #expect(files("Saved to /tmp/report.csv, done") == ["/tmp/report.csv"])
        #expect(files("(see /tmp/report.csv)") == ["/tmp/report.csv"])
        #expect(files("**/tmp/report.csv**") == ["/tmp/report.csv"])
        #expect(files("Is it /tmp/report.csv?") == ["/tmp/report.csv"])
    }

    @Test func aBracketTheNameOwnsIsKept() {
        #expect(files("Found /Users/me/Documents/file(1).pdf")
            == ["/Users/me/Documents/file(1).pdf"])
    }

    @Test func markdownAndFileLinksAreRead() {
        #expect(files("[passport](/Users/me/Documents/Travel/passport.pdf)")
            == ["/Users/me/Documents/Travel/passport.pdf"])
        #expect(files("file:///Users/me/Documents/Travel/passport%20scan.pdf")
            == ["/Users/me/Documents/Travel/passport scan.pdf"])
    }

    // MARK: What is not a result

    @Test func pathsThatDoNotExistAreDropped() {
        #expect(files("Maybe /Users/me/Documents/Travel/missing.pdf or /nope/x.txt").isEmpty)
    }

    @Test func urlsAndRelativeFragmentsAreNotPaths() {
        #expect(files("See https://example.com/tmp/report.csv and docs/tmp/report.csv").isEmpty)
    }

    @Test func rootAndHomeAreNotResults() {
        #expect(TurnFileExtractor.normalised("/", homeDirectory: home) == nil)
        #expect(TurnFileExtractor.normalised("~/", homeDirectory: home) == nil)
        #expect(TurnFileExtractor.normalised("/Users/me/", homeDirectory: home) == nil)
        #expect(TurnFileExtractor.normalised("relative/x", homeDirectory: home) == nil)
        #expect(TurnFileExtractor.normalised("/a/b/../c/./d/", homeDirectory: home) == "/a/c/d")
    }

    @Test func aFolderInTheAnswerIsKeptButAFolderInStepOutputIsNot() {
        #expect(files("They're in ~/Documents/Travel/") == ["/Users/me/Documents/Travel"])
        #expect(files("Done.", steps: ["mdfind -onlyin /Users/me/Documents/Travel passport"])
            .isEmpty)
    }

    // MARK: Order, dedupe, cap

    @Test func answerPathsLeadThenStepOutputFiles() {
        let found = files(
            "Your report: /tmp/report.csv",
            steps: ["/Users/me/Documents/Travel/passport.pdf\n/tmp/report.csv"])
        #expect(found == ["/tmp/report.csv", "/Users/me/Documents/Travel/passport.pdf"])
    }

    @Test func theSameFileWrittenTwoWaysIsOneCard() {
        let found = files(
            "~/Documents/Travel/passport.pdf and /Users/me/Documents//Travel/./passport.pdf",
            steps: ["`/Users/me/Documents/Travel/passport.pdf`"])
        #expect(found == ["/Users/me/Documents/Travel/passport.pdf"])
    }

    @Test func theListIsCapped() {
        var many: [String: TurnFileExtractor.Probe] = [:]
        let listing = (1...30).map { index -> String in
            let path = "/Users/me/Documents/f\(index).pdf"
            many[path] = .file
            return path
        }.joined(separator: "\n")
        let found = TurnFileExtractor.files(
            answer: "", stepOutputs: [listing], homeDirectory: home, probe: { many[$0] })
        #expect(found.count == TurnFileExtractor.defaultLimit)
        #expect(found.first?.path == "/Users/me/Documents/f1.pdf")
        #expect(files("/tmp/report.csv /Users/me/Documents/Travel/passport.pdf", limit: 1)
            == ["/tmp/report.csv"])
    }

    @Test func aHugeListingStopsAtTheProbeBudget() {
        var probes = 0
        let listing = (1...2_000).map { "/nowhere/f\($0).pdf" }.joined(separator: "\n")
        let found = TurnFileExtractor.files(
            answer: "", stepOutputs: [listing], homeDirectory: home,
            probe: { _ in probes += 1; return nil })
        #expect(found.isEmpty)
        #expect(probes <= TurnFileExtractor.probeBudget)
    }

    @Test func anAnswerWithNoPathsHasNoCards() {
        #expect(files("Your Mac has 12 GB free. Nothing else to do.").isEmpty)
    }
}
