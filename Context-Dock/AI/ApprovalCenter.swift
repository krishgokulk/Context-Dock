// ApprovalCenter.swift
// Context-Dock
//
// One inbox for every decision the user is asked to make.
//
// There were three, each with its own publisher, its own risk scale and its own card:
// a shell command waited in TerminalAIBridge, a capability in
// AICapabilityApprovalCenter, an adapter action in AppAdapterManager. Every surface had
// to know all three existed and render all three, and the preview panel proved what
// happens when one is missed — "convert this to JPEG" sat spinning behind a question
// the user was never shown, because the surface watched one inbox and suppressed the
// windows for the other two.
//
// This does not move the continuations. Each center still owns the request it created
// and answers it; what is unified is what the surfaces see — one pending request, one
// risk scale, one pair of answers — so a new kind of approval cannot be invisible in a
// surface that forgot to subscribe to it.

import Combine
import Foundation
import SwiftUI

/// The three scales the app used, said once. A command's classifier counts five levels,
/// a capability declares four, an adapter action has none at all; what a person needs to
/// know is how much care this deserves.
enum ApprovalRisk: Int, Comparable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: ApprovalRisk, rhs: ApprovalRisk) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var tint: Color {
        switch self {
        case .low: return .secondary
        case .medium: return .orange
        case .high: return .red
        }
    }

    init(_ level: TerminalCommandClassifier.RiskLevel) {
        switch level {
        case .safe, .low: self = .low
        case .medium: self = .medium
        case .high, .critical: self = .high
        }
    }

    init(_ level: AICapabilityRiskLevel) {
        switch level {
        case .low: self = .low
        case .medium: self = .medium
        case .high, .critical: self = .high
        }
    }
}

/// What is being asked, in the terms a card needs: who wants what, how risky, and the
/// detail that lets the user judge it.
struct ApprovalRequest: Identifiable {
    enum Kind {
        case command(TerminalAIBridge.PendingCommand)
        case capability(AICapabilityApprovalCenter.PendingApproval)
        case adapter(AdapterActionRequest)
    }

    let id: String
    let kind: Kind
    /// "Run command?", "Move files into folders by kind or by month"
    let title: String
    /// Why it wants to, in the requester's words.
    let purpose: String?
    /// The thing itself: the command line, the plan's explanation, the action's target.
    let body: String?
    let risk: ApprovalRisk
    /// Which surface raised it, for the surfaces that only answer for themselves.
    let origin: TerminalAIBridge.ApprovalOrigin?

    var approveTitle: String {
        switch kind {
        case .command: return "Approve & Run"
        case .capability, .adapter: return "Approve"
        }
    }
}

@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    /// The decision waiting, whichever center is holding it. Only one is ever shown: two
    /// cards stacked is two questions competing for the same yes.
    @Published private(set) var pending: ApprovalRequest?

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Commands first, then capabilities, then adapters — the order they tend to
        // arrive in a single turn, so the answer the model is blocked on comes first.
        TerminalAIBridge.shared.$pendingApproval
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        AICapabilityApprovalCenter.shared.$pending
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        AppAdapterManager.shared.$pendingApproval
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// Recomputed rather than pushed: @Published notifies on willSet, so reading the
    /// three sources on the next runloop turn is what gets their settled values. Pushing
    /// the new value through would publish a request its own center has not stored yet.
    private func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = Self.currentRequest()
        }
    }

    private static func currentRequest() -> ApprovalRequest? {
        if let command = TerminalAIBridge.shared.pendingApproval {
            return ApprovalRequest(
                id: "command:\(command.command)",
                kind: .command(command),
                title: "Run command?",
                purpose: command.purpose.isEmpty ? nil : command.purpose,
                body: command.command,
                risk: ApprovalRisk(command.classification.riskLevel),
                origin: command.origin)
        }
        if let capability = AICapabilityApprovalCenter.shared.pending {
            return ApprovalRequest(
                id: "capability:\(capability.id)",
                kind: .capability(capability),
                title: capability.capability.title,
                purpose: capability.plan.explanation.isEmpty ? nil : capability.plan.explanation,
                body: capability.plan.input
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\n"),
                risk: ApprovalRisk(capability.capability.riskLevel),
                origin: nil)
        }
        if let adapter = AppAdapterManager.shared.pendingApproval {
            return ApprovalRequest(
                id: "adapter:\(adapter.id)",
                kind: .adapter(adapter),
                title: adapter.action.name,
                purpose: adapter.adapter.appName,
                body: nil,
                // An adapter action reaches into another app. Nothing here is a glance.
                risk: .medium,
                origin: nil)
        }
        return nil
    }

    // MARK: - Answering

    func approve(_ request: ApprovalRequest) {
        switch request.kind {
        case .command(let command):
            TerminalAIBridge.shared.approveCommand(command.command)
        case .capability:
            AICapabilityApprovalCenter.shared.approve()
        case .adapter(let adapter):
            adapter.onApprove()
        }
    }

    func deny(_ request: ApprovalRequest) {
        switch request.kind {
        case .command:
            TerminalAIBridge.shared.denyCommand()
        case .capability:
            AICapabilityApprovalCenter.shared.deny()
        case .adapter(let adapter):
            adapter.onDeny()
        }
    }

    /// Only offered when the request itself allows it — a destructive adapter action has
    /// no standing grant, and neither commands nor capabilities have one at all.
    func approveAlways(_ request: ApprovalRequest) -> (() -> Void)? {
        guard case .adapter(let adapter) = request.kind else { return nil }
        return adapter.onApproveAlways
    }
}
