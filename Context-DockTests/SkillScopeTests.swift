// SkillScopeTests.swift
// Context-DockTests
//
// A skill's audience. `adapterBundleId` was required, so every skill belonged to an installed
// app and the surfaces the user spends most time in — Global Context, the corner chat, a CLI
// scope, clipboard, selection, General Chat — could not have one. These pin the three scopes
// apart, because the whole value of the scope is that a clipboard rule does not steer a Safari
// chat.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Skill scope")
@MainActor
struct SkillScopeTests {

    @Test("A file naming a surface steers that surface and no app")
    func surfaceFromFrontmatter() {
        let text = """
            ---
            name: Clipboard Habits
            description: How this user works with copied text
            surface: clipboard
            ---

            Prefer the newest clip.
            """
        let skill = SkillFolder.parse(text, slug: "clipboard-habits")

        #expect(skill?.scope == .surface(.clipboardScope))
        #expect(skill?.steers(.clipboardScope) == true)
        #expect(skill?.steers(.generalChat) == false)
    }

    /// `surface: clipboard` and `surface: Clipboard Scope` are the same request. A canonical
    /// id is what gets stored either way, so the file is forgiving and the store is not.
    @Test("Surface names are taken loosely and stored canonically")
    func surfaceNamesAreLoose() {
        #expect(DoraXSurface(loose: "clipboard") == .clipboardScope)
        #expect(DoraXSurface(loose: "Clipboard Scope") == .clipboardScope)
        #expect(DoraXSurface(loose: "corner") == .contextDockChat)
        #expect(DoraXSurface(loose: "cli") == .cliScope)
        #expect(DoraXSurface(loose: "kitchen sink") == nil)
    }

    /// An unrecognised surface leaves the skill global rather than guessing at the nearest
    /// one — steering a layer the author did not name is worse than steering none.
    @Test("An unrecognised surface is ignored, not guessed")
    func unknownSurfaceFallsBackToGlobal() {
        let text = """
            ---
            name: Mystery
            description: Written for a surface that does not exist
            surface: hovercraft
            ---

            Do the thing.
            """
        let skill = SkillFolder.parse(text, slug: "mystery")

        #expect(skill?.surfaceId.isEmpty == true)
        #expect(skill?.scope == .global)
    }

    @Test("An app skill steers its app and no surface; a global skill steers every surface")
    func theThreeScopesStayApart() {
        let appSkill = AdapterSkill(
            adapterBundleId: "com.apple.Safari", name: "Safari Habits",
            instructions: "Prefer reader mode.")
        let globalSkill = AdapterSkill(
            adapterBundleId: SkillFolder.globalBundleID, name: "House Style",
            instructions: "Be brief.")

        #expect(appSkill.scope == .app(bundleId: "com.apple.Safari"))
        #expect(globalSkill.scope == .global)
        for surface in DoraXSurface.allCases {
            #expect(!appSkill.steers(surface), "an app skill must not steer \(surface.rawValue)")
            #expect(globalSkill.steers(surface), "a global skill steers every surface")
        }
    }

    /// A surface skill carries whatever bundle id it was exported with. The surface is what
    /// the author asked for, so it must not also show up in that app's own skill list.
    @Test("A surface skill is not listed as one of an app's own")
    func aSurfaceSkillIsNotAnAppSkill() {
        let skill = AdapterSkill(
            adapterBundleId: "com.apple.Safari", name: "Clipboard Habits",
            instructions: "Prefer the newest clip.", surfaceId: DoraXSurface.clipboardScope.rawValue)

        #expect(skill.scope == .surface(.clipboardScope))
        #expect(!skill.steers(.contextDockChat))
    }

