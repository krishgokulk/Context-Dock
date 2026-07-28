import SwiftUI

/// Inline offer to close a capability gap: link an installed CLI to this app scope, or install
/// the tool that would make the request possible. Every path is one explicit press — the model
/// never grants itself a tool, and installing still goes through the normal command approval.
struct CapabilityGapCard: View {
    let gap: CapabilityGapService.Gap
    let isWorking: Bool
    let onPrimary: () -> Void
    let onDismiss: () -> Void

    private var title: String {
        switch gap.resolution {
        case .linkInstalledTool(_, let command, let appName):
            return "\(command) is installed but not available in \(appName)"
        case .installTool(let command, _, let appName):
            return "\(appName) has no tool for this — \(command) would do it"
        }
    }

    private var primaryLabel: String {
        switch gap.resolution {
        case .linkInstalledTool(_, let command, let appName):
            return "Link \(command) to \(appName)"
        case .installTool(_, let formula, _):
            return "Install \(formula) with Homebrew"
        }
    }

    private var primaryIcon: String {
        switch gap.resolution {
        case .linkInstalledTool: return "link"
        case .installTool: return "arrow.down.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(gap.rationale)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .installTool(_, let formula, _) = gap.resolution {
                Text("brew install \(formula)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                Button(action: onPrimary) {
                    HStack(spacing: 5) {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: primaryIcon).font(.system(size: 10, weight: .bold))
                        }
                        Text(isWorking ? "Working…" : primaryLabel)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                Button("Not now", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .disabled(isWorking)

                Spacer(minLength: 0)
            }
            Text("Granted for \(gap.appName) only. Commands still ask before they run.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.8)
        )
        .transition(.scale(scale: 0.95, anchor: .bottom).combined(with: .opacity))
    }
}
