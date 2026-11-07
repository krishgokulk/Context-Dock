// FinderContextResolutionTests.swift
// Context-DockTests
//
// Tests for Finder autonomous context resolution and windowless grounding (#384).

import Foundation
import Testing
@testable import Context_Dock

@Suite("FinderContextResolutionTests")
struct FinderContextResolutionTests {

    @Test func wantsFileGroundingDetectsFileAndFolderInquiries() {
        #expect(FinderContextGrounder.wantsFileGrounding("did i have empolyment sharecode latest document in downloads?"))
        #expect(FinderContextGrounder.wantsFileGrounding("check files in documents"))
        #expect(FinderContextGrounder.wantsFileGrounding("what's on my desktop?"))
        #expect(FinderContextGrounder.wantsFileGrounding("where is my tax invoice pdf"))
        #expect(FinderContextGrounder.wantsFileGrounding("find the zip file"))
        #expect(!FinderContextGrounder.wantsFileGrounding("what is the capital of France?"))
        #expect(!FinderContextGrounder.wantsFileGrounding("tell me a joke about dogs"))
    }

    @Test func extractNamedFolderIdentifiesStandardDirectories() {
        let downloads = FinderContextGrounder.extractNamedFolder(from: "did i have sharecode in downloads?")
        #expect(downloads != nil)
        #expect(downloads?.lastPathComponent == "Downloads")

        let documents = FinderContextGrounder.extractNamedFolder(from: "check my documents folder for report")
        #expect(documents != nil)
        #expect(documents?.lastPathComponent == "Documents")

        let desktop = FinderContextGrounder.extractNamedFolder(from: "what files are on my desktop right now?")
        #expect(desktop != nil)
        #expect(desktop?.lastPathComponent == "Desktop")

        let none = FinderContextGrounder.extractNamedFolder(from: "summarize recent messages from Alice")
        #expect(none == nil)
    }

    @Test func extractQueryKeywordsStripsStopwordsAndExtractsStems() {
        let keywords = FinderContextGrounder.extractQueryKeywords(
            from: "did i have empolyment sharecode latest document in downloads?")
        
        // Stopwords stripped
        #expect(!keywords.contains("did"))
        #expect(!keywords.contains("have"))
        #expect(!keywords.contains("latest"))
        #expect(!keywords.contains("document"))
        #expect(!keywords.contains("in"))

        // Relevant stems and tokens extracted
        #expect(keywords.contains("employ") || keywords.contains("empolyment"))
        #expect(keywords.contains("share") || keywords.contains("code") || keywords.contains("sharecode"))
    }

    @Test func matchFilesRanksMatchingNamesAboveIrrelevantFiles() {
        let file1 = FinderGroundedFile(
            name: "Details to give your employer – GOV.UK.png",
            path: "/Users/test/Downloads/Details to give your employer – GOV.UK.png",
            sizeBytes: 343_900,
            formattedSize: "344 KB",
            modificationDate: Date(),
            isDirectory: false
        )
        let file2 = FinderGroundedFile(
            name: "wallpaper-rotated.jpg",
            path: "/Users/test/Downloads/wallpaper-rotated.jpg",
            sizeBytes: 1_200_000,
            formattedSize: "1.2 MB",
            modificationDate: Date().addingTimeInterval(-3600),
            isDirectory: false
        )
        let file3 = FinderGroundedFile(
            name: "Invoice-DRFL2IF001.pdf",
            path: "/Users/test/Downloads/Invoice-DRFL2IF001.pdf",
            sizeBytes: 120_000,
            formattedSize: "120 KB",
            modificationDate: Date().addingTimeInterval(-7200),
            isDirectory: false
        )

        let matches = FinderContextGrounder.matchFiles(
            in: [file1, file2, file3],
            keywords: ["employ", "gov", "uk", "share"],
            rawQuery: "did i have empolyment sharecode in downloads"
        )

        #expect(!matches.isEmpty)
        #expect(matches.first?.name == "Details to give your employer – GOV.UK.png")
    }

    @Test func resolveFinderContextWithSelectionTakesPrecedence() {
        let tempDir = FileManager.default.temporaryDirectory
        let sampleFile = tempDir.appendingPathComponent("sample_selection_test.txt")
        try? "test".write(to: sampleFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sampleFile) }

        let outcome = FinderContextGrounder.resolveFinderContext(
            query: "where is this?",
            finderSelection: [sampleFile.path]
        )

        #expect(outcome.targetSource == .selection)
        #expect(outcome.matchingFiles.count == 1)
        #expect(outcome.matchingFiles.first?.name == "sample_selection_test.txt")
    }

    @Test func resolveFinderContextWithoutSelectionOrWindowsFallsBackGracefully() {
        // Query naming downloads
        let outcomeDownloads = FinderContextGrounder.resolveFinderContext(
            query: "check my downloads for images",
            finderSelection: []
        )
        #expect(outcomeDownloads.targetSource == .queryNamedFolder)
        #expect(outcomeDownloads.targetPath.hasSuffix("Downloads"))

        // Windowless query naming no folder
        let outcomeWindowless = FinderContextGrounder.resolveFinderContext(
            query: "what files do i have?",
            finderSelection: []
        )
        // Resolves to either open window or windowless roots
        #expect(outcomeWindowless.targetSource == .openWindow || outcomeWindowless.targetSource == .windowlessRoots)
        #expect(!outcomeWindowless.targetPath.isEmpty)
    }

    @Test func promptBlockOutputsStructuredFactualMarkdown() {
        let file = FinderGroundedFile(
            name: "Details to give your employer – GOV.UK.png",
            path: "/Users/test/Downloads/Details to give your employer – GOV.UK.png",
            sizeBytes: 343_900,
            formattedSize: "344 KB",
            modificationDate: Date(),
            isDirectory: false
        )
        let outcome = FinderGroundingOutcome(
            targetPath: "/Users/test/Downloads",
            targetSource: .queryNamedFolder,
            matchingFiles: [file],
            recentFiles: [file],
            totalItemsCount: 1,
            totalSizeBytes: 343_900,
            formattedTotalSize: "344 KB"
        )

        let block = FinderContextGrounder.promptBlock(for: outcome)
        #expect(block.contains("Live Finder Filesystem Context"))
        #expect(block.contains("Details to give your employer – GOV.UK.png"))
        #expect(block.contains("/Users/test/Downloads"))
        #expect(block.contains("Target Directory Total Size: 344 KB"))
    }

    @Test func calculateDirectorySizeCalculatesTotalBytesAndItemCount() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create 2 mock files
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.dat")
        let data1 = Data(repeating: 65, count: 1024)
        let data2 = Data(repeating: 66, count: 2048)
        try data1.write(to: file1)
        try data2.write(to: file2)

        let stats = FinderContextGrounder.calculateDirectorySize(at: tempDir)
        #expect(stats != nil)
        #expect(stats?.itemCount == 2)
        #expect(stats?.sizeBytes == 3072)
    }
}
