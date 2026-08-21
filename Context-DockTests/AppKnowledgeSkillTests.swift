import Testing
import Foundation
@testable import Context_Dock

// MARK: - What DoraX knows about an app before it answers
//
// Step 1 of docs/architecture/APP_KNOWLEDGE_SKILLS.md.
//
// An app's Help menu is a vendor-authored index of what the product is — "Documentation",
// "Show All Commands", "Ask @vscode", "Keyboard Shortcuts Reference". It is already in
// AppMenuCapabilityCache and reading the titles requires opening nothing, which is the
// whole point: a menu is a way to do something, never a way to know something.
//
// These cover the composition only. It is a pure function of (app, version, help titles,
// capability counts) so it can be tested without a running app or a warm cache.

struct AppKnowledgeSkillTests {

    private let help = [
        "Welcome", "Show All Commands", "Documentation", "Editor Playground",
        "Keyboard Shortcuts Reference", "Report Issue", "Ask @vscode",
    ]

    private func counts(
        actions: Int = 5, cli: Int = 4, skills: Int = 1, menus: Int = 20,
        mcp: Int = 0, api: Int = 0
    ) -> AppKnowledgeSkill.Capabilities {
        .init(actions: actions, cliTools: cli, skills: skills, menuCommands: menus,
              mcpServers: mcp, apiConnections: api)
    }

    // MARK: - The app's own words

    @Test func helpTitlesReachTheInstructions() throws {
        let skill = try #require(AppKnowledgeSkill.make(
            bundleId: "com.microsoft.VSCode", appName: "Code", version: "1.95.0",
            helpTitles: help, capabilities: counts()))
        for title in ["Documentation", "Show All Commands", "Ask @vscode"] {
            #expect(skill.instructions.contains(title))
        }
    }

    /// Separators and blanks are structure, not knowledge.
    @Test func menuNoiseIsNotKnowledge() throws {
        let skill = try #require(AppKnowledgeSkill.make(
            bundleId: "x", appName: "App", version: "1.0",
            helpTitles: ["-", "", "   ", "Documentation"], capabilities: counts()))
        #expect(skill.instructions.contains("Documentation"))
        #expect(!skill.instructions.contains("\n- -\n"))
    }

    /// The same title twice is one fact.
    @Test func titlesAreDeduplicated() throws {
        let skill = try #require(AppKnowledgeSkill.make(
            bundleId: "x", appName: "App", version: "1.0",
            helpTitles: ["Documentation", "documentation", "Documentation"],
            capabilities: counts()))
        let occurrences = skill.instructions.components(separatedBy: "Documentation").count - 1
        #expect(occurrences == 1)
    }

    // MARK: - Refreshing

    /// Version is the app's, not the skill's, so it refreshes when the app updates and
    /// never in between. A skill that rewrote itself on every launch would overwrite the
    /// user's edits daily.
    @Test func versionTracksTheApp() throws {
        let skill = try #require(AppKnowledgeSkill.make(
            bundleId: "com.microsoft.VSCode", appName: "Code", version: "1.95.0",
            helpTitles: help, capabilities: counts()))
        #expect(skill.version == "1.95.0")
    }

    /// One learned skill per app, found again by id rather than duplicated.
    @Test func identityIsStablePerApp() throws {
        let a = try #require(AppKnowledgeSkill.make(
            bundleId: "com.microsoft.VSCode", appName: "Code", version: "1.95.0",
            helpTitles: help, capabilities: counts()))
        let b = try #require(AppKnowledgeSkill.make(
            bundleId: "com.microsoft.VSCode", appName: "Code", version: "1.96.0",
            helpTitles: help, capabilities: counts()))
        #expect(a.id == b.id)
        #expect(a.adapterBundleId == b.adapterBundleId)
    }

    // MARK: - Honesty

    /// The skill states what DoraX can actually do here. Claiming capabilities it does not
    /// have is how a chat offers to run something that does not exist.
    @Test func capabilitiesAreStatedAsTheyAre() throws {
        let skill = try #require(AppKnowledgeSkill.make(
            bundleId: "x", appName: "App", version: "1.0", helpTitles: help,
            capabilities: counts(actions: 5, cli: 4, skills: 1, menus: 20)))
        #expect(skill.instructions.contains("5"))
        #expect(skill.instructions.contains("20"))
    }

    /// Nothing linked must not read as something linked.
    @Test func absentCapabilitiesAreNotAdvertised() throws {
        let skill = try #require(AppKnowledgeSkill.make(
            bundleId: "x", appName: "App", version: "1.0", helpTitles: help,
            capabilities: counts(mcp: 0, api: 0)))
        #expect(!skill.instructions.contains("0 MCP"))
        #expect(!skill.instructions.contains("0 API"))
    }

    /// With nothing learned and nothing granted there is no knowledge to write down, and a
    /// skill full of empty headings is worse than no skill.
    @Test func nothingToSayProducesNoSkill() {
        #expect(AppKnowledgeSkill.make(
            bundleId: "x", appName: "App", version: "1.0", helpTitles: [],
            capabilities: counts(actions: 0, cli: 0, skills: 0, menus: 0)) == nil)
    }

    /// Capabilities alone are worth a skill even when the app exposes no Help menu.
    @Test func capabilitiesAloneAreEnough() throws {
        let skill = try #require(AppKnowledgeSkill.make(
            bundleId: "x", appName: "App", version: "1.0", helpTitles: [],
            capabilities: counts(actions: 3, cli: 0, skills: 0, menus: 0)))
        #expect(skill.instructions.contains("App"))
    }

    /// The name has to be recognisable in a list beside the user's own workflows.
    @Test func theSkillNamesItsApp() throws {
        let skill = try #require(AppKnowledgeSkill.make(
            bundleId: "com.microsoft.VSCode", appName: "Code", version: "1.95.0",
            helpTitles: help, capabilities: counts()))
        #expect(skill.name.contains("Code"))
    }
}
