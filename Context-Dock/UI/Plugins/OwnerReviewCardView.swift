// Context-Dock/UI/Plugins/OwnerReviewCardView.swift
// Context-Dock
//
// Reusable owner approval surface for a staged `.doraxpack` v2 bundle built by
// `AgenticAIPackBuilder.build(...)`. Shared by `PluginCreatorPane` (Settings ▸ Extensions ▸
// Store / Packs ▸ [+ Create Pack]) and `DynamicNotchLiveActivityView` (Notch AI pack authoring).

import SwiftUI

struct OwnerReviewCardView: View {
    let card: OwnerReviewCard
    var compact: Bool = false
    var isInstalling: Bool = false
    var errorMessage: String? = nil
    let onApprove: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            header
            capabilitiesSection
            if !card.dryRunResults.isEmpty {
                dryRunSection
            }
            if !card.requestedPermissions.isEmpty {
                permissionsSection
            }
            if !card.scriptFiles.isEmpty {
                scriptsSection
            }
            if let errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
            Divider()
            footer
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(compact ? 0.08 : 0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review \(card.appName) Pack")
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                Text("Staged as 0644 · \(card.packID)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("Pending Approval")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.14), in: Capsule())
        }
    }

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Capabilities (\(card.capabilities.count))")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if card.capabilities.isEmpty {
                Text("No executable capabilities detected — minimal pack metadata only.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(card.capabilities.prefix(compact ? 5 : 10).enumerated()), id: \.offset) { _, cap in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: cap.channel))
                            .font(.system(size: 10))
                            .foregroundStyle(.teal)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cap.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            if !cap.detail.isEmpty {
                                Text(cap.detail)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(cap.isReadOnly ? "Read" : "Write")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(cap.isReadOnly ? .green : .orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                (cap.isReadOnly ? Color.green : Color.orange).opacity(0.14),
                                in: Capsule())
                    }
                }
                if card.capabilities.count > (compact ? 5 : 10) {
                    Text("+ \(card.capabilities.count - (compact ? 5 : 10)) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dryRunSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Dry-Run Probes")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(card.dryRunResults.enumerated()), id: \.offset) { _, probe in
                HStack(spacing: 5) {
                    Image(systemName: probe.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(probe.succeeded ? .green : .orange)
                    Text("\(probe.channel.packType): \(probe.detail)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Requested Permissions")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(card.requestedPermissions, id: \.self) { perm in
                Label(perm, systemImage: "lock.shield")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scriptsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Staged Scripts (\(card.scriptFiles.count))")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(card.scriptFiles.joined(separator: ", "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Dismiss", role: .cancel, action: onDismiss)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isInstalling)
            Spacer(minLength: 0)
            Button(action: onApprove) {
                Label(
                    isInstalling ? "Installing…" : "Approve & Install",
                    systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isInstalling)
        }
    }

    private func icon(for channel: CapabilityChannel) -> String {
        switch channel {
        case .extensionHook: return "safari"
        case .embeddedCLI:   return "terminal"
        case .localIPC:      return "point.3.connected.trianglepath.dotted"
        case .utcpHTTP:      return "link"
        case .mcpServer:     return "server.rack"
        case .appleScript:   return "applescript"
        case .urlScheme:     return "arrow.up.right.square"
        case .menuCommand:   return "filemenu.and.selection"
        }
    }
}
