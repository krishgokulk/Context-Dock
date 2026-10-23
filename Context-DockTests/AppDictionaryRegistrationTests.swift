// AppDictionaryRegistrationTests.swift
// Context-DockTests
//
// How the dictionary rung surfaces (P13 #208): one `dict.query.<bundleID>` and one
// `dict.modify.<bundleID>` pair per learned app, registered off the store on every
// preflight — and skipped for an app a built-in adapter already serves, so the rung
// never stands in Mail's, Messages' or Music's way (plan §2c). The registration path
// touches only in-memory state; no scan, no sdef, no Apple Event — offline.

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
        "dict.query.", "dict.modify.", "test.adapter.",
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
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: nil)
    }

    // MARK: The pair

    @Test func registersQueryAndModifyForALearnedApp() throws {
        reset()
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
        reset()
    }

    @Test func skipsAnAppTheAdapterRungAlreadyServes() throws {
        reset()
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
        reset()
    }

    @Test func reregisteringDropsASinceRemovedManifest() throws {
        reset()
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
        reset()
    }

    @Test func anEmptyManifestRegistersNothing() throws {
        reset()
        // Absence caching puts empty manifests in the store (a non-scriptable app);
        // the rung stays invisible for it.
        let empty = AppScriptingDictionary(
            bundleID: Self.testBundleID, appName: "Dic珍App", version: "1",
            parsedAt: Date(), classes: [], commands: [])
        AppDictionaryStore.shared._injectForTesting(
            bundleID: Self.testBundleID, manifest: empty)

        AppDictionaryCapabilities.registerLearned(in: CapabilityRegistry.shared)

        #expect(CapabilityRegistry.shared.capability(
            id: "dict.query." + Self.testBundleID) == nil)
        #expect(CapabilityRegistry.shared.capability(
            id: "dict.modify." + Self.testBundleID) == nil)
        reset()
    }
}
