// CapabilitiesSkillsBrowserTests.swift
// Context-DockTests
//
// Unit tests for Task UI/UX 5/5 (#335): Capabilities & Skills Browser.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Capabilities & Skills Browser (#335)", .serialized)
@MainActor
struct CapabilitiesSkillsBrowserTests {

    @Test("Pre-seeded SystemCommand and provider verification")
    func preSeededSystemCommand() {
        let cmd = SystemCommandsRegistry.shared.commands.first { $0.isCapabilitiesSkillsBoard }
        #expect(cmd != nil)
        #expect(cmd?.provider == CapabilitiesSkillsBrowser.provider)
        #expect(cmd?.name == "Capabilities & Skills")
        #expect(cmd?.hasOwnCornerBoard == true)
        #expect(cmd?.keywords.contains("skills") == true)
        #expect(cmd?.keywords.contains("capabilities") == true)
    }

    @Test("DockKeyMap binding registration for Capabilities & Skills Browser")
    func keyMapRegistration() {
        let allBindings = DockKeyMap.allBindings()
        let binding = allBindings.first { $0.id == "chat.capabilitiesSkillsBoard" }
        #expect(binding != nil)
        #expect(binding?.keys == ["⌥", "K"])
        #expect(binding?.title == "Capabilities & Skills Browser")
    }

    @Test("Browser items aggregation and filtering by tab")
    func itemsAggregationAndFiltering() {
        // Test with seed items
        let allItems = CapabilitiesSkillsBrowser.items(query: "", filter: .all)
        #expect(!allItems.isEmpty)

        // Capabilities tab should only include actions, system commands, and tools
        let capabilities = CapabilitiesSkillsBrowser.items(query: "", filter: .capabilities)
        for item in capabilities {
            #expect(item.kind == .appAction || item.kind == .systemCommand || item.kind == .mcpTool)
        }

        // Skills tab should only include authored / surface skills
        let skills = CapabilitiesSkillsBrowser.items(query: "", filter: .skills)
        for item in skills {
            #expect(item.kind == .skill)
        }

        // Learned tab should only include solved skills
        let learned = CapabilitiesSkillsBrowser.items(query: "", filter: .learned)
        for item in learned {
            #expect(item.kind == .solvedSkill)
        }
    }

    @Test("Query searching across title, app name, and keywords")
    func querySearching() {
        // Add a mock skill to test searching
        let testSkill = AdapterSkill(
            id: "test-skill-browser-123",
            adapterBundleId: "com.apple.mail",
            name: "Mail Digest Summarizer",
            summary: "Summarizes weekly unread newsletters and digests.",
            instructions: "Extract high-priority threads and present bullet points."
        )
        SkillStore.shared.upsert(testSkill)

        // Search by exact skill name
        let nameMatch = CapabilitiesSkillsBrowser.items(query: "Mail Digest Summarizer", filter: .skills)
        #expect(nameMatch.contains { $0.id == "skill.test-skill-browser-123" })

        // Search by instruction keyword
        let instructionMatch = CapabilitiesSkillsBrowser.items(query: "newsletters", filter: .skills)
        #expect(instructionMatch.contains { $0.id == "skill.test-skill-browser-123" })

        // Clean up
        SkillStore.shared.remove(id: "test-skill-browser-123")
    }

    @Test("Keyboard navigation moved helper")
    func movedNavigationHelper() {
        let ids = ["item-1", "item-2", "item-3"]

        // Moving down from item-1 -> item-2
        let next = CapabilitiesSkillsBrowser.moved(from: "item-1", in: ids, down: true)
        #expect(next == "item-2")

        // Moving down from item-3 -> item-3 (clamped at end)
        let clampedEnd = CapabilitiesSkillsBrowser.moved(from: "item-3", in: ids, down: true)
        #expect(clampedEnd == "item-3")

        // Moving up from item-2 -> item-1
        let prev = CapabilitiesSkillsBrowser.moved(from: "item-2", in: ids, down: false)
        #expect(prev == "item-1")

        // Moving up from item-1 -> item-1 (clamped at start)
        let clampedStart = CapabilitiesSkillsBrowser.moved(from: "item-1", in: ids, down: false)
        #expect(clampedStart == "item-1")

        // From nil -> first item
        let fromNil = CapabilitiesSkillsBrowser.moved(from: nil, in: ids, down: true)
        #expect(fromNil == "item-1")
    }
}
