import Testing
import Foundation
@testable import Context_Dock

// #307: a capability's real surface must reach the catalog record, so P7 ranking can cost a
// window-opening route above a headless one. Before this, every AICapability defaulted to
// .headless and the ranker could not tell them apart.

@Suite("AICapability surface → catalog record")
@MainActor
struct CapabilitySurfaceTests {

    private func capability(
        id: String, surface: CapabilityRecord.Surface, bringsAppForward: Bool = false
    ) -> AICapability {
        AICapability(
            id: id, title: id, appBundleID: nil,
            inputSchema: .init(fields: []), riskLevel: .low,
            bringsAppForward: bringsAppForward, surface: surface
        ) { _ in .init(success: true, output: "") }
    }

    @Test("A declared surface is carried onto the record")
    func declaredSurface() {
        let record = CapabilityCatalog.record(
            for: capability(id: "mail.createDraft", surface: .opensApp), appName: "Mail")
        #expect(record.surface == .opensApp)
    }

    @Test("A data capability stays headless")
    func headlessDefault() {
        let record = CapabilityCatalog.record(
            for: capability(id: "mail.search", surface: .headless), appName: "Mail")
        #expect(record.surface == .headless)
    }

    @Test("bringsAppForward upgrades a headless capability to opensApp")
    func bringsAppForwardUpgrades() {
        let record = CapabilityCatalog.record(
            for: capability(id: "menu.thing", surface: .headless, bringsAppForward: true),
            appName: "App")
        #expect(record.surface == .opensApp)
    }

    @Test("The shipped Mail composer capability opens a window, not headless")
    func shippedCreateDraftOpensApp() {
        let createDraft = CapabilityRegistry.shared.capability(id: "mail.createDraft")
        let surface = createDraft.map {
            CapabilityCatalog.record(for: $0, appName: "Mail").surface
        }
        #expect(surface == .opensApp)
    }
}
