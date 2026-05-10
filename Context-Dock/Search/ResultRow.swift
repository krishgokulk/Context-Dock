import AppKit
import SwiftUI

// MARK: - Result Row

struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    @ObservedObject private var settings = AppSettings.shared

    private var isPinned: Bool {
        result.type == .application && settings.isPinned(path: result.subtitle)
    }

    private var typeLabel: String? {
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
            Group {
                if let icon = result.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    switch result.type {
                    case .application:
                        Image(systemName: "app").foregroundColor(.blue)
                    case .shortcut:
                        Image(systemName: "shortcut").foregroundColor(.orange)
                    case .file, .document:
                        Image(systemName: "doc").foregroundColor(.gray)
                    case .folder:
                        Image(systemName: "folder").foregroundColor(.blue)
                    case .contact:
                        Image(systemName: "person.crop.circle").foregroundColor(.purple)
                    case .calendarEvent:
                        Image(systemName: "calendar").foregroundColor(.red)
                    case .reminder:
                        Image(systemName: "checklist").foregroundColor(.orange)
                    case .note:
                        Image(systemName: "note.text").foregroundColor(.yellow)
                    case .mail:
                        Image(systemName: "envelope.fill").foregroundColor(.blue)
                    case .photo:
                        Image(systemName: "photo").foregroundColor(.pink)
                    case .message:
                        Image(systemName: "message.fill").foregroundColor(.green)
                    case .extensionCommand:
                        Image(systemName: "puzzlepiece.extension.fill").foregroundColor(.indigo)
                    case .webSearch:
                        Image(systemName: "globe").foregroundColor(.blue)
                    case .cliTool:
                        Image(systemName: "terminal.fill").foregroundColor(.green)
                    }
                }
            }
            .frame(width: 32, height: 32)

            // Text
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let label = typeLabel {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
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
