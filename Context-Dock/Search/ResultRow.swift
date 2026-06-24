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
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

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
                if let symbol = coloredSymbolName {
                    Image(systemName: symbol)
                        .font(.system(size: symbolIconSize, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(coloredIconTint)
                        .frame(width: iconImageSize, height: iconImageSize)
                } else if let icon = result.icon {
                    FileThumbnailImage(
                        filePath: result.filePath,
                        fallbackImage: icon,
                        systemName: fallbackIconName,
                        tint: iconTint,
                        size: iconImageSize,
                        cornerRadius: result.type == .application ? 10 : 5,
                        isApplication: result.type == .application
                            || (result.filePath?.hasSuffix(".app") ?? false)
                    )
                } else {
                    FileThumbnailImage(
                        filePath: result.filePath,
                        fallbackImage: nil,
                        systemName: fallbackIconName,
                        tint: iconTint,
                        size: iconImageSize,
                        cornerRadius: 5,
                        isApplication: result.type == .application
                    )
                }
            }
            .frame(width: iconBoxSize, height: iconBoxSize)

            // Text
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.title)
                        .font(.system(size: titleFontSize, weight: .semibold))
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

                if !result.subtitle.hasPrefix("syscmd://") && !result.subtitle.hasPrefix("cli://") {
                    Text(result.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Live control for interactive system commands (volume slider, Wi-Fi toggle)
            if let interactive = interactiveSystemCommand {
                SystemCommandAccessoryView(command: interactive)
                    .padding(.trailing, 6)
            }

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
        .animation(.easeOut(duration: 0.07), value: isSelected)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            UnifiedDockRowBackground(
                isFocused: true,
                isHovered: false,
                isEnabled: true,
                isDark: isDark,
                selectionNamespace: selectionNamespace,
                selectionEffectID: selectionEffectID,
                usesMatchedGeometry: usesDockCapsuleSelection
            )
        } else {
            Color.clear
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

    private var iconBoxSize: CGFloat {
        result.type == .application ? 48 : 34
    }

    private var iconImageSize: CGFloat {
        result.type == .application ? 42 : 25
    }

    private var symbolIconSize: CGFloat {
        result.type == .application ? 28 : 22
    }

    private var fallbackIconSize: CGFloat {
        result.type == .application ? 24 : 17
    }

    private var titleFontSize: CGFloat {
        result.type == .application ? 16 : 14
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

    private var interactiveSystemCommand: SystemCommand? {
        guard result.subtitle.hasPrefix("syscmd://"),
            let id = UUID(uuidString: String(result.subtitle.dropFirst("syscmd://".count))),
            let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == id }),
            command.isEnabled,
            command.interactionType != .none
        else { return nil }
        return command
    }

    private var coloredSymbolName: String? {
        if result.subtitle.hasPrefix("cli://") { return "terminal.fill" }
        if result.subtitle.hasPrefix("syscmd://") {
            let raw = String(result.subtitle.dropFirst("syscmd://".count))
            if let id = UUID(uuidString: raw),
                let command = SystemCommandsRegistry.shared.commands.first(where: { $0.id == id })
            {
                return command.icon
            }
            return fallbackIconName
        }
        // Extension-style rows (incl. "Quit <App>") carry a real app icon —
        // show it. Only fall back to an SF symbol when there's no icon.
        guard result.type == .extensionCommand, result.icon == nil else { return nil }
        return fallbackIconName
    }

    private var coloredIconTint: SwiftUI.Color {
        if result.subtitle.hasPrefix("syscmd://") {
            let name = result.title.lowercased()
            if name.contains("wi-fi") || name.contains("wifi") { return .blue }
            if name.contains("bluetooth") { return .cyan }
            if name.contains("volume") { return .orange }
            if name.contains("sleep") { return .indigo }
            if name.contains("lock") { return .purple }
            if name.contains("restart") { return .green }
            if name.contains("shut") || name.contains("quit") || name.contains("log out") { return .red }
            if name.contains("app store") { return .blue }
        }
        return iconTint
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
