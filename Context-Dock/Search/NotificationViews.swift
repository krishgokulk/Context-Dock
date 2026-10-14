import AppKit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI



// MARK: - Old Notification Panel (popover, superseded by NotificationDockView)

struct NotificationPanelView: View {
    @ObservedObject private var manager = ILauncherNotificationManager.shared

    private func color(for name: String) -> SwiftUI.Color {
        switch name {
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        case "purple": return .purple
        case "teal": return .teal
        default: return .blue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Notifications")
                    .font(.headline)
                if manager.unreadCount > 0 {
                    Text("\(manager.unreadCount)")
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                if !manager.notifications.isEmpty {
                    Button("Mark all read") { manager.markAllRead() }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    Button(action: { manager.clearAll() }) {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if manager.notifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No notifications")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.notifications) { n in
                            Button(action: { manager.tap(n.id) }) {
                                HStack(spacing: 10) {
                                    Image(systemName: n.icon)
                                        .font(.system(size: 16))
                                        .foregroundStyle(color(for: n.accentColor))
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(n.title)
                                            .font(.subheadline)
                                            .fontWeight(n.isRead ? .regular : .semibold)
                                            .lineLimit(1)
                                        Text(n.body)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        Text(n.date, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }

                                    Spacer()

                                    if !n.isRead {
                                        Circle()
                                            .fill(color(for: n.accentColor))
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(n.isRead ? Color.clear : Color.white.opacity(0.04))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    manager.markRead(n.id)
                                } label: {
                                    Label("Mark as Read", systemImage: "checkmark.circle")
                                }
                                Button(role: .destructive) {
                                    manager.remove(n.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pinned App Drop Delegate for Reordering
