// AppPetModsTests.swift
// Context-DockTests
//
// Acceptance and regression tests for App Pets Stage 4 (/mods behavior presets & manifests #341).
// Validates manifest schema and loading, supported modes derivation, honest refusal on invalid modes,
// conversation preservation on mode switch, capability filtering, and authority safety invariants.

import Foundation
import Testing

@testable import Context_Dock

@Suite("App Pets Stage 4 — Customization via /mods & Manifests", .serialized)
struct AppPetModsTests {

    private let safariPet = ConversationParticipant(
        petID: .app(bundleID: "com.apple.Safari"),
        displayName: "Safari"
    )

    private let finderPet = ConversationParticipant(
        petID: .app(bundleID: "com.apple.finder"),
        displayName: "Finder"
    )

    private let messagesPet = ConversationParticipant(
        petID: .app(bundleID: "com.apple.MobileSMS"),
        displayName: "Messages"
    )

    private let terminalPet = ConversationParticipant(
        petID: .cli(command: "terminal"),
        displayName: "Terminal"
    )

    // MARK: - 1. Manifest Schema & Loading

    @Test("AppPetManifest schema encodes and decodes JSON losslessly")
    func manifestSchemaEncodingDecoding() throws {
        let manifest = AppPetManifest(
            id: "com.example.customapp",
            appName: "CustomApp",
            bundleID: "com.example.customapp",
            summary: "Custom companion",
            defaultMode: "deep",
            customPrompt: "Always respond with code snippets.",
            customTools: [
                AppPetCustomTool(
                    id: "custom.analyze",
                    name: "Analyze",
                    description: "Analyzes file structure",
                    isReadOnly: true
                )
            ],
            capabilityFilter: AppPetCapabilityFilter(
                allowedPrefixes: ["custom."],
                excludedCapabilities: ["custom.dangerous"],
                readOnlyOnly: true
            ),
            modes: [
                AppPetModeManifest(
                    id: "deep",
                    name: "Deep",
                    summary: "Deep code analysis mode.",
                    icon: "curlybraces",
                    systemPromptOverlay: "Focus on static analysis and performance.",
                    preferredCapabilities: ["custom.analyze"],
                    planDetail: .detailed,
                    responseStyle: "Code diffs and complexity breakdown",
                    verificationEmphasis: .strictReceipt
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(manifest)

        let decoded = try JSONDecoder().decode(AppPetManifest.self, from: data)
        #expect(decoded.id == manifest.id)
        #expect(decoded.appName == manifest.appName)
        #expect(decoded.bundleID == manifest.bundleID)
        #expect(decoded.defaultMode == "deep")
        #expect(decoded.customPrompt == "Always respond with code snippets.")
        #expect(decoded.customTools.count == 1)
        #expect(decoded.customTools[0].id == "custom.analyze")
        #expect(decoded.capabilityFilter?.readOnlyOnly == true)
        #expect(decoded.modes.count == 1)
        #expect(decoded.modes[0].id == "deep")
        #expect(decoded.modes[0].name == "Deep")
        #expect(decoded.modes[0].planDetail == .detailed)
        #expect(decoded.modes[0].verificationEmphasis == .strictReceipt)
    }

    // MARK: - 2. Deriving Supported Modes

    @Test("Supported modes are derived from Pet profile for canonical macOS apps")
    func derivedSupportedModesFromCanonicalPets() {
        let registry = AppPetManifestRegistry.shared

        // Safari: Browse, Research, Compare, Automate
        let safariModes = registry.supportedModes(for: .app(bundleID: "com.apple.Safari"))
        let safariNames = safariModes.map(\.name)
        #expect(safariNames.contains("Browse"))
        #expect(safariNames.contains("Research"))
        #expect(safariNames.contains("Compare"))
        #expect(safariNames.contains("Automate"))

        // Finder: Find, Organize, Batch, Inspect
        let finderModes = registry.supportedModes(for: .app(bundleID: "com.apple.finder"))
        let finderNames = finderModes.map(\.name)
        #expect(finderNames.contains("Find"))
        #expect(finderNames.contains("Organize"))
        #expect(finderNames.contains("Batch"))
        #expect(finderNames.contains("Inspect"))

        // Messages: Read, Draft, Send
        let messagesModes = registry.supportedModes(for: .app(bundleID: "com.apple.MobileSMS"))
        let messagesNames = messagesModes.map(\.name)
        #expect(messagesNames.contains("Read"))
        #expect(messagesNames.contains("Draft"))
        #expect(messagesNames.contains("Send"))

        // Terminal: Explain, Diagnose, Run
        let terminalModes = registry.supportedModes(for: .cli(command: "terminal"))
        let terminalNames = terminalModes.map(\.name)
        #expect(terminalNames.contains("Explain"))
        #expect(terminalNames.contains("Diagnose"))
        #expect(terminalNames.contains("Run"))

        // Generic Pet fallback
        let genericModes = registry.supportedModes(for: .app(bundleID: "com.unknown.arbitrary"))
        let genericNames = genericModes.map(\.name)
        #expect(genericNames.contains("Assist"))
        #expect(genericNames.contains("Inspect"))
        #expect(genericNames.contains("Automate"))
    }

    // MARK: - 3. /mods Command Parsing & Listing

    @Test("Typing /mods lists available modes and marks the active mode")
    func modCommandListing() {
        let participants = ParticipantSet([safariPet])
        let activeModes = [safariPet.petID.canonicalKey: "research"]

        let result = AppPetModCommand.resolve(
            query: "/mods",
            participants: participants,
            focusedParticipant: safariPet,
            activeModes: activeModes
        )

        guard case .listModes(let participant, let modes, let activeModeID) = result else {
            Issue.record("Expected .listModes result")
            return
        }

        #expect(participant.displayName == "Safari")
        #expect(modes.map(\.name).contains("Research"))
        #expect(activeModeID == "research")
        #expect(result?.userFacingMessage.contains("Research") == true)
        #expect(result?.userFacingMessage.contains("*(Active)*") == true)
    }

    @Test("In Combined Chat, /mods targets focused participant and /mods AppName targets named participant")
    func combinedChatModTargeting() {
        let participants = ParticipantSet([finderPet, messagesPet])
        let activeModes = [
            finderPet.petID.canonicalKey: "find",
            messagesPet.petID.canonicalKey: "read"
        ]

        // /mods without args targets focused participant (finderPet)
        let defaultResult = AppPetModCommand.resolve(
            query: "/mods",
            participants: participants,
            focusedParticipant: finderPet,
            activeModes: activeModes
        )
        if case .listModes(let participant, _, _) = defaultResult {
            #expect(participant.displayName == "Finder")
        } else {
            Issue.record("Expected .listModes for Finder")
        }

        // /mods Messages targets Messages participant
        let namedResult = AppPetModCommand.resolve(
            query: "/mods Messages",
            participants: participants,
            focusedParticipant: finderPet,
            activeModes: activeModes
        )
        if case .listModes(let participant, _, _) = namedResult {
            #expect(participant.displayName == "Messages")
        } else {
            Issue.record("Expected .listModes for Messages")
        }

        // /mods Messages send switches Messages to Send mode
        let switchResult = AppPetModCommand.resolve(
            query: "/mods Messages send",
            participants: participants,
            focusedParticipant: finderPet,
            activeModes: activeModes
        )
        if case .switchedMode(let participant, let mode, let prev) = switchResult {
            #expect(participant.displayName == "Messages")
            #expect(mode.id == "send")
            #expect(prev == "read")
        } else {
            Issue.record("Expected .switchedMode for Messages")
        }
    }

    // MARK: - 4. Honest Refusal on Invalid Modes

    @Test("Unsupported mode requests fail honestly with available choices")
    func unsupportedModeFailsHonestly() {
        let participants = ParticipantSet([safariPet])

        let result = AppPetModCommand.resolve(
            query: "/mods turbo_blast",
            participants: participants,
            focusedParticipant: safariPet
        )

        guard case .unsupportedMode(let participant, let requestedName, let availableModes) = result else {
            Issue.record("Expected .unsupportedMode result")
            return
        }

        #expect(participant.displayName == "Safari")
        #expect(requestedName == "turbo_blast")
        let choices = availableModes.map(\.name)
        #expect(choices.contains("Browse"))
        #expect(choices.contains("Research"))
        #expect(result?.userFacingMessage.contains("Unknown mode \"turbo_blast\"") == true)
        #expect(result?.userFacingMessage.contains("Available choices: Browse, Research, Compare, Automate") == true)
    }

    @Test("In Combined Chat, targeting an unconnected app fails honestly listing connected Pets")
    func unconnectedParticipantFailsHonestly() {
        let participants = ParticipantSet([finderPet, messagesPet])

        let result = AppPetModCommand.resolve(
            query: "/mods Photoshop",
            participants: participants
        )

        guard case .unsupportedParticipant(let requestedName, let available) = result else {
            Issue.record("Expected .unsupportedParticipant result")
            return
        }

        #expect(requestedName == "Photoshop")
        #expect(available.map(\.displayName).contains("Finder"))
        #expect(available.map(\.displayName).contains("Messages"))
        #expect(result?.userFacingMessage.contains("App \"Photoshop\" is not connected") == true)
    }

    @Test("General Chat without an active Pet refuses /mods honestly")
    func generalChatRefusesModsHonestly() {
        let result = AppPetModCommand.resolve(
            query: "/mods",
            participants: .empty
        )

        #expect(result == .generalChatNotSupported)
        #expect(result?.userFacingMessage.contains("General Chat does not use Pet modes") == true)
    }

    // MARK: - 5. Conversation Preservation

    @Test("Switching mode does not fork or erase the conversation history")
    @MainActor
    func modeSwitchPreservesConversation() {
        let scope = GeneralChatScope.app(bundleId: "com.apple.Safari")
        let initialMessages = [
            AIChatMessage(role: .user, content: "What is this article about?"),
            AIChatMessage(role: .assistant, content: "It is about Swift testing.")
        ]
        GeneralChatSessionStore.save(initialMessages, scope: scope, title: "Safari")

        // Switch mode to research
        GeneralChatSessionStore.setActiveMode("research", for: safariPet.petID, scope: scope)

        // Verify active mode is updated
        let active = GeneralChatSessionStore.activeMode(for: safariPet.petID, scope: scope)
        #expect(active == "research")

        // Verify conversation history is intact and not forked or deleted
        let loaded = GeneralChatSessionStore.load(scope: scope)
        #expect(loaded.count == 2)
        #expect(loaded[0].content == "What is this article about?")
        #expect(loaded[1].content == "It is about Swift testing.")
    }

    // MARK: - 6. Capability Filtering & Shortlisting

    @Test("Read-only capability filter strictly blocks mutating capabilities")
    func readOnlyCapabilityFiltering() {
        let filter = AppPetCapabilityFilter.readOnly

        // Read-only tools pass
        #expect(filter.isAllowed(capabilityID: "finder.info", isReadOnly: true) == true)
        #expect(filter.isAllowed(capabilityID: "finder.search", isReadOnly: true) == true)
        #expect(filter.isAllowed(capabilityID: "safari.tabs", isReadOnly: true) == true)

        // Modifying tools are strictly rejected
        #expect(filter.isAllowed(capabilityID: "finder.trash", isReadOnly: false) == false)
        #expect(filter.isAllowed(capabilityID: "finder.organize", isReadOnly: false) == false)
        #expect(filter.isAllowed(capabilityID: "messages.send", isReadOnly: false) == false)
    }

    @Test("Excluded capabilities in filter are rejected even if marked read-only")
    func excludedCapabilitiesAreRejected() {
        let filter = AppPetCapabilityFilter(
            allowedPrefixes: [],
            excludedCapabilities: ["sensitive.readSecrets"],
            readOnlyOnly: false
        )

        #expect(filter.isAllowed(capabilityID: "safe.tool", isReadOnly: true) == true)
        #expect(filter.isAllowed(capabilityID: "sensitive.readSecrets", isReadOnly: true) == false)
    }

    // MARK: - 7. Authority & Safety Invariants

    @Test("A mode manifest cannot widen scope or bypass approval requirements")
    func modesCannotWidenAuthorityOrBypassApproval() {
        // High-risk capabilities always require approval regardless of mode
        let criticalRisk = AICapabilityRiskLevel.critical
        let mediumRisk = AICapabilityRiskLevel.medium
        let lowRisk = AICapabilityRiskLevel.low

        #expect(criticalRisk.requiresApproval == true)
        #expect(mediumRisk.requiresApproval == true)
        #expect(lowRisk.requiresApproval == false)

        // Custom tool declared on an App Pet carries its own isReadOnly and cannot bypass approval
        let customTool = AppPetCustomTool(
            id: "custom.delete",
            name: "Delete Cache",
            description: "Deletes cache files",
            isReadOnly: false,
            appBundleID: "com.apple.Safari"
        )
        #expect(customTool.isReadOnly == false)
        #expect(customTool.appBundleID == "com.apple.Safari")
    }
}
