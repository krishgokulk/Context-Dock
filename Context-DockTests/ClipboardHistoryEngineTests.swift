import AppKit
import Testing

@testable import Context_Dock

/// The clipboard history's own rules, moved out of the old launcher (issue #247, 4a).
@MainActor
struct ClipboardHistoryEngineTests {
    @Test func theSameContentIsTheSameClip() {
        let a = ClipboardHistoryEngine.contentHash(text: "hello", filePaths: [], imageData: nil)
        #expect(a == ClipboardHistoryEngine.contentHash(text: "hello", filePaths: [], imageData: nil))
        #expect(a != ClipboardHistoryEngine.contentHash(text: "hello!", filePaths: [], imageData: nil))
        // Files and images are told apart from text that happens to read the same.
        let files = ClipboardHistoryEngine.contentHash(text: "/a", filePaths: ["/a"], imageData: nil)
        #expect(files.hasPrefix("files:"))
        let image = ClipboardHistoryEngine.contentHash(text: "", filePaths: [], imageData: Data([1, 2, 3]))
        #expect(image.hasPrefix("image:"))
        #expect(image == ClipboardHistoryEngine.contentHash(text: "x", filePaths: ["/b"], imageData: Data([1, 2, 3])))
    }

    @Test func aPasswordManagersClipIsNeverRecorded() {
        let pb = NSPasteboard(name: .init("cd-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("hunter2", forType: .string)
        #expect(!ClipboardHistoryEngine.isConcealed(pb))
        pb.clearContents()
        pb.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        pb.setString("hunter2", forType: .string)
        #expect(ClipboardHistoryEngine.isConcealed(pb))
    }
}
