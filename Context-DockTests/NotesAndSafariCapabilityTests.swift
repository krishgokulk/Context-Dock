import Testing
import Foundation
@testable import Context_Dock

@MainActor
struct NotesAndSafariCapabilityTests {

    @Test func notesCapabilitiesIncludeRecentAndSearch() {
        let registry = CapabilityRegistry()
        AppleNotesMCPCapabilities.register(in: registry)

        let notesRecent = registry.capability(id: "notes.recent")
        #expect(notesRecent != nil)
        #expect(notesRecent?.appBundleID == "com.apple.Notes")
        #expect(notesRecent?.riskLevel == .low)

        let notesSearch = registry.capability(id: "notes.search")
        #expect(notesSearch != nil)
        #expect(notesSearch?.appBundleID == "com.apple.Notes")

        let notesCreate = registry.capability(id: "notes.create")
        #expect(notesCreate != nil)
        #expect(notesCreate?.riskLevel == .medium)

        let notesAppend = registry.capability(id: "notes.append")
        #expect(notesAppend != nil)
        #expect(notesAppend?.riskLevel == .medium)
    }

    @Test func safariCapabilitiesRegisteredCleanly() {
        let registry = CapabilityRegistry()
        AppleSafariMCPCapabilities.register(in: registry)

        let currentTab = registry.capability(id: "safari.currentTab")
        #expect(currentTab != nil)
        #expect(currentTab?.appBundleID == "com.apple.Safari")
        #expect(currentTab?.riskLevel == .low)

        let pageContent = registry.capability(id: "safari.pageContent")
        #expect(pageContent != nil)
        #expect(pageContent?.appBundleID == "com.apple.Safari")
        #expect(pageContent?.riskLevel == .low)

        let listTabs = registry.capability(id: "safari.listTabs")
        #expect(listTabs != nil)
        #expect(listTabs?.appBundleID == "com.apple.Safari")
        #expect(listTabs?.riskLevel == .low)

        let switchTab = registry.capability(id: "safari.switchTab")
        #expect(switchTab != nil)
        #expect(switchTab?.appBundleID == "com.apple.Safari")
        #expect(switchTab?.riskLevel == .low)
    }
}
