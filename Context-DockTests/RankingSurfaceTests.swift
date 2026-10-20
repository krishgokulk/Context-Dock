import Testing
import Foundation
@testable import Context_Dock

// Plan §5: when more than one tool can do a job, the cheapest surface wins and the user is
// shown why. The canonical case is "archive the newest bank email": the built-in adapter has
// no archive, so the choice is a headless `mail-app-cli archive` vs the Message › Archive menu
// that opens the app. DoraX must keep and prefer the CLI, and say so.

@Suite("Tool ranking by surface (plan §5)")
@MainActor
struct RankingSurfaceTests {

    private let resolver = GeneralAIActionResolver.shared

    private func candidate(
        id: String, route: DoraXActionCandidate.ExecutionRoute,
        source: DoraXActionCandidate.Source, bundleID: String = "com.apple.mail",
        capabilityID: String? = nil, confidence: Double = 0.9
    ) -> DoraXActionCandidate {
        var c = DoraXActionCandidate(
            id: id, title: id, appName: "Mail", bundleID: bundleID,
            source: source, route: route, capabilityID: capabilityID,
            requiredInputs: [], riskLevel: .medium, confidence: confidence,
            permissionKey: id, debugReason: "test")
        c.operation = .execute
        return c
    }

    @Test("candidateSurface: route maps to cost, capability overrides")
    func surfaceMapping() {
        #expect(resolver.candidateSurface(
            candidate(id: "cli", route: .cli, source: .cli)) == .headless)
        #expect(resolver.candidateSurface(
            candidate(id: "menu", route: .verifiedMenu, source: .cachedMenu)) == .opensApp)
        #expect(resolver.candidateSurface(
            candidate(id: "ax", route: .axFallback, source: .system)) == .takesScreen)
        // A capability that declares .opensApp overrides the otherwise-headless route.
        #expect(resolver.candidateSurface(
            candidate(id: "mail.createDraft", route: .adapter, source: .appAdapter,
                capabilityID: "mail.createDraft")) == .opensApp)
    }

    @Test("A headless CLI survives a window-opening native route (archive)")
    func cliKeptAgainstMenu() {
        let menu = candidate(id: "menu.archive", route: .verifiedMenu, source: .cachedMenu)
        let cli = candidate(id: "cli.archive", route: .cli, source: .cli)
        let kept = resolver.productRouteFiltered([menu, cli])
        #expect(kept.contains { $0.id == "cli.archive" })
        #expect(kept.contains { $0.id == "menu.archive" })
    }

    @Test("A headless native adapter still supersedes a redundant CLI")
    func cliDroppedAgainstHeadlessAdapter() {
        let adapter = candidate(id: "adapter.flag", route: .adapter, source: .appAdapter)
        let cli = candidate(id: "cli.flag", route: .cli, source: .cli)
        let kept = resolver.productRouteFiltered([adapter, cli])
        #expect(kept.contains { $0.id == "adapter.flag" })
        #expect(!kept.contains { $0.id == "cli.flag" })
    }

    @Test("archive: the headless CLI ranks above the window-opening menu")
    func archivePrefersCLI() {
        let menu = candidate(id: "menu.archive", route: .verifiedMenu, source: .cachedMenu)
        let cli = candidate(id: "cli.archive", route: .cli, source: .cli)
        let ranked = resolver.rankedWithPreferences([menu, cli], intentKey: "mail.archive.test")
        #expect(ranked.first?.id == "cli.archive")
    }

    @Test("A window-opening adapter loses to a headless CLI (surface before reliability)")
    func headlessCLIBeatsWindowAdapter() {
        // messages.compose is an adapter-tier route but opens the Messages window (#307), so
        // §5.3 says a headless CLI for the same job wins despite the adapter's higher tier.
        let adapter = candidate(
            id: "messages.compose", route: .adapter, source: .appAdapter,
            bundleID: "com.apple.MobileSMS", capabilityID: "messages.compose")
        let cli = candidate(
            id: "cli.sms", route: .cli, source: .cli, bundleID: "com.apple.MobileSMS")
        #expect(resolver.candidateSurface(adapter) == .opensApp)
        let ranked = resolver.rankedWithPreferences([adapter, cli], intentKey: "sms.send.test")
        #expect(ranked.first?.id == "cli.sms")
    }
}
