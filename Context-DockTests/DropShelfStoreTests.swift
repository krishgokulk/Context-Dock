import AppKit
import Foundation
import Testing

@testable import Context_Dock

/// Every test runs against a temporary root, never the user's real shelf.
@MainActor
private func makeStore() -> DropShelfStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("shelf-\(UUID().uuidString)")
    return DropShelfStore(root: root)
}

@MainActor
private func makeFile(_ name: String, contents: String = "x") -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("src-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try? contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@MainActor
struct DropShelfClassificationTests {
    @Test func anImageIsFiledUnderImagesRatherThanDocuments() {
        // .image also conforms to .content, so an unordered rule set files this wrong.
        #expect(DropShelfStore.kind(for: makeFile("shot.png")) == .images)
    }

    @Test func aPDFIsADocument() {
        #expect(DropShelfStore.kind(for: makeFile("report.pdf")) == .documents)
    }

    @Test func anArchiveIsNotADocument() {
        #expect(DropShelfStore.kind(for: makeFile("bundle.zip")) == .archives)
    }

    @Test func aFolderIsFiledUnderOtherWholeRatherThanByItsContents() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(DropShelfStore.kind(for: dir) == .other)
    }

    @Test func anUnrecognisedTypeFallsBackToOther() {
        #expect(DropShelfStore.kind(for: makeFile("thing.zzzznotatype")) == .other)
    }
}

@MainActor
struct DropShelfDestinationTests {
    private let day = DateComponents(
        calendar: .current, year: 2026, month: 8, day: 23, hour: 12
    ).date!

    @Test func anItemIsFiledUnderItsKindThenTheDayItWasDropped() {
        let store = makeStore()

        let url = store.destinationURL(forName: "shot.png", kind: .images, date: day)

        #expect(url.deletingLastPathComponent().lastPathComponent == "2026-08-23")
        #expect(
            url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                == "Images")
        #expect(url.lastPathComponent == "shot.png")
    }

    /// Two dropped files sharing a name are two different items; silently destroying one
    /// would lose work the user believes is on the shelf.
    @Test func aNameCollisionGetsASuffixInsteadOfOverwriting() throws {
        let store = makeStore()
        let first = store.destinationURL(forName: "report.pdf", kind: .documents, date: day)
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: first)

        let second = store.destinationURL(forName: "report.pdf", kind: .documents, date: day)

        #expect(second.lastPathComponent == "report 2.pdf")
        #expect(try String(contentsOf: first, encoding: .utf8) == "original")
    }

    @Test func aThirdCollisionKeepsCounting() throws {
        let store = makeStore()
        for name in ["report.pdf", "report 2.pdf"] {
            let url = store.destinationURL(forName: name, kind: .documents, date: day)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }

        let third = store.destinationURL(forName: "report.pdf", kind: .documents, date: day)

        #expect(third.lastPathComponent == "report 3.pdf")
    }
}

@MainActor
struct DropShelfIngestTests {
    @Test func droppingAFileCopiesItAndLeavesTheOriginalAlone() throws {
        let store = makeStore()
        let source = makeFile("notes.pdf", contents: "hello")

        let item = try store.ingestFile(at: source, source: ("Finder", "com.apple.finder"))

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: store.url(for: item), encoding: .utf8) == "hello")
        #expect(item.kind == .documents)
        #expect(item.originalName == "notes.pdf")
    }

    /// Dropped text has no file of its own; without one it could never be dragged out.
    @Test func droppedTextBecomesATextFileNamedFromItsFirstLine() throws {
        let store = makeStore()

        let item = try store.ingestText(
            "Release checklist\nsecond line", source: ("Code", "com.microsoft.VSCode"))

        #expect(item.kind == .text)
        #expect(store.url(for: item).lastPathComponent == "Release checklist.txt")
        #expect(
            try String(contentsOf: store.url(for: item), encoding: .utf8)
                == "Release checklist\nsecond line")
    }

    @Test func textWithNoUsableFirstLineStillGetsAName() throws {
        let store = makeStore()

        let item = try store.ingestText("   \n\n  ", source: ("Code", "com.microsoft.VSCode"))

        #expect(store.url(for: item).pathExtension == "txt")
        #expect(!store.url(for: item).deletingPathExtension().lastPathComponent.isEmpty)
    }

    @Test func aVeryLongFirstLineIsTruncatedIntoASaneFilename() throws {
        let store = makeStore()

        let item = try store.ingestText(
            String(repeating: "a", count: 400), source: ("Code", "com.microsoft.VSCode"))

        #expect(store.url(for: item).deletingPathExtension().lastPathComponent.count <= 40)
    }

    @Test func aDroppedLinkBecomesAWeblocThatStillCarriesTheURL() throws {
        let store = makeStore()

        let item = try store.ingestURL(
            URL(string: "https://example.com/board")!, source: ("Safari", "com.apple.Safari"))

        #expect(item.kind == .links)
        #expect(store.url(for: item).pathExtension == "webloc")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: store.url(for: item)), format: nil)
        #expect((plist as? [String: Any])?["URL"] as? String == "https://example.com/board")
    }
}

