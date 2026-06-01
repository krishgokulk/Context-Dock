import AppKit
import SwiftUI

// MARK: - Result Row

struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    let isPinned: Bool
    var usesDockCapsuleSelection: Bool = false
    var selectionNamespace: Namespace.ID? = nil
    var selectionEffectID: String = "dock-result-focus"

    private var typeLabel: String? {
        guard result.showsTypeLabel else { return nil }
        switch result.type {
        case .shortcut:         return "SHORTCUT"
        case .folder:           return "FOLDER"
        case .document:         return "DOCUMENT"
        case .file:             return "FILE"
        case .contact:          return "CONTACT"
        case .calendarEvent:    return "EVENT"
        case .reminder:         return "REMINDER"
        case .note:             return "NOTE"
        case .mail:             return "MAIL"
        case .photo:            return "PHOTO"
        case .message:          return "MESSAGE"
        case .extensionCommand: return "EXTENSION"
        case .webSearch:        return "WEB"
        case .application:      return nil
        case .cliTool:          return "CLI"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                if let icon = result.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .renderingMode(.original)
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 25, height: 25)
                } else {
                    Image(systemName: fallbackIconName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(iconTint)
                        .frame(width: 25, height: 25)
                }
            }
            .frame(width: 34, height: 34)

            // Text
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    ForEach(result.displayBadges, id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(badgeColor))
                    }

                    if result.displayBadges.isEmpty, let label = typeLabel {
                        Text(label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(badgeColor))
                    }

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Tab hint when selected
            if isSelected {
                HStack(spacing: 4) {
                    Text(
                        result.type == .application ? "Open panel"
                            : result.type == .cliTool ? "Attach CLI"
                            : result.type == .folder ? "Browse"
                            : result.type == .contact ? "Contact" : "More"
                    )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    Text("tab")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .tertiaryLabelColor).opacity(0.2))
                        .cornerRadius(4)
                }
                .padding(.trailing, 4)
            }

            // Quick Actions for Contacts
            if result.type == .contact, let contactData = result.contactData {
                HStack(spacing: 8) {
                    if !contactData.primaryEmail.isEmpty {
                        ContactQuickActionButton(icon: "envelope.fill", color: .blue, tooltip: "Email") {
                            if let url = URL(string: "mailto:\(contactData.primaryEmail)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    if !contactData.primaryEmail.isEmpty {
                        ContactQuickActionButton(icon: "message.fill", color: .green, tooltip: "Message") {
                            if let url = URL(string: "imessage:\(contactData.primaryEmail)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    if !contactData.primaryPhone.isEmpty {
                        ContactQuickActionButton(icon: "phone.fill", color: .orange, tooltip: "Call") {
                            if let url = URL(string: "tel:\(contactData.primaryPhone)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    if isSelected {
                        Text("Space")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: .tertiaryLabelColor).opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            selectionBackground
                .padding(.horizontal, usesDockCapsuleSelection ? 2 : 6)
        )
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isSelected)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if usesDockCapsuleSelection, isSelected {
            ZStack {
                if let selectionNamespace {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .matchedGeometryEffect(
                            id: selectionEffectID,
                            in: selectionNamespace,
                            properties: .frame,
                            isSource: false
                        )
                } else {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                }
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.055)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.38), lineWidth: 1.0)
                    .blur(radius: 2.2)
            }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.clear)
        }
    }

    private var badgeColor: SwiftUI.Color {
        switch result.type {
        case .shortcut:          return .secondary.opacity(0.15)
        case .folder:            return .blue.opacity(0.15)
        case .document, .file:   return .green.opacity(0.15)
        case .contact:           return .purple.opacity(0.15)
        case .calendarEvent:     return .red.opacity(0.15)
        case .reminder:          return .orange.opacity(0.15)
        case .note:              return .yellow.opacity(0.15)
        case .mail:              return .blue.opacity(0.15)
        case .photo:             return .pink.opacity(0.15)
        case .message:           return .green.opacity(0.15)
        case .extensionCommand:  return .indigo.opacity(0.15)
        case .webSearch:         return .blue.opacity(0.15)
        case .application:       return .clear
        case .cliTool:           return .green.opacity(0.15)
        }
    }

    private var fallbackIconName: String {
        switch result.type {
        case .application: return "app"
        case .shortcut: return "shortcut"
        case .file, .document: return "doc"
        case .folder: return "folder"
        case .contact: return "person.crop.circle"
        case .calendarEvent: return "calendar"
        case .reminder: return "checklist"
        case .note: return "note.text"
        case .mail: return "envelope.fill"
        case .photo: return "photo"
        case .message: return "message.fill"
        case .extensionCommand: return "puzzlepiece.extension.fill"
        case .webSearch: return "globe"
        case .cliTool: return "terminal.fill"
        }
    }

    private var iconTint: SwiftUI.Color {
        switch result.type {
        case .application, .folder, .mail, .webSearch: return .blue
        case .shortcut, .reminder: return .orange
        case .file, .document: return .secondary
        case .contact: return .purple
        case .calendarEvent: return .red
        case .note: return .yellow
        case .photo: return .pink
        case .message: return .green
        case .extensionCommand: return .indigo
        case .cliTool: return .green
        }
    }
}

// Skip re-rendering when result identity, selection, and pin state are unchanged.
extension ResultRow: Equatable {
    static func == (lhs: ResultRow, rhs: ResultRow) -> Bool {
        lhs.result.id == rhs.result.id &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isPinned == rhs.isPinned &&
        lhs.usesDockCapsuleSelection == rhs.usesDockCapsuleSelection
    }
}

// MARK: - Contact Quick Action Button

struct ContactQuickActionButton: View {
    let icon: String
    let color: SwiftUI.Color
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.12))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
