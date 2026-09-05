import Testing
import Foundation
@testable import Context_Dock

// MARK: - Global integrations have to be findable
//
// Settings ▸ Integrations ▸ Global holds three kinds: CLI tools, Global Commands and Global
// Extensions. Only the CLI tools worked, and the reason was one line — the scorer was handed
//
//     allItems.filter { $0.type == .application || $0.type == .cliTool }
//
// which drops every `.extensionCommand`. Commands and Extensions are both that type, so
// neither could be scored, and an item with no score is rebuilt into no row. A Global
// Command survived only when it had presets and the user typed its name exactly, because
// systemCommandPresetSearchResults expands those separately; a command without presets, and
// every extension, answered to nothing at all.
//
// `SearchCandidateKind` has carried an `extensionCommand` case with a priority the whole
// time. The scorer was always meant to rank these; the filter never delivered one.

struct GlobalIntegrationSearchTests {

    // MARK: - What reaches the scorer

    /// The bug, stated as the rule it broke.
    @Test func globalCommandsAndExtensionsReachTheScorer() {
        #expect(SearchCandidateEligibility.isSearchable(.extensionCommand))
    }

    /// What already worked must keep working — this is the half of the filter that was
    /// right, and the reason CLI tools on that same tab behaved.
    @Test func applicationsAndCLIToolsStillReachTheScorer() {
        #expect(SearchCandidateEligibility.isSearchable(.application))
        #expect(SearchCandidateEligibility.isSearchable(.cliTool))
    }

    /// Files, contacts, calendar events and the rest arrive through their own pipelines and
    /// are scored separately. Letting them in here would rank the same item twice.
    @Test func indexedKindsAreNotCandidatesFromThisPool() {
        for kind: SearchResult.ResultType in [.file, .folder, .document, .contact, .mail] {
            #expect(!SearchCandidateEligibility.isSearchable(kind), "\(kind) is indexed elsewhere")
        }
    }

    // MARK: - What the sentence is matched against

    /// Passing the filter is not enough on its own. searchableText(for:) has branches for
    /// cli:// and syscmd:// that pull in each one's keywords and description, and had none
    /// for userext:// — so an extension would still have matched on its title alone, and
    /// the keywords the user typed when creating it would go on being ignored.
    @Test func anExtensionIsSearchableByItsKeywords() {
        let ext = UserGlobalExtension(
            name: "Process Monitor",
            description: "Live list of running processes",
            keywords: ["ps", "cpu", "activity"])
        let terms = ext.searchTerms

        #expect(terms.contains("Process Monitor"))
        #expect(terms.contains("Live list of running processes"))
        for keyword in ["ps", "cpu", "activity"] {
            #expect(terms.contains(keyword), "keyword \(keyword) must be searchable")
        }
    }

    /// Empty fields are optional in the create sheet, and an empty term would widen every
    /// haystack it joined.
    @Test func emptyFieldsContributeNothing() {
        let ext = UserGlobalExtension(name: "Bare", description: "", keywords: ["", "  "])
        #expect(ext.searchTerms == ["Bare"])
    }

    /// The description defaults to the name when left blank, and the same word twice adds
    /// nothing to a match.
    @Test func theSameWordIsNotRepeated() {
        let ext = UserGlobalExtension(name: "Wi-Fi", keywords: ["Wi-Fi", "wifi"])
        #expect(ext.searchTerms.filter { $0 == "Wi-Fi" }.count == 1)
    }
}
