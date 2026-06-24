import AppKit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI

struct NotificationDockView: View {
    @ObservedObject private var manager = ILauncherNotificationManager.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selectedTab: Int  // 0 = Alerts, 1 = Settings
    let profileImage: NSImage?
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            // Tab bar
            HStack(spacing: 0) {
                tabButton(title: "Alerts", icon: "bell.fill", tag: 0)
                tabButton(title: "Settings", icon: "gearshape.fill", tag: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.08))
                    .frame(height: 0.5)
            }

            if selectedTab == 1 {
                notificationSettings
            } else if visibleNotifications.isEmpty {
                emptyState
                    .padding(.horizontal, 18)
                    .padding(.vertical, 22)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleNotifications) { notification in
                            notificationCard(notification)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 320)
            }
        }
        .glassContainer(cornerRadius: 20)
    }

    @ViewBuilder
    private func tabButton(title: String, icon: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tag }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(selectedTab == tag ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedTab == tag ? Color.primary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var notificationSettings: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                settingsSection("In-App Notifications") {
                    settingsToggle(
                        icon: "bell.fill", iconColor: .blue,
                        title: "Action Completed",
                        subtitle: "Show when a dock action finishes",
                        binding: $appSettings.notifyOnActionCompleted
                    )
                    Divider().padding(.leading, 44)
                    settingsToggle(
                        icon: "exclamationmark.triangle.fill", iconColor: .orange,
                        title: "Action Failed",
                        subtitle: "Show when an action encounters an error",
                        binding: $appSettings.notifyOnActionFailed
                    )
                    Divider().padding(.leading, 44)
                    settingsToggle(
                        icon: "sparkles", iconColor: .purple,
                        title: "AI Response",
                        subtitle: "Show when AI finishes a long task",
                        binding: $appSettings.notifyOnAIResponse
                    )
                }

                settingsSection("System Banners") {
                    settingsToggle(
                        icon: "app.badge.fill", iconColor: .red,
                        title: "System Banners",
                        subtitle: "Also send macOS banners for alerts",
                        binding: $appSettings.notifySystemBanners
                    )
                }

                // Open full settings button
                Button {
                    onClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onOpenSettings() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                        Text("Open Full Settings")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
        }
        .frame(maxHeight: 320)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                content()
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func settingsToggle(
        icon: String, iconColor: SwiftUI.Color,
        title: String, subtitle: String,
        binding: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(iconColor.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var visibleNotifications: [ILauncherNotification] {
        Array(manager.notifications.prefix(10))
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Notifications")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.primary)
                        if !visibleNotifications.isEmpty {
                            Text("(\(visibleNotifications.count))")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(headerSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button {
                    onClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onOpenSettings() }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(width: 34, height: 34)
                        .background(toolbarButtonBackground)
                }
                .buttonStyle(.plain)
                .help("Notification Settings")

                Group {
                    if let profileImage {
                        Image(nsImage: profileImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(
                            Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28), lineWidth: 1)
                )
            }

            if !visibleNotifications.isEmpty {
                HStack(spacing: 8) {
                    if manager.unreadCount > 0 {
                        headerActionButton(
                            title: "Mark All Read",
                            systemImage: "checkmark.circle"
                        ) {
                            manager.markAllRead()
                        }
                    }

                    headerActionButton(
                        title: "Clear",
                        systemImage: "trash"
                    ) {
                        manager.clearAll()
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.12))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(cardFill)
                    .frame(width: 58, height: 58)
                Image(systemName: "bell.slash")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("No notifications")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)

            Text("New alerts and completed actions will appear here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            headerActionButton(
                title: "Open Settings",
                systemImage: "gearshape"
            ) {
                onClose()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onOpenSettings() }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func notificationCard(_ notification: ILauncherNotification) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            accentColor(notification.accentColor).opacity(
                                colorScheme == .dark ? 0.18 : 0.12)
                        )
                        .frame(width: 44, height: 44)
                    Image(systemName: notification.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accentColor(notification.accentColor))
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(notification.title)
                            .font(
                                .system(size: 17, weight: notification.isRead ? .medium : .semibold)
                            )
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Spacer(minLength: 8)

                        Text(notification.date, style: .relative)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }

                    Text(notification.body)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }

            HStack(spacing: 8) {
                if notification.action != nil {
                    cardActionButton(
                        title: "Open",
                        prominence: .primary
                    ) {
                        manager.tap(notification.id)
                        onClose()
                    }
                } else if !notification.isRead {
                    cardActionButton(
                        title: "Mark Read",
                        prominence: .secondary
                    ) {
                        manager.markRead(notification.id)
                    }
                }

                cardActionButton(
                    title: "Remove",
                    prominence: .secondary
                ) {
                    manager.remove(notification.id)
                }

                Spacer(minLength: 0)

                if !notification.isRead {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(accentColor(notification.accentColor))
                            .frame(width: 6, height: 6)
                        Text("New")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(cardStroke, lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu {
            if !notification.isRead {
                Button {
                    manager.markRead(notification.id)
                } label: {
                    Label("Mark as Read", systemImage: "checkmark.circle")
                }
            }
            if notification.action != nil {
                Button {
                    manager.tap(notification.id)
                    onClose()
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
            }
            Button(role: .destructive) {
                manager.remove(notification.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func headerActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(toolbarButtonBackground)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cardActionButton(
        title: String,
        prominence: NotificationActionProminence,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominence == .primary ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            prominence == .primary ? Color.accentColor.opacity(0.92) : toolbarFill
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    prominence == .primary
                                        ? Color.accentColor.opacity(0.20)
                                        : cardStroke,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var headerSubtitle: String {
        if visibleNotifications.isEmpty {
            return "Nothing waiting right now"
        }
        if manager.unreadCount > 0 {
            return "\(manager.unreadCount) unread update\(manager.unreadCount == 1 ? "" : "s")"
        }
        return "All caught up"
    }

    // Matches dock GlassBackground dark: rgba(0.10, 0.10, 0.12, 0.52) / light: rgba(0.97, 0.97, 0.99, 0.65)
    private var cardFill: SwiftUI.Color {
        colorScheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.04)
    }

    private var cardStroke: SwiftUI.Color {
        colorScheme == .dark
            ? Color.white.opacity(0.18)  // matches dock border ring alpha
            : Color.black.opacity(0.09)
    }

    private var toolbarFill: SwiftUI.Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.50)
    }

    private var toolbarButtonBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(toolbarFill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(cardStroke, lineWidth: 1)
            )
    }

    private func accentColor(_ name: String) -> SwiftUI.Color {
        switch name {
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        case "purple": return .purple
        case "teal": return .teal
        default: return .blue
        }
    }
}

private enum NotificationActionProminence {
    case primary
    case secondary
}

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
