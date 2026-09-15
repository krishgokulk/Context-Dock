// SkillFolderTests.swift
// Context-DockTests
//
// Skills as files. `AdapterSkill.fromSkillMarkdown` could always read a Claude-style
// SKILL.md; there was nowhere to put one, so a skill could not be version-controlled,
// shared, diffed or written by another agent — and DoraX shipped no written description of
// itself at all.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Skill folder")
@MainActor
struct SkillFolderTests {

    private let claudeStyle = """
        ---
        name: Release Checklist
        description: What to check before shipping a build
        metadata:
          version: "2.1"
        ---

        # Release Checklist

        1. Tests pass.
        2. The build number moved.
        """

    @Test("A Claude-style SKILL.md parses whole")
    func parsesFrontmatterAndBody() {
        let skill = SkillFolder.parse(claudeStyle, slug: "release-checklist")
        #expect(skill?.name == "Release Checklist")
        #expect(skill?.summary == "What to check before shipping a build")
        #expect(skill?.version == "2.1")
        #expect(skill?.instructions.contains("The build number moved") == true)
        // Frontmatter is metadata, not instructions.
        #expect(skill?.instructions.contains("description:") == false)
    }

    @Test("A file's id comes from its folder, so re-reading replaces rather than duplicates")
    func idIsStable() {
        let first = SkillFolder.parse(claudeStyle, slug: "release-checklist")
        let second = SkillFolder.parse(claudeStyle, slug: "release-checklist")
        #expect(first?.id == second?.id)
        #expect(first?.id == SkillFolder.stableID(forSlug: "release-checklist"))
        #expect(SkillFolder.isFileBacked(first!))
    }

    @Test("A skill with no bundle id belongs to DoraX, not to an app")
    func defaultsToGlobal() {
        let skill = SkillFolder.parse(claudeStyle, slug: "release-checklist")
        // Not a real bundle id: `instructionsBlock(for:)` is keyed by bundle id, so nothing
        // pastes these into a prompt wholesale. They are found and read on demand.
        #expect(skill?.adapterBundleId == SkillFolder.globalBundleID)
    }

    @Test("A skill can name the app it belongs to")
    func bundleIdFromFrontmatter() {
        let scoped = """
            ---
            name: Safari Habits
            description: How this user works in Safari
            bundle_id: com.apple.Safari
            ---

            Prefer reader mode.
            """
        #expect(SkillFolder.parse(scoped, slug: "safari-habits")?.adapterBundleId
            == "com.apple.Safari")
    }

    @Test("A file can switch itself off")
    func enabledIsRespected() {
        let off = """
            ---
            name: Draft Skill
            description: Not ready
            enabled: false
            ---

            Body.
            """
        #expect(SkillFolder.parse(off, slug: "draft")?.isEnabled == false)
        // Absent means on, the way every other skill defaults.
        #expect(SkillFolder.parse(claudeStyle, slug: "release-checklist")?.isEnabled == true)
    }

    @Test("A skill written out reads back the same")
    func exportRoundTrips() {
        let original = AdapterSkill(
            adapterBundleId: "com.apple.Safari",
            name: "Safari Habits",
            summary: "How this user works in Safari",
            instructions: "Prefer reader mode.",
            version: "1.4")

        let text = SkillFolder.markdown(for: original)
        let parsed = SkillFolder.parse(text, slug: "safari-habits")

        #expect(parsed?.name == original.name)
        #expect(parsed?.summary == original.summary)
        #expect(parsed?.version == original.version)
        #expect(parsed?.adapterBundleId == original.adapterBundleId)
        #expect(parsed?.instructions == original.instructions)
    }

    @Test("DoraX describes every surface it has")
    func everySurfaceIsWrittenDown() {
        let slugs = Set(DoraXSurfaceSkills.all.map(\.slug))
        // One per product layer, because CLAUDE.md's rule is that each keeps one job — and
        // a layer nobody wrote down is one a model has to infer.
        for expected in [
            "dorax-global-context", "dorax-context-dock-chat", "dorax-cli-tool-scope",
            "dorax-clipboard-scope", "dorax-selection-scope", "dorax-general-chat",
            "dorax-app-adapters",
        ] {
            #expect(slugs.contains(expected), "no skill describes \(expected)")
        }
    }

    @Test("Each built-in skill is a parseable SKILL.md")
    func builtInsAreValidSkills() {
        for seed in DoraXSurfaceSkills.all {
            guard let parsed = SkillFolder.parse(seed.markdown, slug: seed.slug) else {
                Issue.record("\(seed.slug) does not parse")
                continue
            }
            #expect(parsed.name == seed.name)
            #expect(parsed.summary == seed.description)
            #expect(!parsed.instructions.isEmpty)
            #expect(parsed.adapterBundleId == SkillFolder.globalBundleID)
        }
    }

    @Test("Names become folder slugs without collapsing into each other")
    func slugsAreUsable() {
        #expect(SkillFolder.slugify("Release Checklist") == "release-checklist")
        #expect(SkillFolder.slugify("Safari — page habits") == "safari-page-habits")
        #expect(SkillFolder.slugify("!!!") == "skill")
    }
}
