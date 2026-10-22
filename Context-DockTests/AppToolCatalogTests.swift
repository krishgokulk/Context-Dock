// AppToolCatalogTests.swift
// Context-DockTests
//
// The catalog schema (issue #203, plan §6.2): every shipped entry is complete and
// installable-mentioning, suggestions resolve by bundle id, and the card's lines never
// promise that DoraX installs anything.

import Testing
import Foundation

@testable import Context_Dock

struct AppToolCatalogTests {
    // MARK: - Schema

    @Test func everyShippedEntryIsComplete() {
        for entry in AppToolCatalog.entries {
            #expect(!entry.app.isEmpty)
            #expect(!entry.bundleIds.isEmpty)
            #expect(!entry.tool.isEmpty)
            #expect(!entry.repo.isEmpty)
            #expect(!entry.installCommand.isEmpty)
            #expect(!entry.adds.isEmpty)
            #expect(!entry.vetting.isEmpty)
            // The install command names its fetch source, so the owner runs it alone.
            #expect(
                entry.installCommand.contains("install")
                    || entry.installCommand.contains("-g") || entry.installCommand.contains("brew"))
        }
    }

    @Test func schemaIsStableAcrossDecoding() throws {
        // The entry was deliberately Codable so a shipped JSON can replace the compiled
        // list later; a round-trip through the encoder guards the values it carries.
        for entry in AppToolCatalog.entries {
            let data = try JSONEncoder().encode(entry)
            let back = try JSONDecoder().decode(AppToolCatalogEntry.self, from: data)
            #expect(back == entry)
        }
    }

    @Test func mailAppCliIsTheFirstEntryAndMentionsMail() {
        let first = try! #require(AppToolCatalog.entries.first)
        #expect(first.tool == "mail-app-cli")
        #expect(first.bundleIds.contains("com.apple.mail"))
        #expect(first.adds.contains("archive"))
    }

    // MARK: - Lookup

    @Test func suggestionsResolveByBundleIdAndIgnoreUnknownApps() {
        #expect(AppToolCatalog.suggestions(forBundleId: "com.apple.mail").count == 1)
        #expect(AppToolCatalog.suggestions(forBundleId: "COM.APPLE.MAIL").count == 1)
        #expect(AppToolCatalog.suggestions(forBundleId: "org.example.unrelated").isEmpty)
    }

    // MARK: - The card's words

    @Test func cardLineNamesToolWhatItAddsAndTheRuleThatDoraxNeverInstalls() {
        let lines = AppToolCatalog.suggestionLines(
            forBundleId: "com.apple.mail", appName: "Mail")
        #expect(lines.count == 1)
        let line = try! #require(lines.first)
        #expect(line.contains("mail-app-cli"))
        #expect(line.contains("intelligrit/mail-app-cli"))
        #expect(line.contains("go install"))
        #expect(line.contains("DoraX never installs"))
        #expect(line.contains("writes ask first"))
    }

    @Test @MainActor func unknownToolIsNotReportedInstalled() {
        let seen = AppToolCatalog.isInstalled("definitely-not-a-real-cli-xyz")
        #expect(seen.installed == false)
        #expect(seen.scanned == false)
    }

    @Test @MainActor
    func cardForMailNamesTheEntryAndTheFallbackSaysTheMenuPath() {
        let card = AppToolCatalog.noRouteCard(
            forBundleId: "com.apple.mail", appName: "Mail")
        #expect(card.rows.count == 1)
        let row = try! #require(card.rows.first)
        #expect(row.tool == "mail-app-cli")
        #expect(row.repo == "intelligrit/mail-app-cli")
        #expect(row.installCommand.contains("go install"))
        #expect(!row.scanned || row.installed)
        #expect(
            card.fallback.contains("menus") || card.fallback.contains("menu path"),
            "the fallback must always name the slower menu path, never silence")
    }

    @Test @MainActor func cardForAnUnlistedAppIsEmptyAndHonest() {
        let card = AppToolCatalog.noRouteCard(
            forBundleId: "org.example.unrelated", appName: "SomethingElse")
        #expect(card.rows.isEmpty)
        #expect(card.fallback.contains("No vetted tool"))
    }
}
