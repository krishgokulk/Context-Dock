// ProviderUsagePanel.swift
// Context-Dock
//
// What the selected provider has spent, and what it has left — in the one place the user
// goes to choose a provider.
//
// The data was already being collected: token counts from every response, rate-limit
// headers from keyed APIs, and the reset time a subscription states when it runs dry. None
// of it was visible where the decision is made. A provider list that cannot say "this one
// is out until 3pm" is a list of names.
//
// Three sources, in descending order of urgency, and each one honest about its limits:
//
//   1. Subscription quota — only ever known once a plan refuses. A bridge strips the
//      upstream rate-limit headers, so there is no percentage to draw and none is drawn.
//   2. Rate-limit headers — real remaining/limit numbers, but only keyed APIs send them.
//   3. Token ledger — always available, because DoraX counts it: today's tokens per model.

import Combine
import SwiftUI

struct ProviderUsagePanel: View {
    let provider: AIProvider

    @ObservedObject private var usageStore = AIProviderUsageStore.shared
    @ObservedObject private var ledger = AITokenLedger.shared

    /// Ticks the countdown without polling anything: the reset time is already known, only
    /// the words in front of it change.
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Usage", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    .font(.headline)
                Spacer()
                if todayTotal > 0 {
                    Text("\(todayTotal.compactTokenCount) tokens today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let quota = usageStore.subscriptionQuota(for: provider) {
                quotaCard(quota)
            }

            if let limits = headerLimits {
                headerCard(limits)
            }

            if todayEntries.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(todayEntries.prefix(4)) { entry in
                        modelRow(entry)
                    }
                }
            }
        }
        .onReceive(clock) { date in
            now = date
            usageStore.pruneElapsedQuotas()
        }
        .overlay(alignment: .bottom) { Color.clear.frame(height: 0) }
    }

    // MARK: - Cards

    private func quotaCard(_ quota: AISubscriptionQuota) -> some View {
        let plan = quota.planType.map { " · \($0)" } ?? ""
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Plan limit reached\(plan)")
                    .font(.subheadline).fontWeight(.medium)
                Text("Resets in \(Self.wait(until: quota.resetsAt, from: now)) · \(Self.clockText(quota.resetsAt))")
                    .font(.caption).foregroundStyle(.secondary)
                if let alternative = AISubscriptionGuard.alternative(to: provider) {
                    Text("Requests are held back until then. \(alternative.displayName) is ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func headerCard(_ usage: AIProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let remaining = usage.remainingRequests, let limit = usage.limitRequests,
                limit > 0
            {
                meter(
                    title: "Requests", remaining: remaining, limit: limit,
                    detail: usage.resetText)
            }
            if let remaining = usage.remainingTokens, let limit = usage.limitTokens, limit > 0 {
                meter(
                    title: "Tokens", remaining: remaining, limit: limit,
                    detail: usage.resetText)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// A bar is only drawn where both numbers are real. This is the one place a percentage
    /// is honest — the provider stated the limit and what is left of it.
    private func meter(title: String, remaining: Int, limit: Int, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).fontWeight(.medium)
                Spacer()
                Text("\(remaining.compactTokenCount) / \(limit.compactTokenCount) left")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(remaining), total: Double(limit))
                .progressViewStyle(.linear)
                .tint(Double(remaining) / Double(limit) < 0.15 ? .orange : .accentColor)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func modelRow(_ entry: AITokenUsageEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.model)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(entry.requests) req")
                .font(.caption2).foregroundStyle(.secondary)
            Text(entry.totalTokens.compactTokenCount)
                .font(.caption).fontWeight(.medium)
        }
    }

    // MARK: - Data

    /// The ledger files by display name, which is what the provider paths record.
    private var todayEntries: [AITokenUsageEntry] {
        ledger.today.filter { $0.providerName == provider.displayName }
    }

    private var todayTotal: Int { todayEntries.reduce(0) { $0 + $1.totalTokens } }

    private var headerLimits: AIProviderUsage? {
        usageStore.usage.first { $0.providerName == provider.displayName }
    }

    /// Says why there is nothing rather than only that there is nothing — the reason differs
    /// per provider and is the part worth knowing.
    private var emptyText: String {
        switch provider {
        case .claudeBridge, .chatGPTBridge:
            return "A bridge reports quota only when the plan runs out — there is no "
                + "remaining-balance figure to read until then. Tokens counted here are "
                + "DoraX's own record of what it sent."
        case .onDevice, .ollama:
            return "Runs on this Mac. No quota, no billing — nothing to count against a plan."
        default:
            return "Usage appears after this provider's next request."
        }
    }

    // MARK: - Formatting

    private static func wait(until date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds < 60 { return "under a minute" }
        if seconds < 3_600 { return "\(seconds / 60) min" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    private static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}
