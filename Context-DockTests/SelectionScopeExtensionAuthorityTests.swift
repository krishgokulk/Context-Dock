import Testing

@testable import Context_Dock

@Suite("Selection Scope extension authority")
struct SelectionScopeExtensionAuthorityTests {
    private func selectionExtension(
        triggers: [ExtensionTrigger] = [.always]
    ) -> ILExtension {
        ILExtension(
            name: "Test Selection Extension",
            description: "Contract fixture",
            layer: .l2_context,
            category: "shortcutSheet",
            triggers: triggers)
    }

    @Test("Always-triggered extensions still require a selected payload")
    func alwaysRequiresSelection() {
        #expect(
            !SelectionScopeExtensionPolicy.isEligible(
                selectionExtension(), context: .empty, filePaths: []))
    }

    @Test("Frozen file authority is used for discovery")
    func frozenFilesMakeFileExtensionEligible() {
        let ext = selectionExtension(triggers: [.fileType(["pdf"])])
        #expect(
            SelectionScopeExtensionPolicy.isEligible(
                ext, context: .empty, filePaths: ["/tmp/frozen-selection.pdf"]))
    }

    @Test("Execution resolves the same frozen files used by discovery")
    func frozenFilesOverrideStaleAXFiles() {
        var staleContext = AXContext.empty
        staleContext.selectedFilePaths = ["/tmp/live-after-dock-opened.txt"]
        let frozen = ["/tmp/original-selection.pdf"]

        #expect(
            SelectionScopeExtensionPolicy.resolvedFilePaths(
                context: staleContext, frozenFilePaths: frozen) == frozen)
    }

    @Test("Legacy activation falls back to frozen AX snapshot files")
    func axSnapshotIsCompatibilityFallback() {
        var context = AXContext.empty
        context.selectedFilePaths = ["/tmp/legacy-selection.txt"]

        #expect(
            SelectionScopeExtensionPolicy.resolvedFilePaths(
                context: context, frozenFilePaths: []) == context.selectedFilePaths)
    }
}
