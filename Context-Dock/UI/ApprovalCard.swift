// ApprovalCard.swift
// Context-Dock
//
// One card for every kind of approval.
//
// Three inboxes meant three cards, drawn separately in each surface that remembered to
// draw them: a command card in the dock and again in the chat window, an adapter card
// beside it, a capability card somewhere else. They asked the same question — is this
// alright? — in three visual languages, and a surface that added one usually forgot the
// others.

import SwiftUI

struct ApprovalCard: View {
    let request: ApprovalRequest

    @ObservedObject private var center = ApprovalCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(request.risk.tint)
                Text(request.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text(request.risk.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(request.risk.tint)
            }

            if let subtitle = request.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Attributed, indented and quoted, because this sentence was written by whatever
            // asked — on the AI paths, the model. Rendered plainly it reads as DoraX
            // describing the action, which is how "List the contents of the trash bin"
            // came to sit under Empty Trash as though it were the description.
            if let claim = request.requesterClaim {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ApprovalRequest.claimAttribution(for: request.kind))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("“\(claim)”")
                        .font(.system(size: 11).italic())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 2)
                }
            }

            if let body = request.body, !body.isEmpty {
                Text(body)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 8) {
                Button("Deny") { center.deny(request) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(request.approveTitle) { center.approve(request) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                // Standing grants are the requester's decision to offer, not the card's.
                if let always = center.approveAlways(request) {
                    Button("Always Allow", action: always)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(request.risk.tint.opacity(0.08))
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private var symbol: String {
        switch request.kind {
        case .command: return "terminal.fill"
        case .capability: return "checkmark.shield"
        case .adapter: return "app.connected.to.app.below.fill"
        }
    }
}