@MainActor
struct DropShelfLifecycleTests {
    @Test func theNewestDropIsListedFirst() throws {
        let store = makeStore()
        _ = try store.ingestText("older", source: ("Code", "com.microsoft.VSCode"))
        _ = try store.ingestText("newer", source: ("Code", "com.microsoft.VSCode"))

        #expect(store.items.first?.originalName.hasPrefix("newer") == true)
    }

    @Test func removingAnItemDeletesTheShelfsCopy() throws {
        let store = makeStore()
        let item = try store.ingestText("scratch", source: ("Code", "com.microsoft.VSCode"))
        let copy = store.url(for: item)

        store.remove(item)

        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(store.items.isEmpty)
    }

    @Test func itemsSurviveBeingReloadedFromDisk() throws {
        let store = makeStore()
        _ = try store.ingestText("kept", source: ("Code", "com.microsoft.VSCode"))

        let reopened = DropShelfStore(root: store.root)

        #expect(reopened.items.count == 1)
        #expect(reopened.items.first?.sourceAppName == "Code")
    }

    /// The files are the truth. A lost index must not lose the shelf.
    @Test func aMissingIndexIsRebuiltByWalkingTheFolders() throws {
        let store = makeStore()
        _ = try store.ingestText("kept", source: ("Code", "com.microsoft.VSCode"))
        _ = try store.ingestFile(
            at: makeFile("shot.png"), source: ("Finder", "com.apple.finder"))
        try FileManager.default.removeItem(at: store.indexURL)

        let reopened = DropShelfStore(root: store.root)

        #expect(reopened.items.count == 2)
        #expect(Set(reopened.items.map(\.kind)) == Set([.text, .images]))
    }

    @Test func aCorruptIndexIsRebuiltRatherThanEmptyingTheShelf() throws {
        let store = makeStore()
        _ = try store.ingestText("kept", source: ("Code", "com.microsoft.VSCode"))
        try Data("not json".utf8).write(to: store.indexURL)

        let reopened = DropShelfStore(root: store.root)

        #expect(reopened.items.count == 1)
    }
}

// MARK: - Reading a dropped pasteboard

@MainActor
struct DropShelfPasteboardTests {
    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("shelf-test-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    private let source = (name: "Finder", bundleId: "com.apple.finder")

    @Test func aDroppedFileLandsOnTheShelfAsAFile() {
        let store = makeStore()
        let pb = pasteboard()
        pb.writeObjects([makeFile("dropped.pdf") as NSURL])

        let accepted = store.ingest(pasteboard: pb, source: source)

        #expect(accepted == 1)
        #expect(store.items.first?.kind == .documents)
        #expect(store.items.first?.originalName == "dropped.pdf")
    }

    @Test func droppingSeveralFilesAtOnceKeepsAllOfThem() {
        let store = makeStore()
        let pb = pasteboard()
        pb.writeObjects([makeFile("a.png") as NSURL, makeFile("b.pdf") as NSURL])

        let accepted = store.ingest(pasteboard: pb, source: source)

        #expect(accepted == 2)
        #expect(store.items.count == 2)
    }

    @Test func aDroppedWebLinkLandsAsALinkRatherThanAFile() {
        let store = makeStore()
        let pb = pasteboard()
        pb.writeObjects([URL(string: "https://example.com/board")! as NSURL])

        let accepted = store.ingest(pasteboard: pb, source: source)

        #expect(accepted == 1)
        #expect(store.items.first?.kind == .links)
    }

    /// A dropped file also puts its path on the pasteboard as a string. Reading the string
    /// first would file every dropped file as a text note.
    @Test func aDroppedFileIsNotMistakenForItsOwnPath() {
        let store = makeStore()
        let pb = pasteboard()
        let file = makeFile("real.png")
        pb.writeObjects([file as NSURL])
        pb.setString(file.path, forType: .string)

        _ = store.ingest(pasteboard: pb, source: source)

        #expect(store.items.count == 1)
        #expect(store.items.first?.kind == .images)
    }

    @Test func droppedTextWithNoFileBehindItBecomesANote() {
        let store = makeStore()
        let pb = pasteboard()
        pb.setString("a paragraph worth keeping", forType: .string)

        let accepted = store.ingest(pasteboard: pb, source: source)

        #expect(accepted == 1)
        #expect(store.items.first?.kind == .text)
    }

    @Test func anEmptyDropChangesNothing() {
        let store = makeStore()

        let accepted = store.ingest(pasteboard: pasteboard(), source: source)

        #expect(accepted == 0)
        #expect(store.items.isEmpty)
    }
}
