import Foundation

/// What an AI provider can do in DoraX — declared at setup time, enforced by the host.
///
/// Tool calling ability (`supportsNativeTools`) tells you whether a provider understands
/// the function-calling wire format. Capability profile tells you what the provider is
/// *authorised* to do in this app: execute app actions, query data, or only answer.
///
/// Every provider declares its own profile; the host uses it to:
///   - filter which tool schemas are injected per turn
///   - decide whether to show the approval card
///   - surface the right UI tier label in Settings → AI Providers
///   - show a one-tap handoff when a mutation request arrives on a read-only provider
struct ProviderCapabilityProfile: Equatable, Sendable {
    /// May call capability-registry write/mutation tools (run_menu_command, etc.).
    let canExecuteActions: Bool

    /// May call readers, search, and inspection tools.
    let canReadData: Bool

    /// Host displays the approval card before executing a high-risk capability.
    let supportsApprovalFlow: Bool

    // MARK: - Well-known profiles

    /// Actions + reads + approval sheet.
    static let full = ProviderCapabilityProfile(
        canExecuteActions: true,
        canReadData: true,
        supportsApprovalFlow: true
    )

    /// Tool reads only, no mutation tools, no approval sheet needed.
    static let readOnly = ProviderCapabilityProfile(
        canExecuteActions: false,
        canReadData: true,
        supportsApprovalFlow: false
    )

    /// No tool calls at all — the provider answers from its own knowledge.
    static let answerOnly = ProviderCapabilityProfile(
        canExecuteActions: false,
        canReadData: false,
        supportsApprovalFlow: false
    )

    // MARK: - Tier

    /// User-visible capability tier shown in Settings → AI Providers.
    enum Tier: Equatable, Sendable {
        case full        // ✦ Actions + reads
        case readOnly    // ◎ Read only
        case answerOnly  // ○ Answer only

        var symbol: String {
            switch self {
            case .full: return "✦"
            case .readOnly: return "◎"
            case .answerOnly: return "○"
            }
        }

        var label: String {
            switch self {
            case .full: return "Full (actions + reads)"
            case .readOnly: return "Read only"
            case .answerOnly: return "Answer only"
            }
        }

        var shortLabel: String {
            switch self {
            case .full: return "Full"
            case .readOnly: return "Read"
            case .answerOnly: return "Answer"
            }
        }
    }

    var tier: Tier {
        if canExecuteActions { return .full }
        if canReadData { return .readOnly }
        return .answerOnly
    }
}
