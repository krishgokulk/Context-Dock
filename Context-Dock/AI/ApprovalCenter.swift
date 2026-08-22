// ApprovalCenter.swift
// Context-Dock
//
// One inbox for every decision the user is asked to make.
//
// There were three, each with its own publisher, its own risk scale and its own card:
// a shell command waited in TerminalAIBridge, a capability in
// AICapabilityApprovalCenter, a general app action in GeneralAIActionApprovalCenter, and
// an adapter action in AppAdapterManager. Every surface had
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
        case generalAction(GeneralAIActionApprovalCenter.PendingApproval)
        case adapter(AdapterActionRequest)
    }

    let id: String
    let kind: Kind
    /// "Run command?", "Move files into folders by kind or by month"
    let title: String
    /// Fact about the request that DoraX itself knows — which app it reaches, and nothing
    /// a requester wrote.
    let subtitle: String?
    /// The requester's own account of why, which on every AI path means a sentence the
    /// model composed.
    ///
    /// Held apart from `subtitle` because it used to share it. Asked "what's in my trash
    /// bin", the model called the Empty Trash capability with the explanation "List the
    /// contents of the trash bin", and the card printed that under the real title in the
    /// same grey the description would use. Two lines, two authors, one voice — and the
    /// line a user actually reads on a card said the opposite of what approving it did.
    ///
    /// It is still shown: a model's reason is worth reading. It is never shown unlabelled.
    let requesterClaim: String?
    /// The thing itself: the command line, the capability and its inputs, the action target.
    let body: String?
    let risk: ApprovalRisk
    /// Which surface raised it, for the surfaces that only answer for themselves.
    let origin: TerminalAIBridge.ApprovalOrigin?

    /// Who wrote the sentence in `requesterClaim`.
    enum Requester {
        /// A model composed it. Nothing checked it against what the action does.
        case assistant
        /// DoraX naming the app an action reaches. Not a claim about intent.
        case connectedApp

        /// How the sentence is introduced, so it can never be read as DoraX describing its
        /// own action.
        var attribution: String {
            switch self {
            case .assistant: return "The assistant's reason:"
            case .connectedApp: return "Requested for:"
            }
        }
    }

    /// The two AI paths ask in a model's words; an adapter action does not.
    static func requester(of kind: Kind) -> Requester {
        switch kind {
        case .capability, .generalAction, .command: return .assistant
        case .adapter: return .connectedApp
        }
    }

    static func claimAttribution(for kind: Kind) -> String {
        requester(of: kind).attribution
    }

    /// What a capability card shows as fact.
    ///
    /// The id leads deliberately. A title does not always identify the action: a Global
    /// Command's title is whatever the user named it, so one called "List Trash Contents"
    /// wrapping an empty-trash script reads as harmless in every line of the card except
    /// this one.
    static func capabilityBody(capabilityID: String, inputs: [String: String]) -> String {
        ([capabilityID] + inputs.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
            .joined(separator: "\n")
    }

    var approveTitle: String {
        switch kind {
        case .command: return "Approve & Run"
        case .capability, .generalAction, .adapter: return "Approve"
        }
    }
}

/// Where a decision can be answered. A command belongs to the surface that asked for it;
/// everything else belongs to whichever surface the user is actually looking at.
enum ApprovalSurface {
    case dock
    case chatWindow
    case preview
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
        GeneralAIActionApprovalCenter.shared.$pending
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
                subtitle: nil,
                requesterClaim: command.purpose.isEmpty ? nil : command.purpose,
                body: command.command,
                risk: ApprovalRisk(command.classification.riskLevel),
                origin: command.origin)
        }
        if let capability = AICapabilityApprovalCenter.shared.pending {
            return ApprovalRequest(
                id: "capability:\(capability.id)",
                kind: .capability(capability),
                title: capability.capability.title,
                subtitle: nil,
                requesterClaim: capability.plan.explanation.isEmpty
                    ? nil : capability.plan.explanation,
                body: ApprovalRequest.capabilityBody(
                    capabilityID: capability.capability.id, inputs: capability.plan.input),
                risk: ApprovalRisk(capability.capability.riskLevel),
                origin: nil)
        }
        if let action = GeneralAIActionApprovalCenter.shared.pending {
            let candidate = action.candidate
            var details: [String] = []
            if let menuPath = candidate.menuPath, !menuPath.isEmpty {
                details.append(menuPath.joined(separator: " → "))
            }
            details.append(contentsOf: candidate.inputValues.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" })
            return ApprovalRequest(
                id: "general-action:\(action.id.uuidString)",
                kind: .generalAction(action),
                title: candidate.title,
                subtitle: candidate.appName.map { "Run with \($0) via \(candidate.routeLabel)" }
                    ?? candidate.routeLabel,
                requesterClaim: nil,
                body: details.isEmpty ? nil : details.joined(separator: "\n"),
                risk: ApprovalRisk(candidate.riskLevel),
                origin: nil)
        }
        if let adapter = AppAdapterManager.shared.pendingApproval {
            return ApprovalRequest(
                id: "adapter:\(adapter.id)",
                kind: .adapter(adapter),
                title: adapter.action.name,
                subtitle: adapter.adapter.appName,
                requesterClaim: nil,
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
        case .generalAction:
            GeneralAIActionApprovalCenter.shared.resolve(.allowOnce)
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
        case .generalAction:
            GeneralAIActionApprovalCenter.shared.resolve(.cancel)
        case .adapter(let adapter):
            adapter.onDeny()
        }
    }

    /// The request this surface should draw, if any.
    ///
    /// The rule used to live in the dock as three near-identical onReceive blocks, each
    /// deciding for itself whether a chat surface was visible and whether to open a
    /// floating window instead. Every new surface had to reimplement it, and the preview
    /// got it wrong in two of three cases. It is one rule, so it lives in one place.
    func pending(for surface: ApprovalSurface) -> ApprovalRequest? {
        guard let request = pending else { return nil }

        // A command is answered where it was asked. Two conversations can be running at
        // once, and a card from one appearing in the other is someone else's question.
        if case .command = request.kind {
            switch (request.origin, surface) {
            case (.window, .chatWindow), (.dock, .dock), (.preview, .preview):
                return request
            default:
                return nil
            }
        }

        // Capabilities, general actions and adapter actions name no surface, so they go to the one in
        // front: the preview window if its assistant is open, then the chat window, then
        // the dock.
        return surface == frontmostSurface ? request : nil
    }

    /// Which surface a surface-less request belongs to right now.
    var frontmostSurface: ApprovalSurface {
        if PreviewController.shared.hasVisibleComposer { return .preview }
        if GeneralChatWindowController.shared.isVisible { return .chatWindow }
        return .dock
    }

    /// True when no in-app surface will draw the request, so the caller may fall back to
    /// its floating window rather than leaving the question unanswered.
    var needsFloatingWindow: Bool {
        guard let request = pending else { return false }
        if case .command = request.kind { return request.origin == nil }
        return frontmostSurface == .dock
    }

    /// Only offered when the request itself allows it — a destructive adapter action has
    /// no standing grant, and neither commands nor capabilities have one at all.
    func approveAlways(_ request: ApprovalRequest) -> (() -> Void)? {
        switch request.kind {
        case .generalAction:
            return { GeneralAIActionApprovalCenter.shared.resolve(.allowAlways) }
        case .adapter(let adapter):
            return adapter.onApproveAlways
        case .command, .capability:
            return nil
        }
    }
}