    /// The store on disk predates `surfaceId`. A throw here is not one missing field — it is
    /// every skill the user has written, gone at launch.
    @Test("Skills saved before scopes existed still decode, as app skills")
    func decodingIsBackwardCompatible() throws {
        let legacy = """
            {
              "id": "abc",
              "adapterBundleId": "com.apple.Safari",
              "name": "Safari Habits",
              "summary": "How this user works in Safari",
              "instructions": "Prefer reader mode.",
              "version": "1.0",
              "isEnabled": true,
              "updatedAt": "2026-01-01T00:00:00Z"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let skill = try decoder.decode(AdapterSkill.self, from: Data(legacy.utf8))

        #expect(skill.surfaceId.isEmpty)
        #expect(skill.scope == .app(bundleId: "com.apple.Safari"))
    }

    @Test("The surface written in a file survives a round trip through the folder format")
    func surfaceSurvivesExport() {
        let skill = AdapterSkill(
            adapterBundleId: SkillFolder.globalBundleID, name: "Clipboard Habits",
            summary: "How this user works with copied text",
            instructions: "Prefer the newest clip.",
            surfaceId: DoraXSurface.clipboardScope.rawValue)

        let reparsed = SkillFolder.parse(SkillFolder.markdown(for: skill), slug: "clipboard-habits")

        #expect(reparsed?.scope == .surface(.clipboardScope))
    }

    /// Each seeded skill describes one product layer, and CLAUDE.md's rule is that layers are
    /// never merged. Two seeds claiming the same surface would merge two in the prompt.
    @Test("Every seeded skill names a surface, and no two name the same one")
    func seedsCoverEachSurfaceOnce() {
        let surfaces = DoraXSurfaceSkills.all.map(\.surface)
        #expect(Set(surfaces).count == surfaces.count)
        #expect(Set(surfaces) == Set(DoraXSurface.allCases))

        for seed in DoraXSurfaceSkills.all {
            let parsed = SkillFolder.parse(seed.markdown, slug: seed.slug)
            #expect(
                parsed?.scope == .surface(seed.surface),
                "\(seed.slug) does not parse back as \(seed.surface.rawValue)")
        }
    }

    /// The dock calls a CLI thread and an app chat by the same source. They are different
    /// surfaces with different rules, and the scope id is what tells them apart.
    @Test("A cli:// scope is the CLI surface, not an app chat")
    func cliScopeIsItsOwnSurface() {
        #expect(DoraXSurface(scopeBundleId: "cli://brew") == .cliScope)
        #expect(DoraXSurface(scopeBundleId: "com.apple.Safari") == .contextDockChat)
    }

    /// Where the surface a turn runs on comes from when the caller did not say. A source with
    /// no surface gets none rather than the nearest-looking one.
    @Test("A request's surface is explicit first, then its source, then nothing")
    func surfaceResolutionOrder() {
        var request = AIRequest(text: "hi", context: .none, source: .contextDock)
        #expect(AIProviderRouter.surface(for: request) == .contextDockChat)

        request.surface = .clipboardScope
        #expect(AIProviderRouter.surface(for: request) == .clipboardScope)

        #expect(
            AIProviderRouter.surface(
                for: AIRequest(text: "hi", context: .none, source: .globalContext))
                == .globalContext)
        #expect(
            AIProviderRouter.surface(
                for: AIRequest(text: "hi", context: .none, source: .workflow)) == nil)
    }

    /// The block is an index, not seven bodies. A surface skill describes a whole product
    /// layer, so pasting them in full is the prompt-bloat path scopes exist to avoid.
    @Test("A surface is told its skills' names and where to read them, not their bodies")
    func theSurfaceBlockIsAnIndex() {
        let store = SkillStore.shared
        let id = "test.surface.index.\(UUID().uuidString)"
        store.upsert(AdapterSkill(
            id: id, adapterBundleId: SkillFolder.globalBundleID, name: "Clipboard Habits",
            summary: "How this user works with copied text",
            instructions: "SECRET-BODY-MARKER: prefer the newest clip.",
            surfaceId: DoraXSurface.clipboardScope.rawValue))
        defer { store.remove(id: id) }

        let block = store.surfaceInstructionsBlock(for: .clipboardScope)

        #expect(block.contains("Clipboard Habits"))
        #expect(block.contains("How this user works with copied text"))
        #expect(block.contains("skills.read"))
        #expect(!block.contains("SECRET-BODY-MARKER"))
        // And nothing of it reaches a surface it was not written for.
        #expect(!store.surfaceInstructionsBlock(for: .generalChat).contains("Clipboard Habits"))
    }
}

// MARK: - Progressive disclosure
//
// `skills.list` / `skills.read` existed as capabilities — cheap, on demand — while
// `instructionsBlock(for:)` pasted every enabled body into the scoped prompt. So the
// prompt-bloat path was the live one and the progressive pair was decoration. These pin the
// default the other way round, and pin the one exception: a skill the user has pinned.

@Suite("Progressive skill disclosure")
@MainActor
struct SkillDisclosureTests {

    private func body(_ marker: String) -> String {
        "\(marker)\n" + String(repeating: "a long paragraph of skill instructions. ", count: 40)
    }

    private func skill(
        _ name: String, marker: String, bundleId: String, pinned: Bool = false
    ) -> AdapterSkill {
        AdapterSkill(
            id: "test.disclosure.\(name).\(UUID().uuidString)",
            adapterBundleId: bundleId, name: name,
            summary: "what \(name) is for", instructions: body(marker), isPinned: pinned)
    }

    @Test("An app's prompt block names its skills without carrying their bodies")
    func unpinnedSkillsCostANameAndASummary() {
        let store = SkillStore.shared
        let bundleId = "test.disclosure.\(UUID().uuidString)"
        let skills = [
            skill("Release Checklist", marker: "MARKER-ONE", bundleId: bundleId),
            skill("Review Habits", marker: "MARKER-TWO", bundleId: bundleId),
        ]
        skills.forEach(store.upsert)
        defer { skills.forEach { store.remove(id: $0.id) } }

        let block = store.instructionsBlock(for: bundleId)

        #expect(block.contains("Release Checklist"))
        #expect(block.contains("what Review Habits is for"))
        #expect(block.contains("skills.read"))
        #expect(!block.contains("MARKER-ONE"))
        #expect(!block.contains("MARKER-TWO"))
    }

    /// The measurable half of the claim: several skills enabled, and the prompt does not grow
    /// with their bodies.
    @Test("The block stays small as skills are added")
    func theBlockDoesNotGrowWithBodies() {
        let store = SkillStore.shared
        let bundleId = "test.disclosure.\(UUID().uuidString)"
        let skills = (1...5).map {
            skill("Skill \($0)", marker: "MARKER-\($0)", bundleId: bundleId)
        }
        skills.forEach(store.upsert)
        defer { skills.forEach { store.remove(id: $0.id) } }

        let block = store.instructionsBlock(for: bundleId)
        let bodyCharacters = skills.reduce(0) { $0 + $1.instructions.count }

        #expect(block.count < bodyCharacters / 2, "the index should cost a fraction of the bodies")
        for index in 1...5 { #expect(!block.contains("MARKER-\(index)")) }
    }

    @Test("A pinned skill's body is in force, and an unpinned one beside it is still only named")
    func pinningIsTheOptOut() {
        let store = SkillStore.shared
        let bundleId = "test.disclosure.\(UUID().uuidString)"
        let pinned = skill("House Style", marker: "PINNED-MARKER", bundleId: bundleId, pinned: true)
        let listed = skill("Release Checklist", marker: "LISTED-MARKER", bundleId: bundleId)
        [pinned, listed].forEach(store.upsert)
        defer { [pinned, listed].forEach { store.remove(id: $0.id) } }

        let block = store.instructionsBlock(for: bundleId)

        #expect(block.contains("PINNED-MARKER"))
        #expect(!block.contains("LISTED-MARKER"))
        #expect(block.contains("Release Checklist"))
    }

    /// Pinning is "always applies", not "applies everywhere". A pinned clipboard skill has no
    /// business in a Safari chat.
    @Test("A pinned skill still only applies inside its own scope")
    func pinningDoesNotEscapeTheScope() {
        let store = SkillStore.shared
        let pinnedSurfaceSkill = AdapterSkill(
            id: "test.disclosure.surface.\(UUID().uuidString)",
            adapterBundleId: SkillFolder.globalBundleID, name: "Clipboard Habits",
            summary: "how this user works with copied text",
            instructions: "PINNED-SURFACE-MARKER: prefer the newest clip.",
            surfaceId: DoraXSurface.clipboardScope.rawValue, isPinned: true)
        store.upsert(pinnedSurfaceSkill)
        defer { store.remove(id: pinnedSurfaceSkill.id) }

        #expect(
            store.surfaceInstructionsBlock(for: .clipboardScope)
                .contains("PINNED-SURFACE-MARKER"))
        #expect(
            !store.surfaceInstructionsBlock(for: .contextDockChat)
                .contains("PINNED-SURFACE-MARKER"))
        #expect(!store.instructionsBlock(for: "com.apple.Safari").contains("PINNED-SURFACE-MARKER"))
    }

    /// A pin set in Settings on a file-backed skill has to reach the file, or the next folder
    /// sync puts it straight back to what the file says.
    @Test("A pin survives the folder format")
    func pinRoundTripsThroughTheFile() {
        let skill = AdapterSkill(
            id: SkillFolder.stableID(forSlug: "house-style"),
            adapterBundleId: SkillFolder.globalBundleID, name: "House Style",
            summary: "how to write here", instructions: "Be brief.", isPinned: true)

        let markdown = SkillFolder.markdown(for: skill)
        #expect(markdown.contains("pinned: true"))
        #expect(SkillFolder.parse(markdown, slug: "house-style")?.isPinned == true)
        // And the default is off, so a file that says nothing is read on demand.
        #expect(SkillFolder.parse(
            """
            ---
            name: House Style
            description: how to write here
            ---

            Be brief.
            """, slug: "house-style")?.isPinned == false)
    }

    @Test("Pinning writes back to the file a file-backed skill came from")
    func slugIsRecoverableFromTheStableID() {
        #expect(SkillFolder.slug(forStableID: SkillFolder.stableID(forSlug: "house-style"))
            == "house-style")
    }
}
