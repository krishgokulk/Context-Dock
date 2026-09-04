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
}
