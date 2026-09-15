//
//  WorkflowFlowView.swift
//  Context-Dock
//
//  What happens to a request after it leaves the composer: how many became runs,
//  how many of those actually ran commands, how many were verified afterwards, and
//  how they ended. Every stage is a count of durable receipts on disk, which is why
//  a stage can be read as "this happened" rather than "this was attempted".
//

import SwiftUI

struct WorkflowFlowView: View {
    let snapshot: DashboardSnapshot

    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    private struct Stage: Identifiable {
        let id = UUID()
        let name: String
        let value: Int
        let note: String
    }

    private var stages: [Stage] {
        [
            Stage(name: "Task runs", value: snapshot.taskRuns,
                  note: "requests that started work"),
            Stage(name: "Commands run", value: snapshot.commandReceipts,
                  note: "successful tool receipts"),
            Stage(name: "Verified", value: snapshot.verifiedReceipts,
                  note: "read-back checks that passed"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if snapshot.taskRuns == 0 {
                DashboardEmptyNote(
                    symbol: "arrow.triangle.branch",
                    text: "No task runs recorded yet. Ask for something that runs a command and the flow appears here.")
            } else {
                funnel
                Divider().opacity(0.4)
                outcomes
            }
        }
    }

    // MARK: Funnel

    private var funnel: some View {
        let peak = max(1, stages.map(\.value).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(stage.name)
                            .font(.system(size: 11, weight: .medium))
                        Text(stage.note)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        Text("\(stage.value)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                    }
                    GeometryReader { proxy in
                        let width = proxy.size.width * CGFloat(stage.value) / CGFloat(peak)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DashboardPalette.grid(dark))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DashboardPalette.ordinal(index, of: stages.count, dark: dark))
                                .frame(width: max(stage.value > 0 ? 4 : 0, width))
                        }
                    }
                    .frame(height: 8)
                }
                .help("\(stage.name): \(stage.value) — \(stage.note)")
            }
        }
    }

    // MARK: Outcomes

    private var outcomes: some View {
        let parts: [(String, Int, Color)] = [
            ("Completed", snapshot.taskCompleted, DashboardPalette.good(dark)),
            ("Interrupted", snapshot.taskInterrupted, DashboardPalette.warning(dark)),
            ("Failed", snapshot.taskFailed, DashboardPalette.critical(dark)),
        ]
        let total = max(1, parts.reduce(0) { $0 + $1.1 })

        return VStack(alignment: .leading, spacing: 8) {
            Text("Outcomes")
                .font(.system(size: 11, weight: .medium))

            GeometryReader { proxy in
                HStack(spacing: 2) {  // 2px surface gap between abutting segments
                    ForEach(parts, id: \.0) { part in
                        if part.1 > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(part.2)
                                .frame(width: max(4, proxy.size.width * CGFloat(part.1) / CGFloat(total)))
                                .help("\(part.0): \(part.1)")
                        }
                    }
                }
            }
            .frame(height: 10)

            // Status is never colour alone: each swatch ships with its name and count.
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(part.2)
                            .frame(width: 8, height: 8)
                        Text(part.0)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(part.1)")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Activity

/// Chat volume over the last two weeks, split by who spoke. Two series, so it carries a
/// legend; the bars are stacked with a 2px surface gap so the split stays readable at
/// small heights.
struct ActivityChartView: View {
    let days: [ActivityDay]

    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    private var peak: Int { max(1, days.map(\.total).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if days.allSatisfy({ $0.total == 0 }) {
                DashboardEmptyNote(
                    symbol: "chart.bar",
                    text: "No messages in the last 14 days.")
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(days) { day in
                        VStack(spacing: 2) {
                            GeometryReader { proxy in
                                let height = proxy.size.height
                                let userHeight = height * CGFloat(day.userMessages) / CGFloat(peak)
                                let assistantHeight = height * CGFloat(day.assistantMessages) / CGFloat(peak)
                                VStack(spacing: 2) {
                                    Spacer(minLength: 0)
                                    // Rounded data-end on top, square where it meets the
                                    // baseline — the stack reads as one bar.
                                    UnevenRoundedRectangle(
                                        topLeadingRadius: 4, bottomLeadingRadius: 0,
                                        bottomTrailingRadius: 0, topTrailingRadius: 4)
                                        .fill(DashboardPalette.app(dark))
                                        .frame(height: max(day.assistantMessages > 0 ? 2 : 0, assistantHeight))
                                    Rectangle()
                                        .fill(DashboardPalette.folder(dark))
                                        .frame(height: max(day.userMessages > 0 ? 2 : 0, userHeight))
                                }
                            }
                            Text(Self.dayLabel(day.date))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .help("\(Self.fullDate(day.date)): \(day.userMessages) sent, \(day.assistantMessages) replies")
                    }
                }
                .frame(height: 92)

                HStack(spacing: 14) {
                    legendSwatch("You", DashboardPalette.folder(dark))
                    legendSwatch("DoraX", DashboardPalette.app(dark))
                    Spacer(minLength: 0)
                    Text("peak \(peak)/day")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func legendSwatch(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }
}

// MARK: - Shared empty note

struct DashboardEmptyNote: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
