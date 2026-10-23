// AppDictionaryRegistrationTests.swift
// Context-DockTests
//
// How the dictionary rung surfaces (P13 #208): `dict.query.<bundleID>`,
// `dict.modify.<bundleID>`, and one capability per learned command — registered off the
// store on every preflight, only for an app the turn granted, and skipped for an app a
// built-in adapter already serves, so the rung never stands in Mail's, Messages' or
// Music's way (plan §2c). Registration touches only in-memory state; no scan, no sdef, no
// Apple Event — offline.

import Foundation
import Testing
@testable import Context_Dock

@MainActor
@Suite
struct AppDictionaryRegistrationTests {

    /// A bundle id no fixture of ours collides with and no installed app owns.
    private static let testBundleID = "com.dictrung.testapp"
    /// The prefixes registration and the fake adapter use, for clean-up between tests.
    private static let registryPrefixes = [
        "dict.query.", "dict.modify.", "dict.command.", "dict.outbound.", "test.adapter.",
    ]

    private func learnedManifest() -> AppScriptingDictionary {
        AppSdefParser.parse(
            AppScriptingDictionaryParserTests.spotifyExcerpt,
            bundleID: Self.testBundleID, appName: "DictApp", version: "1")
    }

    private func reset() {
        for prefix in Self.registryPrefixes {
            CapabilityRegistry.shared.removeCapabilities(withPrefixes: [prefix])
        }
        AppDictionaryCapabilities.setActiveGrants([])
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: nil)
    }

    // MARK: The grant boundary

    @Test func nothingIsRegisteredUntilTheTurnGrantsTheApp() throws {
        reset()
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: learnedManifest())

        AppDictionaryCapabilities.registerLearned(in: CapabilityRegistry.shared)

        // Discovery is not consent: a manifest on disk grants nothing.
        #expect(CapabilityRegistry.shared.capability(
            id: "dict.query." + Self.testBundleID) == nil)
        #expect(CapabilityRegistry.shared.capability(
            id: "dict.modify." + Self.testBundleID) == nil)
        #expect(!CapabilityRegistry.shared.capabilities(for: Self.testBundleID)
            .contains { $0.id.hasPrefix("dict.command.") })

        AppDictionaryCapabilities.setActiveGrants([Self.testBundleID])
        AppDictionaryCapabilities.registerLearned(in: CapabilityRegistry.shared)

        #expect(CapabilityRegistry.shared.capability(
            id: "dict.query." + Self.testBundleID) != nil)
        #expect(CapabilityRegistry.shared.capability(
            id: "dict.modify." + Self.testBundleID) != nil)
        reset()
    }

    // MARK: The pair and the per-command capabilities

    @Test func registersQueryModifyAndOneCapabilityPerCommand() throws {
        reset()
        AppDictionaryCapabilities.setActiveGrants([Self.testBundleID])
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: learnedManifest())

        AppDictionaryCapabilities.registerLearned(in: CapabilityRegistry.shared)

        let query = try #require(
            CapabilityRegistry.shared.capability(id: "dict.query." + Self.testBundleID))
        #expect(query.riskLevel == .low)
        #expect(query.needsRunningApp)
        // The rung runs itself, and the apps it exists for (Spotify, Things) have no
        // adapter — the chat hub filters app-owned capabilities on exactly that.
        #expect(query.runsWithoutAdapter)
        #expect(query.appBundleID == Self.testBundleID)
        #expect(query.inputSchema.fields.contains { $0.name == "class" })

        let modify = try #require(
            CapabilityRegistry.shared.capability(id: "dict.modify." + Self.testBundleID))
        #expect(modify.riskLevel == .medium)
        #expect(modify.needsRunningApp)
        #expect(modify.runsWithoutAdapter)
        // Commands have their own ids now; the modify card is set/make/delete only.
        #expect(!modify.inputSchema.fields.contains { $0.name == "command" })
        #expect(modify.inputSchema.fields.contains { $0.name == "verb" })

        // "pause" is one learned command with its own executable id.
        let pause = try #require(
            CapabilityRegistry.shared.capability(
                id: "dict.command." + Self.testBundleID + ".pause"))
        #expect(pause.appBundleID == Self.testBundleID)
        #expect(pause.needsRunningApp)
        #expect(pause.runsWithoutAdapter)
        #expect(pause.title.contains("Pause"))
        // A command with a named parameter cannot be typed yet, so it is not advertised.
        #expect(CapabilityRegistry.shared.capability(
            id: "dict.command." + Self.testBundleID + ".play-track") == nil)
        reset()
    }

    @Test func anOutboundCommandGetsItsOwnHighRiskCapability() throws {
        reset()
        // A minimal learned manifest whose one command the sdef classifies outbound. This
        // is the P6/P13 shape: an outbound command is represented, gated, not erased.
        var dictionary = learnedManifest()
        dictionary.commands = [
            ScriptingCommand(
                name: "send track", suite: "DictApp Suite", verbClass: .outbound,
                directType: "text", parameters: [], code: "send", eventClass: "dcta")
        ]
        AppDictionaryCapabilities.setActiveGrants([Self.testBundleID])
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: dictionary)

        AppDictionaryCapabilities.registerLearned(in: CapabilityRegistry.shared)

        let outbound = try #require(
            CapabilityRegistry.shared.capability(
                id: "dict.outbound." + Self.testBundleID + ".send-track"))
        #expect(outbound.riskLevel == .high)
        #expect(outbound.needsRunningApp)
        #expect(outbound.title.lowercased().contains("asks first"))
        #expect(outbound.inputSchema.fields.contains { $0.name == "value" })
        reset()
    }

    @Test func skipsAnAppTheAdapterRungAlreadyServes() throws {
        reset()
        AppDictionaryCapabilities.setActiveGrants([Self.testBundleID])
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: learnedManifest())
        // The fake stands for a built-in adapter: owned by the app the manifest targets.
        CapabilityRegistry.shared.register(
            AICapability(
                id: "test.adapter." + Self.testBundleID,
                title: "An adapter that already reads this app",
                appBundleID: Self.testBundleID,
                inputSchema: .init(fields: []),
                riskLevel: .low,
                executor: { (_: AICapabilityExecutionRequest) throws -> AICapabilityExecutionResult in
                    throw AICapabilityError.unknownCapability("never runs in tests")
                }))

        AppDictionaryCapabilities.registerLearned(in: CapabilityRegistry.shared)

        #expect(CapabilityRegistry.shared.capability(
            id: "dict.query." + Self.testBundleID) == nil)
        #expect(CapabilityRegistry.shared.capability(
            id: "dict.modify." + Self.testBundleID) == nil)
        #expect(!CapabilityRegistry.shared.capabilities(for: Self.testBundleID)
            .contains { $0.id.hasPrefix("dict.command.") })
        reset()
    }

    @Test func reregisteringDropsASinceRemovedManifest() throws {
        reset()
        AppDictionaryCapabilities.setActiveGrants([Self.testBundleID])
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: learnedManifest())
        AppDictionaryCapabilities.registerLearned(in: CapabilityRegistry.shared)

        // The manifest is gone (an unlearnable version, a store reset): the stale
        // capability must leave with it, not outlive the store.
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: nil)
        AppDictionaryCapabilities.registerLearned(in: CapabilityRegistry.shared)

        #expect(CapabilityRegistry.shared.capability(
            id: "dict.query." + Self.testBundleID) == nil)
        #expect(CapabilityRegistry.shared.capability(
            id: "dict.modify." + Self.testBundleID) == nil)
        #expect(!CapabilityRegistry.shared.capabilities(for: Self.testBundleID)
            .contains { $0.id.hasPrefix("dict.command.") })
        reset()
    }

    @Test func anEmptyManifestRegistersNothing() throws {
        reset()
        // Absence caching puts empty manifests in the store (a non-scriptable app);
        // the rung stays invisible for it.
        let empty = AppScriptingDictionary(
            bundleID: Self.testBundleID, appName: "DictApp", version: "1",
            parsedAt: Date(), classes: [], commands: [])
        AppDictionaryCapabilities.setActiveGrants([Self.testBundleID])
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: empty)

        AppDictionaryCapabilities.registerLearned(in: CapabilityRegistry.shared)

        #expect(CapabilityRegistry.shared.capability(
            id: "dict.query." + Self.testBundleID) == nil)
        #expect(CapabilityRegistry.shared.capability(
            id: "dict.modify." + Self.testBundleID) == nil)
        reset()
    }

    @Test func thePromptNamesRegisteredIdsAndTheirRequiredFields() throws {
        reset()
        AppDictionaryCapabilities.setActiveGrants([Self.testBundleID])
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: learnedManifest())
        AppDictionaryCapabilities.registerLearned(in: CapabilityRegistry.shared)

        let query = try #require(
            CapabilityRegistry.shared.capability(id: "dict.query." + Self.testBundleID))
        let modify = try #require(
            CapabilityRegistry.shared.capability(id: "dict.modify." + Self.testBundleID))
        let required = query.inputSchema.fields.filter(\.required).map(\.name)
        #expect(required == ["class"])
        #expect(modify.inputSchema.fields.filter(\.required).map(\.name) == ["verb", "class"])
        reset()
    }
}
