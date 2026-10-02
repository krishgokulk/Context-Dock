// AgentToolRegistry+OutboundGate.swift
// Context-Dock
//
// The registry half of the outbound gate (see OutboundGate.swift): classify a call, ask or
// refuse, and word the card. Split out of AgentToolRegistry.swift, which is already oversized;
// the per-turn record (`taint`) and the card's answerer (`approveOutbound`) live on the registry.

import Foundation

extension AgentToolRegistry {

    /// What the gate cannot know without the registry.
    var outboundLookups: OutboundGate.Lookups {
        OutboundGate.Lookups(
            adapterActionSendsData: { id in
                AppAdapterManager.shared.adapters
                    .lazy.compactMap { $0.actions.first(where: { $0.id == id }) }.first
                    .map { AppPack.sendsDataOut($0) }
            },
            route: { id in
                AgentToolRegistry.offeredRoute(id: id).map { ($0.kind.rawValue, $0.payload) }
            })
    }

    /// One line naming the call, shown on the card under the reason.
    static func outboundDescription(name: String, arguments: [String: Any]) -> String {
        let pick: String?
        switch name {
        case "read_url": pick = arguments["url"] as? String
        case "run_command", "spawn_worker": pick = arguments["command"] as? String
        case "run_shortcut": pick = arguments["name"] as? String
        case "compose_message": pick = arguments["recipient"] as? String
        case "run_menu_command": pick = arguments["path"] as? String
        case "run_capability": pick = arguments["capability_id"] as? String
        default: pick = nil
        }
        let detail = pick.map { String($0.prefix(200)) } ?? ""
        return detail.isEmpty ? name : "\(name): \(detail)"
    }

    /// THE choke point for outbound tools: every in-app turn (the Dock, the Corner and the Chat
    /// Window alike) reaches its tools through `dispatch`, and so does the MCP server's menu tool.
    /// Returns nil when the call may go ahead, or the result to hand the model instead.
    ///
    /// `attended` is the caller's own claim (an MCP caller that is not DoraX's own CLI turn is
    /// not); an unattended run in the current task refuses as well, the mechanism #117 added.
    func gateOutbound(
        target: OutboundGate.Target, what: String, turn: AgentTurnToken?,
        chatScope: GeneralChatScope?, attended: Bool = true
    ) async -> AgentToolResult? {
        let decision = OutboundGate.decide(
            taint: taint.taint(for: turn), target: target,
            typedHosts: taint.typedHosts(for: turn),
            attended: attended && !AICapabilityApprovalCenter.refusesEveryApprovalUnattended)
        switch decision {
        case .allow:
            return nil
        case .refuse(let reason):
            AICapabilityApprovalCenter.recordUnattendedRefusal(OutboundGate.approvalCapabilityID)
            return AgentToolResult(
                success: false,
                output: reason + " Say what you would have done and why it was held back.",
                displayCommand: "\(what) · held back")
        case .ask(let reason, _):
            let plan = OutboundGate.approvalPlan(reason: reason, what: what)
            if await approveOutbound(plan, chatScope) { return nil }
            var denied = AgentToolResult(
                success: false,
                output: "The user did not approve this: \(reason) Nothing ran. Say so and stop; "
                    + "do not try another route to the same destination.",
                displayCommand: "\(what) · declined")
            denied.deniedByUser = true
            return denied
        }
    }
}
