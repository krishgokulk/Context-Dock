// CuratedSystemScopesRoutingTests.swift
// Context-DockTests
//
// Tests for curated tool capabilities, parameter schemas, and route fallback
// across all remaining core macOS system scopes (Task #205, Plan §6.2 & §6.3).

import Testing
import Foundation
@testable import Context_Dock

struct CuratedSystemScopesRoutingTests {

    // MARK: - AppPetManifest Canonical System Scopes

    @Test func defaultManifestsContainAllElevenCoreSystemScopes() {
        let manifests = AppPetManifestRegistry.defaultManifests
        #expect(manifests.count >= 11)

        let expectedBundleIDs: Set<String> = [
            "com.apple.Safari",
            "com.apple.finder",
            "com.apple.MobileSMS",
            "com.apple.Terminal",
            "com.apple.Notes",
            "com.apple.mail",
            "com.apple.iCal",
            "com.apple.reminders",
            "com.apple.AddressBook",
            "com.apple.Music",
            "com.apple.Photos"
        ]

        let actualBundleIDs = Set(manifests.map { $0.id })
        for expected in expectedBundleIDs {
            #expect(actualBundleIDs.contains(expected), "Missing default manifest for \(expected)")
        }
    }

    // MARK: - Calendar Routing & Parameter Schema

    @Test @MainActor func calendarRoutingExtractsParametersAccurately() {
        AppSettings.shared.calendarMCPEnabled = true
        CapabilityRegistry.shared.refreshBuiltInMCPs()

        let todayCandidates = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Calendar", bundleID: "com.apple.iCal", query: "what is on my calendar today")
        #expect(todayCandidates.count == 1)
        #expect(todayCandidates.first?.capabilityID == "calendar.today")

        let searchCandidates = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Calendar", bundleID: "com.apple.iCal", query: "search calendar for design sprint")
        #expect(searchCandidates.count == 1)
        #expect(searchCandidates.first?.capabilityID == "calendar.search")
        #expect(searchCandidates.first?.inputValues["query"] == "design sprint")

        let createCandidates = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Calendar", bundleID: "com.apple.iCal", query: "schedule meeting with Tim")
        #expect(createCandidates.count == 1)
        #expect(createCandidates.first?.capabilityID == "calendar.create")
        #expect(createCandidates.first?.inputValues["title"]?.contains("Tim") == true)
        #expect(createCandidates.first?.inputValues["startDate"] == "today")

        let deleteCandidates = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Calendar", bundleID: "com.apple.iCal", query: "delete event Team Sync")
        #expect(deleteCandidates.count == 1)
        #expect(deleteCandidates.first?.capabilityID == "calendar.delete")
        #expect(deleteCandidates.first?.inputValues["matchTitle"] == "Team Sync")
    }

    // MARK: - Contacts Routing & Parameter Schema

    @Test @MainActor func contactsRoutingExtractsParametersAccurately() {
        AppSettings.shared.contactsMCPEnabled = true
        CapabilityRegistry.shared.refreshBuiltInMCPs()

        let searchCandidates = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Contacts", bundleID: "com.apple.AddressBook", query: "find contact Steve")
        #expect(searchCandidates.count == 1)
        #expect(searchCandidates.first?.capabilityID == "contacts.search")
        #expect(searchCandidates.first?.inputValues["query"]?.caseInsensitiveCompare("Steve") == .orderedSame)

        let detailsCandidates = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Contacts", bundleID: "com.apple.AddressBook", query: "phone number of Alice")
        #expect(detailsCandidates.count == 1)
        #expect(detailsCandidates.first?.capabilityID == "contacts.details")
        #expect(detailsCandidates.first?.inputValues["name"] == "Alice")
    }

    // MARK: - Music Routing & Parameter Schema

    @Test @MainActor func musicRoutingExtractsParametersAccurately() {
        AppSettings.shared.musicMCPEnabled = true
        CapabilityRegistry.shared.refreshBuiltInMCPs()

        let nowPlaying = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Music", bundleID: "com.apple.Music", query: "what song is playing")
        #expect(nowPlaying.count == 1)
        #expect(nowPlaying.first?.capabilityID == "music.nowPlaying")

        let volume = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Music", bundleID: "com.apple.Music", query: "check music volume")
        #expect(volume.count == 1)
        #expect(volume.first?.capabilityID == "music.volume")
    }

    // MARK: - Photos Routing & Parameter Schema

