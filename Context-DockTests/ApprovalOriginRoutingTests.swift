import Testing
@testable import Context_Dock

@Suite("Approval origin routing")
@MainActor
struct ApprovalOriginRoutingTests {
    @Test("Explicit General Chat ownership survives loss of key-window status")
    func explicitWindowOriginDoesNotDriftToDock() {
        let origin = TerminalAIBridge.resolveApprovalOrigin(
            explicit: .window,
            previewIsKey: false,
            generalChatIsKey: false
        )

        #expect(origin == .window)
    }

    @Test("Legacy callers retain key-window fallback")
    func legacyOriginFallback() {
        #expect(TerminalAIBridge.resolveApprovalOrigin(
            explicit: nil,
            previewIsKey: true,
            generalChatIsKey: false
        ) == .preview)
        #expect(TerminalAIBridge.resolveApprovalOrigin(
            explicit: nil,
            previewIsKey: false,
            generalChatIsKey: true
        ) == .window)
        #expect(TerminalAIBridge.resolveApprovalOrigin(
            explicit: nil,
            previewIsKey: false,
            generalChatIsKey: false
        ) == .dock)
    }
}
