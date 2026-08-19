import Testing
import Foundation
@testable import Context_Dock

// MARK: - What a memory chip says
//
// These are filenames and they were being shown raw, three at a time, above every answer:
//
//   ran Used memory: 18e64caa-mapped-it-here-s-what-s-actually-there-measured-.md
//   ran Used memory: preferences.md
//   ran Used memory: 2026-08-18.md
//
// More lines of filename than the answer had of sentence, and "ran" was the view asserting
// a verb over something that was read, not run.

@MainActor
struct MemoryChipLabelTests {

    private func label(_ filename: String) -> String {
        MarkdownMemoryStore.memoryLabel(for: filename)
    }

    // MARK: Captured notes

    /// The one from the screenshot. Eight hex characters keep the name unique on disk and
    /// mean nothing to a reader.
    @Test func aCapturedNoteLosesItsUniquenessPrefix() {
        let result = label("18e64caa-mapped-it-here-s-what-s-actually-there-measured-.md")
        #expect(!result.contains("18e64caa"))
        #expect(!result.contains(".md"))
        #expect(result.hasPrefix("Mapped it"))
    }

    /// The slug has already lost its apostrophes, leaving "here s what s". Putting them back
    /// is the difference between a label and a filename with the dashes taken out.
    @Test func strandedLettersBecomeContractionsAgain() {
        #expect(label("0c171fb5-i-can-t-do-that.md") == "I can't do that")
        #expect(label("5a9cb05b-here-s-the-plan.md") == "Here's the plan")
    }

    /// Long enough to be a sentence, short enough to be a chip.
    @Test func longNotesAreTruncatedRatherThanWrapped() {
        let result = label("18e64caa-mapped-it-here-s-what-s-actually-there-measured-.md")
        #expect(result.count <= 34)
        #expect(result.hasSuffix("…"))
    }

    /// A trailing dash is an artefact of slugging a truncated line, not part of the title.
    @Test func slugArtefactsDoNotSurvive() {
        #expect(label("0baab62d-new.md") == "New")
    }

    // MARK: The other three shapes

    @Test func namedFilesReadAsNames() {
        #expect(label("preferences.md") == "Preferences")
        #expect(label("projects.md") == "Projects")
        #expect(label("tasks.md") == "Tasks")
    }

    @Test func anAppsMemoryIsNamedAfterTheApp() {
        #expect(label("com.microsoft.VSCode.md") == "VSCode")
        #expect(label("com.apple.Safari.md") == "Safari")
    }

    @Test func daysReadAsDays() {
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        today.locale = Locale(identifier: "en_US_POSIX")

        #expect(label("\(today.string(from: Date())).md") == "Today")
        #expect(label("\(today.string(from: Date().addingTimeInterval(-86_400))).md") == "Yesterday")

        // An older day keeps a date rather than becoming "3 days ago", which stops being
        // useful the moment it is more than a few.
        let older = label("2026-08-04.md")
        #expect(older != "Today" && older != "Yesterday")
        #expect(older.contains("4"))
    }

    // MARK: Nothing to work with

    @Test func aNameWithNoStructureIsLeftAlone() {
        #expect(label("MEMORY.md") == "MEMORY")
        #expect(label("") == "")
        #expect(label(".md") == ".md")
    }
}
