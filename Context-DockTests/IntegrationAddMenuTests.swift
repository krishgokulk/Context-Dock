import Foundation
import Testing

@testable import Context_Dock

@Suite("Integration Add menu")
struct IntegrationAddMenuTests {
    @Test func appResourcesOfferOnlyAppResourceActions() {
        #expect(IntegrationAddAction.available(scope: .apps, tab: .resources) == [
            .addSkill, .addCLITool, .addMCPServer, .connectAPI, .linkShortcut
        ])
    }

    @Test func appActionsOfferActionCreationAndImport() {
        #expect(IntegrationAddAction.available(scope: .apps, tab: .actions) == [
            .addAction, .importIntegration
        ])
    }

    @Test func globalActionsOfferCommandsAndSelectionActions() {
        #expect(IntegrationAddAction.available(scope: .global, tab: .actions) == [
            .addCommand, .addSelectionAction
        ])
    }

    /// Skills and API connections are app-scoped authority. Offering them in Global would
    /// invite the user to create a capability with nothing to scope it to.
    ///
    /// MCP is absent for a different reason: `MCPServerManager` stores a server only as a
    /// link to an app, and drops it the moment its last link goes. There is nowhere for a
    /// global server to live, so the menu does not offer to create one.
    @Test func globalResourcesOfferOnlyWhatGlobalCanStore() {
        let actions = IntegrationAddAction.available(scope: .global, tab: .resources)
        #expect(actions == [.addCLITool])
        #expect(!actions.contains(.addSkill))
        #expect(!actions.contains(.connectAPI))
        #expect(!actions.contains(.addMCPServer))
    }

    @Test func appOverviewOffersAppChoiceAndImport() {
        #expect(IntegrationAddAction.available(scope: .apps, tab: .overview) == [
            .chooseApp, .importIntegration
        ])
    }

    @Test func everyScopeAndTabOffersAtLeastOneAction() {
        for scope in IntegrationScope.allCases {
            for tab in IntegrationDetailTab.allCases {
                #expect(!IntegrationAddAction.available(scope: scope, tab: tab).isEmpty)
            }
        }
    }
}
