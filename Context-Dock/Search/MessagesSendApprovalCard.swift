import SwiftUI

struct MessagesSendApprovalCard: View {
    let pending: AICapabilityApprovalCenter.PendingApproval

    @State private var contactPhoto: NSImage?
    @State private var fileThumbnail: NSImage?

    private var recipient: String {
        pending.plan.input["recipient"] ?? ""
    }

    private var body_text: String {
        pending.plan.input["body"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var filePath: String {
        pending.plan.input["filePath"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var hasFile: Bool { !filePath.isEmpty }

    private var resolvedName: String {
        switch MessagesAutomation.resolveRecipient(recipient) {
        case .resolved(let contact): return contact.name
        case .ambiguous, .notFound: return recipient
        }
    }

    private var resolvedHandle: String {
        switch MessagesAutomation.resolveRecipient(recipient) {
        case .resolved(let contact):
            return contact.handle != contact.name ? contact.handle : ""
        case .ambiguous, .notFound: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 7) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(hasFile ? "Send File via Messages" : "Send Message")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
                Text("High")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            // Recipient row
            HStack(spacing: 10) {
                contactPhotoView
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolvedName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !resolvedHandle.isEmpty {
                        Text(resolvedHandle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "message.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            // File attachment row
            if hasFile {
                HStack(spacing: 10) {
                    filePreviewView
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ApprovalCardEnrichment.fileName(at: filePath))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let size = ApprovalCardEnrichment.fileSize(at: filePath) {
                            Text(size)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Body text
            if !body_text.isEmpty {
                Text(body_text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 9)
            }

            if !pending.plan.explanation.isEmpty {
                Text(pending.plan.explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .italic()
            }

            Text("Sends immediately upon approval. Cannot be undone.")
                .font(.system(size: 10))
                .foregroundStyle(.orange)

            Text("Expires after 60 seconds.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            // Buttons
            HStack(spacing: 8) {
                Button("Cancel") { AICapabilityApprovalCenter.shared.deny() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Button("Send") { AICapabilityApprovalCenter.shared.approve() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(Color.green, in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8)
        )
        .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
        .task { await loadEnrichment() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var contactPhotoView: some View {
        if let photo = contactPhoto {
            Image(nsImage: photo)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.green.opacity(0.2))
                .frame(width: 36, height: 36)
                .overlay {
                    Text(initials(for: resolvedName))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.green)
                }
        }
    }

    @ViewBuilder
    private var filePreviewView: some View {
        if let thumb = fileThumbnail {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(nsImage: ApprovalCardEnrichment.fileIcon(at: filePath))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
        }
    }

    // MARK: - Loading

    private func loadEnrichment() async {
        contactPhoto = ApprovalCardEnrichment.contactPhoto(for: recipient)
        if hasFile {
            fileThumbnail = await ApprovalCardEnrichment.fileThumbnail(at: filePath)
        }
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}
