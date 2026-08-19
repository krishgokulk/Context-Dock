import Testing
import Foundation
@testable import Context_Dock

// MARK: - Global Commands reaching the deterministic resolver
//
// "trash bin" was answered conversationally while two enabled commands matched it. The
// resolver had no idea Global Commands existed, and the one path that did — explicitRunMatch
// — demands a verb prefix plus the command's literal name. These cover the two gates that
// decide whether a keyword-shaped phrase now reaches an installed command at all.

@MainActor
struct GlobalCommandRoutingTests {

    /// The gate the fix depends on. A keyword phrase is not a question, so it must not be
    /// filtered out as read-shaped before the command lookup runs.
    @Test func keywordPhrasesAreNotTreatedAsQuestions() {
        let resolver = GeneralAIActionResolver.shared
        #expect(!resolver.looksReadOnly("trash bin"))
        #expect(!resolver.looksReadOnly("dark mode"))
        #expect(!resolver.looksReadOnly("empty bin"))
    }

    /// The other half: asking about a thing must never offer to run the command named after
    /// it. The keyword scorer cannot make this distinction itself — its noise list strips
    /// "what" before scoring, so "what is in my trash bin" scores exactly like "trash bin".
    @Test func questionsAboutTheSameNounStayQuestions() {
        let resolver = GeneralAIActionResolver.shared
        #expect(resolver.looksReadOnly("what's in my trash bin"))
        #expect(resolver.looksReadOnly("show me my trash"))
        #expect(resolver.looksReadOnly("how many items are in the bin"))
    }

    /// Imperatives keep their existing meaning — they are executable, not read-shaped, and
    /// were already routed before this change.
    @Test func imperativesRemainExecutable() {
        let resolver = GeneralAIActionResolver.shared
        #expect(!resolver.looksReadOnly("empty the trash"))
        #expect(!resolver.looksReadOnly("delete these files"))
    }
}

// MARK: - Capability identity and risk

@MainActor
struct GlobalCommandCapabilityShapeTests {

    /// Ids are derived from the name, so a candidate the resolver builds and the capability
    /// the executor looks up have to agree without either one holding a table.
    @Test func idsAreSluggedFromTheName() {
        let command = SystemCommand(
            name: "Empty Trash", icon: "trash", keywords: ["trash", "bin"],
            scriptType: "applescript", script: "tell application \"Finder\" to empty trash")
        #expect(GlobalCommandCapabilities.capabilityID(for: command) == "globalcmd.empty-trash")
    }

    @Test func idsSurvivePunctuationAndCasing() {
        let command = SystemCommand(
            name: "Wi-Fi: Toggle!", icon: "wifi", keywords: [],
            scriptType: "bash", script: "echo hi")
        #expect(GlobalCommandCapabilities.capabilityID(for: command) == "globalcmd.wi-fi-toggle")
    }

    /// Anything that runs a script is high risk, which is what puts the approval card in
    /// front of it. This matters more than usual here: the fix makes a keyword phrase able
    /// to surface Empty Trash, and the card is what stands between a match and a wipe.
    @Test func scriptCommandsAreHighRisk() {
        for scriptType in ["bash", "applescript", "jxa", "scriptFile"] {
            let command = SystemCommand(
                name: "Do Something", icon: "gear", keywords: [],
                scriptType: scriptType, script: "echo hi")
            #expect(GlobalCommandCapabilities.riskLevel(for: command) == .high)
        }
    }

    @Test func openingAUrlOrFileIsLowRisk() {
        for scriptType in ["url", "file"] {
            let command = SystemCommand(
                name: "Open Something", icon: "link", keywords: [],
                scriptType: scriptType, script: "https://example.com")
            #expect(GlobalCommandCapabilities.riskLevel(for: command) == .low)
        }
    }

    /// Named destructively even when the mechanism looks harmless.
    @Test func destructiveNamesAreHighRiskWhateverTheMechanism() {
        for name in ["Restart", "Shut Down", "Log Out", "Sleep"] {
            let command = SystemCommand(
                name: name, icon: "power", keywords: [],
                scriptType: "url", script: "x-apple.systempreferences:")
            #expect(GlobalCommandCapabilities.riskLevel(for: command) == .high)
        }
    }
}
