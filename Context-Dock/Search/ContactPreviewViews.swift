import AppKit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI

struct KeyboardHintBadge: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: .tertiaryLabelColor).opacity(0.2))
                .cornerRadius(4)

            Text(action)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Contact Preview Card
struct ContactPreviewCard: View {
    let contact: SearchResult
    @Binding var isPresented: Bool
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        isPresented = false
                    }
                }

            // Contact card
            VStack(spacing: 0) {
                // Header with close button
                HStack {
                    Text(contact.title)
                        .font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Button(action: {
                        withAnimation {
                            isPresented = false
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // Contact details
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Profile section
                        VStack(spacing: 12) {
                            if let icon = contact.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 80)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.gray.opacity(0.2), lineWidth: 2))
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color.purple.opacity(0.6),
                                                    Color.blue.opacity(0.6),
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 80, height: 80)

                                    Text(getInitials())
                                        .font(.system(size: 32, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                            }

                            Text(contact.title)
                                .font(.system(size: 20, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                        Divider()

                        // All Emails
                        if let contactData = contact.contactData, !contactData.allEmails.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Email")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(contactData.allEmails, id: \.self) { email in
                                    ContactDetailRow(
                                        icon: "envelope.fill",
                                        label: "",
                                        value: email,
                                        action: {
                                            if let url = URL(string: "mailto:\(email)") {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                    )
                                }
                            }
                        }

                        // All Phones
                        if let contactData = contact.contactData, !contactData.allPhones.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Phone")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(contactData.allPhones, id: \.self) { phone in
                                    ContactDetailRow(
                                        icon: "phone.fill",
                                        label: "",
                                        value: phone,
                                        action: {
                                            if let url = URL(string: "tel:\(phone)") {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                    )
                                }
                            }
                        }

                        Divider()

                        // Action buttons
                        HStack(spacing: 12) {
                            if let contactData = contact.contactData {
                                if !contactData.primaryEmail.isEmpty {
                                    Button(action: {
                                        if let url = URL(
                                            string: "mailto:\(contactData.primaryEmail)")
                                        {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }) {
                                        Label("Email", systemImage: "envelope.fill")
                                    }
                                    .buttonStyle(.bordered)

                                    Button(action: {
                                        if let url = URL(
                                            string: "imessage:\(contactData.primaryEmail)")
                                        {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }) {
                                        Label("Message", systemImage: "message.fill")
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if !contactData.primaryPhone.isEmpty {
                                    Button(action: {
                                        if let url = URL(string: "tel:\(contactData.primaryPhone)")
                                        {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }) {
                                        Label("Call", systemImage: "phone.fill")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }

                            Spacer()

                            Button(action: {
                                contact.action()  // Opens in Contacts.app
                            }) {
                                Label("Open", systemImage: "person.crop.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 8)
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(width: 450, height: 500)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 15)
            .opacity(settings.folderPreviewOpacity)
        }
        .onKeyPress(.escape) {
            withAnimation {
                isPresented = false
            }
            return .handled
        }
    }

    private func getInitials() -> String {
        let components = contact.title.components(separatedBy: " ")
        if components.count >= 2 {
            let first = components[0].prefix(1)
            let last = components[components.count - 1].prefix(1)
            return "\(first)\(last)".uppercased()
        } else if let first = components.first?.prefix(1) {
            return first.uppercased()
        }
        return "?"
    }
}

struct ContactDetailRow: View {
    let icon: String
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.lowercase)

            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Text(value)
                    .font(.system(size: 14))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .contentShape(Rectangle())
            .onTapGesture {
                action()
            }
        }
    }
}

// MARK: - Contact Quick Action Button
// ContactQuickActionButton moved to ResultRow.swift

// MARK: - Resize Handle Component
struct ResizeHandle: View {
    @Binding var isDragging: Bool
    @State private var isHovering: Bool = false

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(isHovering || isDragging ? 0.2 : 0.1), radius: 4)

            // Resize icon (diagonal arrows)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering || isDragging ? .primary : .secondary)
                .rotationEffect(.degrees(90))
        }
        .padding(12)
        .opacity(isDragging ? 1.0 : (isHovering ? 0.9 : 0.6))
        .scaleEffect(isDragging ? 1.15 : (isHovering ? 1.05 : 1.0))
        .animation(.easeInOut(duration: 0.15), value: isDragging)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else if !isDragging {
                NSCursor.pop()
            }
        }
        .help("Drag to resize • 75% of screen by default")
    }
}

// MARK: - Folder Item Row
struct FolderItemRow: View {
    let item: FolderPreviewView.FolderItem
    let isSelected: Bool
    var iconSize: CGFloat = 32

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: iconSize, height: iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(item.size)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Text(item.modifiedDate)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

// MARK: - AI Chat Models
/// Spotlight-style context: set when user presses Tab/→ on any search result
