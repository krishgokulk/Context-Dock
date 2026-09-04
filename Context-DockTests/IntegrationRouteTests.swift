import Testing
@testable import Context_Dock

@Suite("Integration settings routing")
struct IntegrationRouteTests {
    @Test(arguments: [
        (SettingsPage.frontmostAppAdapters, IntegrationDestination(scope: .apps)),
        (SettingsPage.extensionsGlobalWithoutSelection, IntegrationDestination(scope: .global, tab: .actions, focus: .commands)),
        (SettingsPage.extensionsCLIToolScope, IntegrationDestination(scope: .global, tab: .resources, focus: .cliTools)),
        (SettingsPage.shortcutSheetWorkflows, IntegrationDestination(scope: .global, tab: .actions, focus: .selectionActions)),
    ])
    func legacyPageMapsToIntegration(
        page: SettingsPage,
        expected: IntegrationDestination
    ) {
        #expect(SettingsRouteResolver.destination(for: page) == expected)
    }

    @Test func ordinaryPageDoesNotInventIntegrationRoute() {
        #expect(SettingsRouteResolver.destination(for: .appearance) == nil)
    }

    @Test func appDeepLinkPreservesBundleAndTab() {
        let route = IntegrationDestination(
            scope: .apps,
            bundleID: "com.openai.codex",
            tab: .resources,
            focus: .mcpServers)
        let payload = SettingsRouteResolver.notificationPayload(for: route)

        #expect(payload["page"] as? String == SettingsPage.integrations.rawValue)
        #expect(SettingsRouteResolver.destination(from: payload) == route)
    }

    /// Anything that posted a legacy page before this workspace existed still lands in the
    /// right scope, so an old caller is never stranded on a page that no longer has a row.
    @Test func legacyRawValueStillResolves() {
        let payload: [AnyHashable: Any] = ["page": SettingsPage.frontmostAppAdapters.rawValue]
        #expect(SettingsRouteResolver.destination(from: payload)?.scope == .apps)
    }

    @Test func nonIntegrationPayloadResolvesToNoDestination() {
        let payload: [AnyHashable: Any] = ["page": SettingsPage.appearance.rawValue]
        #expect(SettingsRouteResolver.destination(from: payload) == nil)
    }

    @Test func payloadOmitsKeysItHasNoValueFor() {
        let payload = SettingsRouteResolver.notificationPayload(
            for: IntegrationDestination(scope: .global, tab: .actions))
        #expect(payload["bundleID"] == nil)
        #expect(payload["integrationFocus"] == nil)
    }
}
