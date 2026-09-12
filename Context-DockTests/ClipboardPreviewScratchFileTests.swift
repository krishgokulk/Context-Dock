// ClipboardPreviewScratchFileTests.swift
// Context-DockTests
//
// The clipboard's text preview always wrote to one fixed scratch path, so every clip's
// preview shared the same PreviewItem.id (the URL). That made a second, different clip
// look identical to the first: `toggleIfSame` closed the window instead of showing the new
// text, and even on the reuse path SwiftUI's `.id(item.id)` never changed, so the panel kept
// rendering stale content. These assert the naming rule that fixed it, isolated from AppKit
// and the live preview window.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Clipboard preview scratch file")
struct ClipboardPreviewScratchFileTests {

    private func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardPreviewScratchFileTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Different text gets a different URL")
    func distinctTextDistinctURL() {
        let a = ClipboardPreviewScratchFile.url(for: "first clip")
        let b = ClipboardPreviewScratchFile.url(for: "second, unrelated clip")
        // This is the exact bug: two different clips producing the same id made the second
        // preview look like a repeat of the first instead of new content.
        #expect(a != b)
    }

    @Test("The same text always gets the same URL, within this run")
    func identicalTextIdenticalURL() {
        let text = "reread this exact sentence"
        #expect(ClipboardPreviewScratchFile.url(for: text)
            == ClipboardPreviewScratchFile.url(for: text))
    }

    @Test("Writing puts the exact text at its content-named URL")
    func writeRoundTrips() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = "what actually ends up on disk"
        let url = try #require(ClipboardPreviewScratchFile.write(text, in: dir))

        #expect(url == ClipboardPreviewScratchFile.url(for: text, in: dir))
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test("Pruning removes every earlier scratch file except the one just written")
    func pruningKeepsOnlyTheCurrentFile() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try #require(ClipboardPreviewScratchFile.write("clip one", in: dir))
        let second = try #require(ClipboardPreviewScratchFile.write("clip two", in: dir))
        #expect(FileManager.default.fileExists(atPath: first.path))

        ClipboardPreviewScratchFile.pruneStale(keeping: second, in: dir)

        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("Pruning never touches a file outside its own prefix")
    func pruningIsScopedToItsOwnFiles() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let unrelated = dir.appendingPathComponent("something-else-entirely.txt")
        try "not ours".write(to: unrelated, atomically: true, encoding: .utf8)
        let current = try #require(ClipboardPreviewScratchFile.write("the live one", in: dir))

        ClipboardPreviewScratchFile.pruneStale(keeping: current, in: dir)

        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
