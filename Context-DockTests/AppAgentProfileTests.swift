import Foundation
import Testing

@testable import Context_Dock

// An app's behaviour, written as a file.
//
// The profile's whole purpose is that teaching DoraX a new app stops meaning editing DoraX. That
// only holds if the parser is forgiving in the right direction: a typo loses one line and says
// so, never a whole app's tools.

struct AppAgentProfileTests {

    private let safari = """
        ---
        app: Safari
        bundle_id: com.apple.Safari
        summary: Browsing, tabs, page content, and the open page's links.
        tools:
          capabilities: [browser.tabs, browser.currentPage]
          mcp: [safari-mcp]
          scripts: [tabs-to-md.sh]
        never:
          - Close or quit the browser without being asked to
          - Read history when the question is about the page in front of the user
        verify:
          tabs: browser.tabs
        ---

        Prefer the extension's live page read over AppleScript: it sees the page the user is
        looking at.
        """

    @Test func aProfileReadsAsItWasWritten() {
        let profile = AppAgentProfile.parse(safari)
        #expect(profile.appName == "Safari")
        #expect(profile.bundleID == "com.apple.Safari")
        #expect(profile.summary.hasPrefix("Browsing, tabs"))
        #expect(profile.tools.capabilities == ["browser.tabs", "browser.currentPage"])
        #expect(profile.tools.mcp == ["safari-mcp"])
        #expect(profile.tools.scripts == ["tabs-to-md.sh"])
        #expect(profile.never.count == 2)
        #expect(profile.verify["tabs"] == "browser.tabs")
        #expect(profile.instructions.hasPrefix("Prefer the extension's live page read"))
        #expect(profile.problems.isEmpty)
    }

    @Test func notDeclaredAndDeclaredNoneAreDifferentStatements() {
        // An app with no `cli:` line keeps whatever DoraX infers today. An app that writes
        // `cli: []` is saying it has none, and that must not be read as silence.
        let profile = AppAgentProfile.parse("""
            ---
            app: Notes
            tools:
              cli: []
            ---
            """)
        #expect(profile.tools.cli == [])
        #expect(profile.tools.capabilities == nil)
    }

    @Test func aListMayBeWrittenEitherWay() {
        let inline = AppAgentProfile.parse("""
            ---
            tools:
              capabilities: [a, b]
            ---
            """)
        let block = AppAgentProfile.parse("""
            ---
            tools:
              capabilities:
                - a
                - b
            ---
            """)
        #expect(inline.tools.capabilities == ["a", "b"])
        #expect(block.tools.capabilities == ["a", "b"])
    }

    @Test func aTypoCostsOneLineAndIsReported() {
        // The failure mode that matters: a bad key must not take the app's tools with it.
        let profile = AppAgentProfile.parse("""
            ---
            app: Safari
            summry: typo here
            tools:
              capabilities: [browser.tabs]
            ---
            """)
        #expect(profile.appName == "Safari")
        #expect(profile.tools.capabilities == ["browser.tabs"])
        #expect(profile.problems.contains { $0.contains("summry") })
    }

    @Test func aFileWithNoFrontMatterIsAllInstructions() {
        let profile = AppAgentProfile.parse("Just tell the model this.")
        #expect(profile.instructions == "Just tell the model this.")
        #expect(profile.tools.isEmpty)
    }

    @Test func anUnterminatedBlockKeepsWhatItCanRead() {
        // A missing closing `---` is a mistake; losing the app's declared tools to it would be
        // a worse one.
        let profile = AppAgentProfile.parse("""
            ---
            app: Safari
            tools:
              capabilities: [browser.tabs]
            """)
        #expect(profile.appName == "Safari")
        #expect(profile.tools.capabilities == ["browser.tabs"])
    }

    @Test func quotesAreNotPartOfTheValue() {
        let profile = AppAgentProfile.parse("""
            ---
            summary: "Browsing and tabs"
            never:
              - "Quit the browser"
            ---
            """)
        #expect(profile.summary == "Browsing and tabs")
        #expect(profile.never == ["Quit the browser"])
    }

