// NotificationsBoardCard.swift
// Context-Dock
//
// Notifications, in the shell's result board (issue #247, inventory D9).
//
// The Dock had them as a compact scope of its own window. Here they are a Global Command
// (`provider:notifications`) the field steps into from Global search, drawn the way the
// clipboard's board is: the field filters, the list on the left, the chosen row on the
// right, and floating key pills at the foot. One card over the field, at the field's width
// — not a second container.
//
// The notifications are `ILauncherNotificationManager`'s and the usage is
// `AIProviderUsageStore`'s and `AITokenLedger`'s, unchanged. This file draws them, plus the
// pure rules the board adds: what the filter keeps and which row the keys move to.

import AppKit
import SwiftUI

// MARK: - Rules

enum NotificationsBoard {
    /// The command's `provider:` name, which the board answers for.
    static let provider = "notifications"

    /// A notification or a usage line: what the list draws and the keys move through.
    enum Item: Identifiable {
        case notification(ILauncherNotification)
        case usage(SharedResultRowModel)

        var id: String {
            switch self {
            case .notification(let n): return n.id.uuidString
            case .usage(let row): return row.id
            }
        }
    }

    /// Notifications first — the board's name, and the rows Return acts on — then the usage
    /// lines the Dock's scope led with. The filter matches title and body, as the Dock's did.
    static func items(
        notifications: [ILauncherNotification], usage: [SharedResultRowModel], query: String
    ) -> (notifications: [Item], usage: [Item]) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func keeps(_ title: String, _ body: String) -> Bool {
            q.isEmpty || title.lowercased().contains(q) || body.lowercased().contains(q)
        }
        return (
            notifications.filter { keeps($0.title, $0.body) }.map(Item.notification),
            usage.filter { keeps($0.title, $0.subtitle) }.map(Item.usage)
        )
    }

    /// The row the keys land on: one step from `current` through `ids`, held at the ends.
    /// Nothing focused (or focus filtered away) starts at the first row.
    static func moved(from current: String?, in ids: [String], down: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(index + (down ? 1 : -1), 0), ids.count - 1)]
    }
}

extension SystemCommand {
    /// The Global Command the Notifications board stands for.
    var isNotificationsBoard: Bool { provider == NotificationsBoard.provider }
}

extension SwiftUI.Color {
    /// A notification's colour name ("green", "red"…) as a colour; anything else is the accent.
    static func named(_ name: String?) -> SwiftUI.Color {
        switch name?.lowercased() {
        case "blue": return .blue
        case "red": return .red
        case "green": return .green
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "indigo": return .indigo
        case "teal": return .teal
        case "pink": return .pink
        case "gray", "grey": return .secondary
        default: return Color.accentColor
        }
    }
}

// MARK: - Usage rows

