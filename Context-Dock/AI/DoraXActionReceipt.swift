// DoraXActionReceipt.swift
// Context-Dock
//
// One record of machine work: what ran, what came back, whether it passed, and whether
// it was the action or the check on the action.
//
// This shape was declared three times. TaskRunStore persisted it, GeneralChatWorkflowResult
// carried it between orchestration and presentation, and EvidenceReceipt drew it — and that
// last one, the copy the other two were written to match, lived in a SwiftUI view file. The
// receipt is what a surface shows the user when it claims something happened, so its shape
// was being decided by whichever layer happened to need it next.
//
// Field names follow the persisted form, because runs already on disk are decoded against
// them. `id` is deliberately outside CodingKeys: it identifies an instance for a ForEach,
// not a row in a file, and older run files never wrote one.
//
// Equality is content equality. Two receipts describing the same command and the same
// observation are the same receipt, whichever instance is holding them.

import Foundation

struct DoraXActionReceipt: Codable, Equatable, Identifiable {
    let id = UUID()
    /// What ran, as written — `run_command(…)`, `route(menuCommand, …)`, `verify_app_state(…)`.
    let command: String
    /// What came back. May be empty; use `observation` to draw it.
    let output: String
    let success: Bool
    /// True when this receipt is the read-back rather than the action it checked.
    let isVerification: Bool
    let recordedAt: Date

    private enum CodingKeys: String, CodingKey {
        case command, output, success, isVerification, recordedAt
    }

    init(
        command: String,
        output: String,
        success: Bool,
        isVerification: Bool = false,
        recordedAt: Date = Date()
    ) {
        self.command = command
        self.output = output
        self.success = success
        self.isVerification = isVerification
        self.recordedAt = recordedAt
    }

    /// Deliberately single-argument: call sites map a run of executed commands straight
    /// through it (`executed.map(DoraXActionReceipt.init)`), and a defaulted second
    /// parameter cannot be referenced that way.
    init(_ executed: AIProviderService.ExecutedCommand) {
        self.init(
            command: executed.command,
            output: executed.output,
            success: executed.success,
            isVerification: executed.isVerification)
    }

    /// Output with something to show when the command printed nothing. A blank line under a
    /// green tick reads as a rendering bug rather than as a command that succeeded quietly.
    var observation: String { output.isEmpty ? "No output" : output }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.command == rhs.command
            && lhs.output == rhs.output
            && lhs.success == rhs.success
            && lhs.isVerification == rhs.isVerification
            && lhs.recordedAt == rhs.recordedAt
    }
}