    @Test @MainActor func photosRoutingExtractsParametersAccurately() {
        AppSettings.shared.photosMCPEnabled = true
        CapabilityRegistry.shared.refreshBuiltInMCPs()

        let recent = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Photos", bundleID: "com.apple.Photos", query: "show recent photos")
        #expect(recent.count == 1)
        #expect(recent.first?.capabilityID == "photos.recent")
        #expect(recent.first?.inputValues["limit"] == "10")

        let search = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Photos", bundleID: "com.apple.Photos", query: "photos of mountains")
        #expect(search.count == 1)
        #expect(search.first?.capabilityID == "photos.search")
        #expect(search.first?.inputValues["query"] == "mountains")
    }

    // MARK: - Messages Routing & Parameter Schema

    @Test @MainActor func messagesRoutingExtractsParametersAccurately() {
        AppSettings.shared.messagesMCPEnabled = true
        CapabilityRegistry.shared.refreshBuiltInMCPs()

        let top = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Messages", bundleID: "com.apple.MobileSMS", query: "who do i message most")
        #expect(top.count == 1)
        #expect(top.first?.capabilityID == "messages.topContacts")

        let search = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Messages", bundleID: "com.apple.MobileSMS", query: "search messages about lunch")
        #expect(search.count == 1)
        #expect(search.first?.capabilityID == "messages.search")
        #expect(search.first?.inputValues["query"] == "lunch")
    }

    // MARK: - Mail Routing & Parameter Schema

    @Test @MainActor func mailRoutingExtractsParametersAccurately() {
        AppSettings.shared.mailMCPEnabled = true
        CapabilityRegistry.shared.refreshBuiltInMCPs()

        let searchFrom = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Mail", bundleID: "com.apple.mail", query: "search mail from John today")
        #expect(searchFrom.count == 1)
        #expect(searchFrom.first?.capabilityID == "mail.search")
        #expect(searchFrom.first?.inputValues["sender"] == "John")
        #expect(searchFrom.first?.inputValues["day"] == "today")

        let unread = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Mail", bundleID: "com.apple.mail", query: "show unread emails")
        #expect(unread.count == 1)
        #expect(unread.first?.capabilityID == "mail.search")
        #expect(unread.first?.inputValues["unreadOnly"] == "true")
    }

    // MARK: - Finder Routing & Parameter Schema

    @Test @MainActor func finderRoutingExtractsParametersAccurately() {
        let summary = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Finder", bundleID: "com.apple.finder", query: "summarize folder")
        #expect(summary.count == 1)
        #expect(summary.first?.capabilityID == "finder.summarizeFolder")

        let grep = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Finder", bundleID: "com.apple.finder", query: "search in files for invoice")
        #expect(grep.count == 1)
        #expect(grep.first?.capabilityID == "finder.grepFiles")
        #expect(grep.first?.inputValues["query"] == "invoice")
    }

    // MARK: - Safari Routing & Parameter Schema

    @Test @MainActor func safariRoutingExtractsParametersAccurately() {
        let summarize = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Safari", bundleID: "com.apple.Safari", query: "summarize page")
        #expect(summarize.count == 1)
        #expect(summarize.first?.capabilityID == "safari.summarizePage")

        let findInPage = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Safari", bundleID: "com.apple.Safari", query: "find in page login")
        #expect(findInPage.count == 1)
        #expect(findInPage.first?.capabilityID == "browser.findInPage")
        #expect(findInPage.first?.inputValues["text"] == "login")
    }

    // MARK: - Terminal Routing & Parameter Schema

    @Test @MainActor func terminalRoutingExtractsParametersAccurately() {
        let run = AppAdapterCapabilityCatalog.registeredCandidates(
            appName: "Terminal", bundleID: "com.apple.Terminal", query: "run uptime")
        #expect(run.count == 1)
        #expect(run.first?.capabilityID == "terminal.runCommand")
        #expect(run.first?.inputValues["command"] == "uptime")
    }

    // MARK: - ChatRouteResolver First-Party Capability Routes

    @Test @MainActor func chatRouteResolverSurfacesFirstPartyCapabilities() async {
        AppSettings.shared.calendarMCPEnabled = true
        AppSettings.shared.musicMCPEnabled = true
        AppSettings.shared.contactsMCPEnabled = true
        CapabilityRegistry.shared.refreshBuiltInMCPs()

        let calendarRoutes = await ChatRouteResolver.routes(
            for: "today's events", bundleId: "com.apple.iCal", appName: "Calendar")
        #expect(calendarRoutes.contains(where: { $0.id == "capability:calendar.today" }))

        let musicRoutes = await ChatRouteResolver.routes(
            for: "what song is playing", bundleId: "com.apple.Music", appName: "Music")
        #expect(musicRoutes.contains(where: { $0.id == "capability:music.nowPlaying" }))

        let contactsRoutes = await ChatRouteResolver.routes(
            for: "search contacts", bundleId: "com.apple.AddressBook", appName: "Contacts")
        #expect(contactsRoutes.contains(where: { $0.id == "capability:contacts.search" }))
    }
}
