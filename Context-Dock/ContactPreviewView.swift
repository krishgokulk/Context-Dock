import SwiftUI
import AppKit

struct ContactPreviewView: View {
    let contact: ContactSearchManager.ContactResult
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        isPresented = false
                    }
                }

            // Contact Card
            VStack(spacing: 0) {
                // Header with close button
                HStack {
                    Text("Contact Preview")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: {
                        withAnimation {
                            isPresented = false
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                }
                .padding()

                Divider()

                // Contact Information
                VStack(spacing: 24) {
                    // Profile Image
                    if let image = contact.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 2)
                            )
                    } else {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.6)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 120, height: 120)

                            Text(getInitials())
                                .font(.system(size: 48, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }

                    // Name
                    VStack(spacing: 4) {
                        Text(contact.fullName.isEmpty ? "No Name" : contact.fullName)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.primary)

                        if !contact.primaryEmail.isEmpty {
                            Text(contact.primaryEmail)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Action Buttons
                    HStack(spacing: 12) {
                        if !contact.primaryEmail.isEmpty {
                            ActionButton(
                                icon: "envelope.fill",
                                label: "Email",
                                color: .blue
                            ) {
                                if let url = URL(string: "mailto:\(contact.primaryEmail)") {
                                    NSWorkspace.shared.open(url)
                                }
                            }

                            ActionButton(
                                icon: "message.fill",
                                label: "Message",
                                color: .green
                            ) {
                                if let url = URL(string: "imessage:\(contact.primaryEmail)") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }

                        ActionButton(
                            icon: "person.crop.circle.fill",
                            label: "Open",
                            color: .orange
                        ) {
                            contact.openInContacts()
                        }
                    }

                    // Hint
                    Text("Press Esc to close")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
                .padding(32)
            }
            .frame(width: 450, height: 500)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
            )
        }
    }

    private func getInitials() -> String {
        let firstName = contact.givenName.prefix(1)
        let lastName = contact.familyName.prefix(1)

        if !firstName.isEmpty && !lastName.isEmpty {
            return "\(firstName)\(lastName)".uppercased()
        } else if !firstName.isEmpty {
            return firstName.uppercased()
        } else if !lastName.isEmpty {
            return lastName.uppercased()
        } else if !contact.primaryEmail.isEmpty {
            return contact.primaryEmail.prefix(1).uppercased()
        }

        return "?"
    }
}

struct ActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundStyle(color)
                }

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
