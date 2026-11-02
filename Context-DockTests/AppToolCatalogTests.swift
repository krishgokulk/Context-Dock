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

    @Test func allRemainingCoreSystemScopesResolveVettedSuggestions() {
        let expectedScopes: [(bundleId: String, tool: String)] = [
            ("com.apple.mail", "mail-app-cli"),
            ("com.apple.iCal", "ical-buddy"),
            ("com.apple.reminders", "reminders-cli"),
            ("com.apple.AddressBook", "contacts-cli"),
            ("com.apple.Music", "nowplaying-cli"),
            ("com.apple.Photos", "osxphotos"),
            ("com.apple.MobileSMS", "imessage-exporter"),
            ("com.apple.Safari", "browser-history"),
            ("com.apple.finder", "trash"),
            ("com.apple.Terminal", "tmux"),
        ]
        for scope in expectedScopes {
            let suggestions = AppToolCatalog.suggestions(forBundleId: scope.bundleId)
            #expect(!suggestions.isEmpty, "Scope \(scope.bundleId) should have curated suggestions")
            #expect(suggestions.contains(where: { $0.tool == scope.tool }),
                    "Scope \(scope.bundleId) should suggest \(scope.tool)")
        }
    }

    // MARK: - The card's words

    @Test @MainActor func cardLineNamesTheTruthfulInstallState() {
        let seen = AppToolCatalog.isInstalled("mail-app-cli")
        let lines = AppToolCatalog.suggestionLines(
            forBundleId: "com.apple.mail", appName: "Mail")
        #expect(lines.count == 1)
        let line = try! #require(lines.first)
        #expect(line.contains("mail-app-cli"))
        #expect(line.contains("intelligrit/mail-app-cli"))
        if seen.installed {
            // A tool already on the user's PATH must never be offered as something to
            // install again — the truthful turn says it is there and points to linking it.
            #expect(line.contains("ALREADY installed"))
            #expect(!line.contains("Install yourself"))
            #expect(line.contains("App Adapters"))
        } else {
            #expect(line.contains("go install"))
            #expect(line.contains("DoraX never installs"))
        }
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

    @Test @MainActor
    func cardsForRemainingCoreScopesContainCuratedRowsAndTruthfulFallback() {
        let scopes = [
            ("com.apple.iCal", "Calendar", "ical-buddy"),
            ("com.apple.reminders", "Reminders", "reminders-cli"),
            ("com.apple.AddressBook", "Contacts", "contacts-cli"),
            ("com.apple.Music", "Music", "nowplaying-cli"),
            ("com.apple.Photos", "Photos", "osxphotos"),
            ("com.apple.MobileSMS", "Messages", "imessage-exporter"),
            ("com.apple.Safari", "Safari", "browser-history"),
            ("com.apple.finder", "Finder", "trash"),
            ("com.apple.Terminal", "Terminal", "tmux"),
        ]
        for (bundleId, appName, expectedTool) in scopes {
            let card = AppToolCatalog.noRouteCard(forBundleId: bundleId, appName: appName)
            #expect(!card.rows.isEmpty, "Card for \(appName) should have rows")
            #expect(card.rows.contains(where: { $0.tool == expectedTool }),
                    "Card for \(appName) should contain \(expectedTool)")
            #expect(card.fallback.contains("menus") || card.fallback.contains("menu path"),
                    "Fallback for \(appName) should point to menu path")
        }
    }

    @Test @MainActor func cardForAnUnlistedAppIsEmptyAndHonest() {
        let card = AppToolCatalog.noRouteCard(
            forBundleId: "org.example.unrelated", appName: "SomethingElse")
        #expect(card.rows.isEmpty)
        #expect(card.fallback.contains("No vetted tool"))
    }
}
