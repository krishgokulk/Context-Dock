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
    /// What a surface reserves for one, when it has no request to measure.
    ///
    /// Kept as the floor rather than the answer: 96pt holds a title and two buttons, and the
    /// card that asked to create a note showed `notes.create…` — the input clipped to one
    /// line, so the one thing the user was being asked to judge was the one thing they could
    /// not read. Surfaces that reserve space should ask `height(for:)`.
    static let height: CGFloat = 96

    /// How tall this particular request needs to be, capped so a long input scrolls instead
    /// of pushing the buttons off the surface.
    static func height(for request: ApprovalRequest) -> CGFloat {
        var total: CGFloat = 64  // header + buttons + padding
        if request.subtitle?.isEmpty == false { total += 18 }
        if let claim = request.requesterClaim, !claim.isEmpty {
            total += 26 + estimatedTextHeight(claim, width: 320, lineHeight: 14, maxLines: 3)
        }
        if let body = request.body, !body.isEmpty {
            total += 16 + min(bodyMaxHeight,
                estimatedTextHeight(body, width: 300, lineHeight: 14, maxLines: 8))
        }
        return max(height, min(total, 280))
    }

    /// What a surface should reserve for whatever is actually pending on it.
    ///
    /// The surfaces size themselves from a Bool — "is there an approval" — and had no way to
    /// ask how tall this one needs to be. Asking the centre keeps the reservation and the
    /// drawn card in step; they were the same number by coincidence before, and the
    /// coincidence is what clipped the note body down to `notes.create…`.
    @MainActor
    static func reservedHeight(for surface: ApprovalSurface) -> CGFloat {
        guard let request = ApprovalCenter.shared.pending(for: surface) else { return height }
        return height(for: request)
    }

    /// The tallest the input preview grows before it scrolls.
    static let bodyMaxHeight: CGFloat = 132

    private static func estimatedTextHeight(
        _ text: String, width: CGFloat, lineHeight: CGFloat, maxLines: Int
    ) -> CGFloat {
        let charsPerLine = max(20, Int(width / 6.2))
        let wrapped = text.components(separatedBy: .newlines).reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / Double(charsPerLine))))
        }
        return CGFloat(min(maxLines, max(1, wrapped))) * lineHeight
    }

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
                // Scrolls rather than clips. What is being approved — the command, the note
                // body, the message text — is the whole question the card is asking, and a
                // truncated first line answers it with an ellipsis.
                ScrollView(.vertical) {
                    Text(body)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: Self.bodyMaxHeight)
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
        case .generalAction: return "play.rectangle.on.rectangle"
        case .adapter: return "app.connected.to.app.below.fill"
        }
    }
}
