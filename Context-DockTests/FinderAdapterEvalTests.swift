import Foundation
import Testing

@testable import Context_Dock

// The Finder adapter's canonical question set.
//
// Finder is the richest adapter and the only one where a mistake destroys something. Its
// group-one variant is scope integrity: for Reminders grounding means reading before claiming,
// for Safari it means taking the tool-less path, and here it means acting on exactly the paths
// the user meant and no others.
//
// Every capability that changes a file is declared .high or .medium, and the three that would
// act *on* a folder rather than inside it are refused when aimed at the scope's own root —
// trashing, moving or renaming the directory a conversation is about leaves the thread
// pointing at nothing.

@MainActor
struct FinderAdapterEvalTests {

    private static let bundleId = "com.apple.finder"

    private func decision(_ query: String) -> AgentSourceDecision {
        AgentSourceAuthority.decide(query: query, scopeBundleId: Self.bundleId)
    }

    // MARK: - Changes stay changes

    /// Finder's whole vocabulary is verbs. If one of them is not recognised as a change, the
    /// request is answered from a reader — described rather than done, and with no approval
    /// sheet in front of it.
    @Test func theVerbsPeopleUseOnFilesAreAllChanges() {
        for query in [
            "organize these",
            "rename this file to invoice-final",
            "move these to Downloads",
            "delete this",
            "copy these to the Client folder",
            "make a new folder called Screenshots",
        ] {
            #expect(
                GeneralAIActionResolver.shared.requestsChange(query),
                "\"\(query)\" changes files but reads as a question")
        }
    }

    /// The counterweight: questions about the same files must not become changes, or they lose
    /// their grounding and get an approval sheet for nothing.
    @Test func questionsAboutFilesAreNotChanges() {
        for query in [
            "what files are selected?",
            "what folder am i in?",
            "how much space is left?",
            "which of these are duplicates?",
        ] {
            #expect(
                !GeneralAIActionResolver.shared.requestsChange(query),
                "\"\(query)\" only asks")
        }
    }

    // MARK: - Consequence is declared

    /// A destructive capability marked .low executes with no approval sheet at all. These are
    /// the ones that move, rename, delete or reorganise someone's files.
    @Test func everythingThatTouchesFilesIsGated() {
        let registry = CapabilityRegistry.shared
        for id in [
            "finder.trash", "finder.renameFiles", "finder.moveFiles", "finder.copyFiles",
            "finder.organize", "finder.newFolder",
        ] {
            guard let capability = registry.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(
                capability.riskLevel.requiresApproval,
                "\(id) changes files but would run with no approval")
        }
    }

    /// Reads stay free. An approval sheet in front of "what folder am I in?" trains people to
    /// approve without reading, which is what makes the sheet in front of trash worthless.
    @Test func lookingAtFilesCostsNoApproval() {
        let registry = CapabilityRegistry.shared
        for id in [
            "finder.duplicates", "finder.staleFiles", "finder.diskSpace", "finder.folderSize",
            "finder.searchFiles", "finder.listFolder", "finder.readFile", "finder.fileInfo",
            "finder.recentByKind", "finder.reveal",
        ] {
            guard let capability = registry.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(!capability.riskLevel.requiresApproval, "\(id) only reads but asks approval")
        }
    }

    /// Trash is recoverable; rename and move are not, in the sense that matters — the file is
    /// somewhere the user did not put it. All three deserve the loudest declaration.
    @Test func theIrreversibleOnesAreHighNotMedium() {
        for id in ["finder.trash", "finder.renameFiles", "finder.moveFiles"] {
            guard let capability = CapabilityRegistry.shared.capability(id: id) else {
                Issue.record("\(id) is not registered"); continue
            }
            #expect(capability.riskLevel == .high, "\(id) is \(capability.riskLevel.rawValue)")
        }
    }

    // MARK: - Absence stays a finding

    /// Verbatim from FinderCoworkerCapabilities. A search that ran and matched nothing has
    /// answered the question — "no duplicates" is a result, not a failure to look.
    @Test func findingNothingIsAnAnswer() {
        for output in [
            "No files matched \"invoice\".",
            "No duplicate names and sizes in this folder.",
            "Nothing to organise in /Users/x/Downloads.",
        ] {
            #expect(!EvidenceSufficiency.admitsDefeat(output), "\"\(output)\" is a finding")
        }
    }
}
