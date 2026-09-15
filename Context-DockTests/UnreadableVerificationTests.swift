import Testing
import Foundation
@testable import Context_Dock

// MARK: - A check that could not run is not a check that failed
//
// `create a reminder "call sujith" today at 5 pm` created the reminder and EventKit
// confirmed it. The model then verified for itself, choosing
// ~/Library/Reminders/Reminders — a directory holding a SQLite store — and was told the
// text was not there. It reported to the user that the reminder had not been created.
//
// Two failures met: a content check on something that cannot be read as text, answered as
// though it had been read; and a model going looking for proof after a read-back had
// already given it.

@MainActor
struct UnreadableVerificationTests {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dorax-verify-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The exact shape from the bug.
    @Test func aDirectoryCannotBeSearchedForText() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let reason = AgentToolRegistry.unreadableAsText(directory.path)
        #expect(reason != nil)
        #expect(reason?.contains("directory") == true)
        // The words that matter: the model has to know this settles nothing, or it draws
        // the same conclusion from the same non-answer.
        #expect(reason?.contains("proves nothing") == true)
    }

    @Test func aMissingPathProvesNothingEitherWay() {
        let missing = temporaryDirectory().appendingPathComponent("absent.txt")
        let reason = AgentToolRegistry.unreadableAsText(missing.path)
        #expect(reason?.contains("could not be performed") == true)
    }

    @Test func binaryContentIsNotAFailedMatch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("store.bin")
        try Data([0xFF, 0xFE, 0x00, 0x01, 0xC0]).write(to: file)

        let reason = AgentToolRegistry.unreadableAsText(file.path)
        #expect(reason?.contains("proves nothing") == true)
    }

    /// The other side. A real text file is readable, so the content check runs and its
    /// answer means something — this helper must stay out of the way.
    @Test func areadableTextFileIsLeftToTheRealCheck() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "call sujith".write(to: file, atomically: true, encoding: .utf8)

        #expect(AgentToolRegistry.unreadableAsText(file.path) == nil)
    }

    @Test func anEmptyFileIsStillReadable() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("empty.txt")
        try "".write(to: file, atomically: true, encoding: .utf8)

        #expect(AgentToolRegistry.unreadableAsText(file.path) == nil)
    }
}
