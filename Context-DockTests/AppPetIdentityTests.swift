import Foundation
import Testing

@testable import Context_Dock

@Suite("App Pet identity")
struct AppPetIdentityTests {
    @Test("App bundle IDs round-trip between AppPetID and GeneralChatScope.app")
    func appBundleIDRoundTrips() {
        let pet = AppPetID.app(bundleID: "com.apple.Safari")
        #expect(pet.bundleID == "com.apple.Safari")
        #expect(pet.cliCommand == nil)
        #expect(pet.dockBundleID == "com.apple.Safari")

        let scope = GeneralChatScope(petID: pet)
        #expect(scope == .app(bundleId: "com.apple.Safari"))
        #expect(scope.petID == pet)
        #expect(AppPetID(dockBundleID: "com.apple.Safari") == pet)
    }

    @Test("CLI commands normalize exactly as GeneralChatScope.cli storage does")
    func cliCommandNormalizes() {
        let pet = AppPetID.cli(command: "  Brew  ")
        #expect(pet.cliCommand == "brew")
        #expect(pet.bundleID == nil)
        #expect(pet.dockBundleID == "cli://brew")

        let scope = GeneralChatScope(petID: pet)
        #expect(scope == .cli(command: "brew"))
        #expect(scope.petID == .cli(command: "brew"))
        #expect(GeneralChatScope.cli(command: "BREW").petID == .cli(command: "brew"))
        #expect(AppPetID(dockBundleID: "cli://BREW") == .cli(command: "brew"))
    }

    @Test("Empty app bundle IDs and CLI commands are rejected from dockBundleID")
    func emptyIdentifiersAreRejected() {
        #expect(AppPetID(dockBundleID: nil) == nil)
        #expect(AppPetID(dockBundleID: "") == nil)
        #expect(AppPetID(dockBundleID: "   ") == nil)
        #expect(AppPetID(dockBundleID: "cli://") == nil)
        #expect(AppPetID(dockBundleID: "cli://   ") == nil)
        #expect(GeneralChatScope.app(bundleId: "").petID == nil)
        #expect(GeneralChatScope.cli(command: "   ").petID == nil)
    }

    @Test(".general, .thread and .folder are not Pets")
    func nonPetScopesReturnNil() {
        #expect(GeneralChatScope.general.petID == nil)
        #expect(GeneralChatScope.thread(id: "abc").petID == nil)
        #expect(GeneralChatScope.thread(id: "combined-123").petID == nil)
        #expect(GeneralChatScope.folder(path: "/Users/test/Documents").petID == nil)
    }

    @Test("Storage keys and dock panel keys remain compatible with existing app and CLI conversations")
    func storageKeysRemainCompatible() {
        let appScope = GeneralChatScope(petID: .app(bundleID: "com.apple.mail"))
        #expect(appScope.storageKey == "app:com.apple.mail")
        #expect(GeneralChatSessionStore.dockPanelKey(appScope) == "dock_app_com.apple.mail")

        let cliScope = GeneralChatScope(petID: .cli(command: "gh"))
        #expect(cliScope.storageKey == "cli:gh")
        #expect(GeneralChatSessionStore.dockPanelKey(cliScope) == "dock_app_cli://gh")
    }
}