/// The AI provider usage lines the Notifications board — and the Dock's scope before it —
/// shows: today's tokens per model, spent subscriptions, and live rate limits.
enum AIUsageRows {
    /// Wall-clock time a plan comes back, so "resets in 3h 10m" can be checked against a
    /// clock rather than trusted.
    static func quotaClockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date)
            ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    /// Live per-provider rate-limit rows (from API response headers). Shows a hint
    /// row until the first API-key request populates real numbers.
    @MainActor
    static func rows(usageStore: AIProviderUsageStore = .shared) -> [SharedResultRowModel] {
        let usage = usageStore.usage
        // What today actually cost, in the unit every provider agrees on. These counts were
        // in each response all along and were thrown away, so the one number that tells a
        // user a scoped turn re-sends its context per tool round was the one they could not
        // see. Shown first: it is the answer to "why is this expensive".
        let ledger = AITokenLedger.shared
        let rateCard = AIModelRateCard.shared
        let tokenRows: [SharedResultRowModel] = ledger.today.prefix(6).map { entry in
            var parts = [
                "in \(entry.inputTokens.compactTokenCount)",
                "out \(entry.outputTokens.compactTokenCount)",
            ]
            if entry.cachedInputTokens > 0 {
                parts.append("cached \(entry.cachedInputTokens.compactTokenCount)")
            }
            parts.append("\(entry.requests) request\(entry.requests == 1 ? "" : "s")")
            // Money only where the user has said what the model costs. A row with no rate
            // shows tokens and stops, rather than a number DoraX invented.
            let spend = rateCard.cost(for: entry).map { " · \($0.compactUSD)" } ?? ""
            return SharedResultRowModel(
                id: "tokens-\(entry.id)",
                title: "\(entry.model) — \(entry.totalTokens.compactTokenCount) tokens today"
                    + spend,
                subtitle: parts.joined(separator: " • "),
                systemIcon: "number.circle"
            )
        }

        // A spent subscription is the most urgent thing this scope can say, so it leads.
        // It is also the only quota fact a bridge ever gives up: the plan reports nothing
        // while it still has room, and states the reset time at the moment it runs out.
        usageStore.pruneElapsedQuotas()
        let quotaRows: [SharedResultRowModel] = usageStore.subscriptionQuotas.map { quota in
            let plan = quota.planType.map { " (\($0))" } ?? ""
            let seconds = max(0, Int(quota.resetsAt.timeIntervalSinceNow))
            let wait = seconds < 60
                ? "under a minute"
                : (seconds < 3_600
                    ? "\(seconds / 60) min"
                    : "\(seconds / 3_600)h \((seconds % 3_600) / 60)m")
            return SharedResultRowModel(
                id: "quota-\(quota.id)",
                title: "\(quota.providerName)\(plan) — limit reached",
                subtitle: "Resets in \(wait) · \(Self.quotaClockText(quota.resetsAt))",
                systemIcon: "exclamationmark.triangle.fill"
            )
        }

        guard !usage.isEmpty || !tokenRows.isEmpty || !quotaRows.isEmpty else {
            return [
                SharedResultRowModel(
                    id: "usage-empty",
                    title: "Usage appears after your next AI request",
                    subtitle: "API-key providers report remaining requests/tokens; "
                        + "subscription bridges report only when a plan runs out.",
                    systemIcon: "gauge.with.dots.needle.bottom.50percent"
                )
            ]
        }
        return quotaRows + tokenRows + usage.map { u in
            var parts: [String] = []
            if let remaining = u.remainingRequests {
                let limit = u.limitRequests.map { "/\($0)" } ?? ""
                parts.append("requests \(remaining)\(limit)")
            } else if let limit = u.limitRequests {
                parts.append("request limit \(limit)")
            }
            if let remaining = u.remainingTokens {
                let limit = u.limitTokens.map { "/\($0)" } ?? ""
                parts.append("tokens \(remaining)\(limit)")
            } else if let limit = u.limitTokens {
                parts.append("token limit \(limit)")
            }
            if let reset = u.resetText { parts.append(reset) }
            return SharedResultRowModel(
                id: "usage-\(u.id)",
                title: u.providerName,
                subtitle: parts.joined(separator: " • "),
                systemIcon: "gauge.with.dots.needle.67percent"
            )
        }
    }

}

// MARK: - The board

enum NotificationsBoardMetrics {
    static let headerHeight: CGFloat = 36
    static let footerHeight: CGFloat = 38

    /// The clipboard's board size: the two boards are the same kind of thing.
    static var size: CGSize { ClipboardBoardMetrics.size }
}

struct NotificationsBoardCard: View {
    /// The field the board stands over: its text is the filter.
    @ObservedObject var prompt: AppChatPromptModel
    @ObservedObject private var manager = ILauncherNotificationManager.shared
    @ObservedObject private var usageStore = AIProviderUsageStore.shared
    @ObservedObject private var ledger = AITokenLedger.shared
    @State private var focusedID: String?

    private var size: CGSize { NotificationsBoardMetrics.size }

    private var sections: (notifications: [NotificationsBoard.Item], usage: [NotificationsBoard.Item]) {
        NotificationsBoard.items(
            notifications: manager.notifications, usage: AIUsageRows.rows(usageStore: usageStore),
            query: prompt.query)
    }

    private var flat: [NotificationsBoard.Item] { sections.notifications + sections.usage }

    private var focused: NotificationsBoard.Item? {
        let items = flat
        return items.first { $0.id == focusedID } ?? items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                list
                    .frame(width: CornerBoardLayout.listWidth(
                        board: size.width, preview: .file(URL(fileURLWithPath: "/"))))
                Color.clear.frame(width: CornerBoardLayout.dividerWidth)
                preview
                    .frame(width: CornerBoardLayout.panelWidth(board: size.width))
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(BoardGlass())
        .onHover { _ in prompt.touch() }
        .onAppear { registerKeys() }
        .onDisappear {
            ScopedListKeyBridge.shared.move = nil
            ScopedListKeyBridge.shared.run = nil
        }
    }

    /// The field keeps the keyboard for typing and forwards ↑/↓ and Return here, as it
    /// does for every command's list (`ScopedListKeyBridge`).
    private func registerKeys() {
        let bridge = ScopedListKeyBridge.shared
        bridge.move = { down in
            let ids = flat.map(\.id)
            guard !ids.isEmpty else { return false }
            focusedID = NotificationsBoard.moved(from: focused?.id, in: ids, down: down)
            prompt.touch()
            return true
        }
        // Always taken: Return here opens a notification or does nothing — it never falls
        // through to asking the panel's assistant, whose answer this board does not draw.
        bridge.run = {
            if case .notification(let n) = focused { open(n) }
            return true
        }
    }

