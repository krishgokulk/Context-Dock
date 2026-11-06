import Testing
import Foundation
@testable import Context_Dock

// MARK: - evidence_sufficiency retry must not re-run write tools
//
// ScopedTurnRunner strips already-succeeded outbound tools from allowedToolNames
// before the evidence_sufficiency retry so the model cannot re-run a side-effectful
// action it already completed. The stripped set is derived from OutboundGate.outboundTools.
//
// Regression for: "open new session" fired run_menu_command twice because the
// evidence_sufficiency retry received the full allowedToolNames set and the model
// re-ran the same menu command to verify the paste that never happened.

struct EvidenceSufficiencyRetryToolsTests {

    // run_menu_command is the tool that caused the double-action; it must be in
    // OutboundGate.outboundTools for the fix to apply.
    @Test func runMenuCommandIsOutbound() {
        #expect(OutboundGate.outboundTools.contains("run_menu_command"))
    }

    // Other common write tools must also be in the set so the guard is broad enough.
    @Test func otherWriteToolsAreOutbound() {
        for name in ["run_capability", "run_adapter_action", "run_synthesized_script"] {
            #expect(OutboundGate.outboundTools.contains(name), "expected \(name) to be outbound")
        }
    }

    // The core fix: when run_menu_command ran successfully, it should be subtracted
    // from the retry's allowed set.
    @Test func succeededWriteToolIsRemovedFromRetrySet() {
        let executed = [
            AIProviderService.ExecutedCommand(command: "run_menu_command", output: "ok", success: true)
        ]
        let originalAllowed: Set<String> = [
            "run_menu_command", "ax_snapshot", "find_capability", "run_capability",
            "find_menu_command", "verify_outcome"
        ]

        let alreadyRanWrites = Set(executed.filter(\.success).map(\.command))
            .intersection(OutboundGate.outboundTools)
        let retryAllowedTools = alreadyRanWrites.isEmpty
            ? originalAllowed
            : originalAllowed.subtracting(alreadyRanWrites)

        #expect(!retryAllowedTools.contains("run_menu_command"),
            "run_menu_command must be blocked on retry after it ran")
        #expect(retryAllowedTools.contains("ax_snapshot"),
            "read-only tools must remain available for verification")
        #expect(retryAllowedTools.contains("find_capability"),
            "find tools must remain available for verification")
    }

    // A failed write action must NOT be subtracted — the model may need to retry it.
    @Test func failedWriteToolRemainsInRetrySet() {
        let executed = [
            AIProviderService.ExecutedCommand(command: "run_menu_command", output: "error", success: false)
        ]
        let originalAllowed: Set<String> = ["run_menu_command", "ax_snapshot"]

        let alreadyRanWrites = Set(executed.filter(\.success).map(\.command))
            .intersection(OutboundGate.outboundTools)
        let retryAllowedTools = alreadyRanWrites.isEmpty
            ? originalAllowed
            : originalAllowed.subtracting(alreadyRanWrites)

        #expect(retryAllowedTools.contains("run_menu_command"),
            "failed write tool must stay available so model can retry it")
    }

    // When NO write tools ran, allowedToolNames must pass through unchanged.
    @Test func noWriteActionsLeavesAllowedToolsUnchanged() {
        let executed = [
            AIProviderService.ExecutedCommand(command: "ax_snapshot", output: "{}", success: true)
        ]
        let originalAllowed: Set<String> = ["run_menu_command", "ax_snapshot", "find_capability"]

        let alreadyRanWrites = Set(executed.filter(\.success).map(\.command))
            .intersection(OutboundGate.outboundTools)
        let retryAllowedTools = alreadyRanWrites.isEmpty
            ? originalAllowed
            : originalAllowed.subtracting(alreadyRanWrites)

        #expect(retryAllowedTools == originalAllowed,
            "allowedToolNames must be unchanged when no write tools ran")
    }
}