    @Test func aProfileSurvivesARoundTrip() {
        let original = AppAgentProfile.parse(safari)
        let reparsed = AppAgentProfile.parse(original.markdown())
        #expect(reparsed.appName == original.appName)
        #expect(reparsed.bundleID == original.bundleID)
        #expect(reparsed.tools == original.tools)
        #expect(reparsed.never == original.never)
        #expect(reparsed.verify == original.verify)
        #expect(reparsed.instructions == original.instructions)
        #expect(reparsed.problems.isEmpty)
    }

    @Test func anEmptyProfileKnowsItIsEmpty() {
        #expect(AppAgentProfile.parse("").isEmpty)
        #expect(!AppAgentProfile.parse(safari).isEmpty)
    }
}

// Apple's own MCP servers, offered per app.
struct NativeMCPCatalogTests {

    @Test func safariIsOfferedOnSafarisPage() {
        let servers = NativeMCPCatalog.servers(forBundleID: "com.apple.Safari")
        #expect(servers.count == 1)
        #expect(servers.first?.id == "safari-mcp")
    }

    @Test func anotherAppIsOfferedNothing() {
        #expect(NativeMCPCatalog.servers(forBundleID: "com.apple.Notes").isEmpty)
    }

    @Test func theConfigurationIsTheCommandAppleDocuments() {
        // `safaridriver --mcp`, over stdio, linked to Safari — the shape MCPServerConfig
        // already stores, which is why this is a catalogue entry and not a new subsystem.
        let config = NativeMCPCatalog.configuration(for: NativeMCPCatalog.safari)
        #expect(config.command == "/usr/bin/safaridriver")
        #expect(config.args == ["--mcp"])
        #expect(config.transport == "stdio")
        #expect(config.bundleIds == ["com.apple.Safari"])
    }

    @Test func theRequirementsAreStatedRatherThanAssumed() {
        // Both Safari settings are the user's to turn on, and the version requirement is real:
        // an older Mac must read "your Safari is a version behind", not "DoraX cannot do this".
        let requirements = NativeMCPCatalog.safari.requirements
        #expect(requirements.contains { $0.contains("Safari 27") })
        #expect(requirements.contains { $0.lowercased().contains("remote automation") })
        #expect(requirements.contains { $0.lowercased().contains("web developers") })
    }
}

// The profile on disk, and what a turn sees.
@MainActor
struct AppAgentProfileStoreTests {

    private func temporaryStore() -> (AppAgentProfileStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-profiles-\(UUID().uuidString)", isDirectory: true)
        return (AppAgentProfileStore(root: root), root)
    }

    @Test func anAppWithNoProfileHasNone() {
        // The ordinary case, and it must stay cheap and silent: every app without a file
        // behaves exactly as DoraX behaves today.
        let (store, _) = temporaryStore()
        #expect(store.profile(forBundleID: "com.apple.Safari") == nil)
    }

    @Test func aSavedProfileIsReadBack() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var profile = AppAgentProfile.parse("""
            ---
            app: Safari
            tools:
              capabilities: [browser.tabs]
            ---

            Prefer the live page read.
            """, bundleID: "com.apple.Safari")
        profile.never = ["Quit the browser"]
        try store.save(profile, forBundleID: "com.apple.Safari")

        let read = store.profile(forBundleID: "com.apple.Safari")
        #expect(read?.tools.capabilities == ["browser.tabs"])
        #expect(read?.never == ["Quit the browser"])
        #expect(read?.instructions == "Prefer the live page read.")
    }

    @Test func editingTheFileChangesWhatTheNextTurnReads() throws {
        // Cached by modification date, because a profile is read every turn and edited about
        // once a month — but a stale cache would mean the authoring UI and the chat disagree.
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var profile = AppAgentProfile.parse("---\napp: Notes\n---\nFirst version.")
        try store.save(profile, forBundleID: "com.apple.Notes")
        #expect(store.profile(forBundleID: "com.apple.Notes")?.instructions == "First version.")

        profile.instructions = "Second version."
        try store.save(profile, forBundleID: "com.apple.Notes")
        #expect(store.profile(forBundleID: "com.apple.Notes")?.instructions == "Second version.")
    }

    @Test func theListNamesOnlyAppsThatWroteOne() throws {
        let (store, root) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.save(
            AppAgentProfile.parse("---\napp: Notes\n---\nBody."), forBundleID: "com.apple.Notes")
        #expect(store.bundleIDsWithProfiles() == ["com.apple.notes"])
    }
}