    private func open(_ notification: ILauncherNotification) {
        focusedID = notification.id.uuidString
        manager.tap(notification.id)
        prompt.touch()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
            Text("Notifications")
                .font(.system(size: 12, weight: .semibold))
            Text("\(manager.notifications.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            if manager.unreadCount > 0 {
                Text("\(manager.unreadCount) unread")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: NotificationsBoardMetrics.headerHeight)
    }

    // MARK: List

    private var list: some View {
        let sections = sections
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionTitle("Notifications")
                    if sections.notifications.isEmpty {
                        Text(prompt.query.isEmpty ? "No notifications" : "No matching notifications")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                    }
                    ForEach(sections.notifications) { row($0) }
                    if !sections.usage.isEmpty {
                        sectionTitle("AI Provider Usage")
                        ForEach(sections.usage) { row($0) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: focusedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ item: NotificationsBoard.Item) -> some View {
        let isFocused = item.id == focused?.id
        return Group {
            switch item {
            case .notification(let n):
                rowLabel(
                    symbol: n.icon, tint: .named(n.accentColor), title: n.title,
                    trailing: n.date.formatted(date: .omitted, time: .shortened),
                    unread: !n.isRead, focused: isFocused)
                    .onTapGesture(count: 2) { open(n) }
                    .onTapGesture { focusedID = item.id }
                    .contextMenu {
                        if !n.isRead {
                            Button("Mark as Read") { manager.markRead(n.id) }
                        }
                        Button("Remove", role: .destructive) { manager.remove(n.id) }
                    }
            case .usage(let u):
                rowLabel(
                    symbol: u.systemIcon, tint: .secondary, title: u.title, trailing: nil,
                    unread: false, focused: isFocused)
                    .onTapGesture { focusedID = item.id }
            }
        }
        .id(item.id)
    }

    private func rowLabel(
        symbol: String, tint: Color, title: String, trailing: String?, unread: Bool,
        focused: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            Text(title)
                .font(.system(size: 12.5, weight: unread ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            if unread {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            focused ? Color.primary.opacity(0.11) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        if let item = focused {
            NotificationsBoardPreview(item: item)
                .id(item.id)
                .boardPanelCard()
        } else {
            Color.clear.boardPanelCard()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if case .notification = focused {
                BoardFooter.pill { BoardFooter.action("Open", keys: ["↩"]) }
            }
            BoardFooter.pill {
                BoardFooter.button("checkmark.circle", keys: [], help: "Mark All Read") {
                    manager.markAllRead()
                }
            }
            .disabled(manager.unreadCount == 0)
            BoardFooter.pill {
                BoardFooter.button("trash", keys: [], help: "Clear All") {
                    manager.clearAll()
                }
            }
            .disabled(manager.notifications.isEmpty)
            BoardFooter.pill {
                BoardFooter.button("xmark", keys: ["⌫"], help: "Back to Global Context (⌫)") {
                    prompt.leaveScopeForGlobal()
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: NotificationsBoardMetrics.footerHeight)
    }
}

/// The chosen row: its icon and words, then its Information section.
private struct NotificationsBoardPreview: View {
    let item: NotificationsBoard.Item

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 40, height: 40)
                        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .textSelection(.enabled)
                    if !body_.isEmpty {
                        Text(body_)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                Text("Information")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                ForEach(Array(details.enumerated()), id: \.offset) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.element.0)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(entry.element.1)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                            .padding(.horizontal, 14)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var symbol: String {
        switch item {
        case .notification(let n): return n.icon
        case .usage(let u): return u.systemIcon
        }
    }

    private var tint: Color {
        if case .notification(let n) = item { return .named(n.accentColor) }
        return .secondary
    }

    private var title: String {
        switch item {
        case .notification(let n): return n.title
        case .usage(let u): return u.title
        }
    }

    /// `body` is the view's; this is the row's text.
    private var body_: String {
        switch item {
        case .notification(let n): return n.body
        case .usage: return ""
        }
    }

    private var details: [(String, String)] {
        switch item {
        case .notification(let n):
            return [
                ("Received", n.date.formatted(date: .abbreviated, time: .shortened)),
                ("Status", n.isRead ? "Read" : "Unread"),
                ("Return", n.action == nil ? "Marks it read" : "Opens it"),
            ]
        case .usage(let u):
            // "requests 40/50", "Resets in 3h · 14:00": the first word labels the rest.
            return u.subtitle.components(separatedBy: " • ").map { part in
                let words = part.split(separator: " ", maxSplits: 1).map(String.init)
                return words.count == 2 ? (words[0].capitalized, words[1]) : ("", part)
            }
        }
    }
}
