import Testing

@testable import Context_Dock

struct VSCodeExtensionsIntentTests {
    @Test func recognizesInstalledVSCodeExtensionInventory() {
        #expect(VSCodeExtensionsIntent.matches(
            "What are all extensions installed on VS Code?"))
    }

    @Test func doesNotClaimGenericContextDockExtensions() {
        #expect(!VSCodeExtensionsIntent.matches("List installed extensions"))
    }

    @Test func doesNotClaimExtensionInstallation() {
        #expect(!VSCodeExtensionsIntent.matches("Install the Python extension in VS Code"))
    }
}
