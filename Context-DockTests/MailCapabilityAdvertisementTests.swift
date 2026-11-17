// MailCapabilityAdvertisementTests.swift
// Context-DockTests
//
// Issue #354 — chatGPTSubscription scoped turns produced an empty capability block for
// Mail-scoped chats.
//
// Root cause: mail MCP capabilities had no `runsWithoutAdapter` flag, so the filter in
// GeneralChatCapabilityHub.builtInCapabilityLines dropped them whenever no Mail App
// Adapter was installed. The model received zero tool instructions and answered directly.
//
// Fix: mark all mail MCP capabilities with `runsWithoutAdapter: true` — they execute
// through JXA/MailAutomation, not through an adapter.

import Testing
@testable import Context_Dock

@MainActor
struct MailCapabilityAdvertisementTests {

    // Mail capabilities present in the read-only / search family.
    private static let readIDs = [
        "mail.unread", "mail.search", "mail.recent", "mail.read", "mail.currentMessage",
    ]

    // MARK: - Struct property

    @Test("Mail MCP capabilities carry runsWithoutAdapter=true (Issue #354)")
    func mailCapabilitiesAreMarkedRunsWithoutAdapter() {
        // Register directly (bypassing the mailMCPEnabled settings gate) so this test is
        // self-contained and passes regardless of the user's Settings state.
        AppleMailMCPCapabilities.register(in: CapabilityRegistry.shared)
        for id in Self.readIDs {
            let cap = CapabilityRegistry.shared.capability(id: id)
            #expect(cap != nil)
            #expect(cap?.runsWithoutAdapter == true)
        }
    }

    // MARK: - Adapter filter

    @Test("Mail capabilities survive the adapter filter in a Mail-scoped chat without an adapter")
    func mailCapabilitiesSurviveAdapterFilterWithoutAdapter() {
        AppleMailMCPCapabilities.register(in: CapabilityRegistry.shared)
        let all = CapabilityRegistry.shared.all
        let inScope = AgentToolRegistry.capabilitiesInScope(
            all, scopedBundleID: "com.apple.mail")
        // Reproduce the filter from GeneralChatCapabilityHub.builtInCapabilityLines.
        // In the test host AppAdapterManager has no installed adapters, so only
        // capabilities marked runsWithoutAdapter=true survive.
        let advertised = Set(
            inScope
                .filter { cap in
                    guard let bundleID = cap.appBundleID else { return true }
                    if cap.runsWithoutAdapter { return true }
                    return AppAdapterManager.shared.adapter(for: bundleID) != nil
                }
                .map(\.id)
        )
        for id in Self.readIDs {
            #expect(advertised.contains(id))
        }
    }
}
