import SwiftUI

/// What this integration is and whether it is working.
///
/// Every number here comes from the summary the inventory already composed; querying the
/// stores again from a child view is how two parts of one page start disagreeing.
struct AppIntegrationOverviewView: View {
    let summary: AppIntegrationSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusRow
                healthSection
                summaryCards
                breakdown
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var isEnabled: Bool { summary.adapter?.isEnabled ?? false }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(isEnabled ? "Enabled" : "Disabled")
                .font(.system(size: 12, weight: .medium))
            if summary.adapter?.isBuiltIn == true {
                Text("Built-in")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Integration status")
        .accessibilityValue(isEnabled ? "Enabled" : "Disabled")
    }

    @ViewBuilder
    private var healthSection: some View {
        switch summary.health {
        case .healthy:
            Label("No setup problems", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .needsAttention(let warnings):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.10)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Needs attention")
            .accessibilityValue(warnings.joined(separator: ", "))
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
            summaryCard(
                title: "Actions",
                value: summary.counts.actions,
                caption: "Things it can do",
                icon: "bolt.fill",
                tint: .teal)
            summaryCard(
                title: "Resources",
                value: summary.counts.resources,
                caption: "Skills, tools, and readers",
                icon: "wrench.and.screwdriver.fill",
                tint: .indigo)
        }
    }

    private func summaryCard(
        title: String,
        value: Int,
        caption: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.system(size: 26, weight: .semibold))
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Breakdown")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                breakdownRow("App actions", summary.appActions.count, "bolt")
                breakdownRow("Browser actions", summary.browserActions.count, "safari")
                breakdownRow("Skills", summary.counts.skills, "brain.head.profile")
                breakdownRow("CLI tools", summary.counts.cliTools, "terminal")
                breakdownRow("MCP servers", summary.counts.mcpServers, "server.rack")
                breakdownRow("API connections", summary.counts.apiConnections, "link")
                breakdownRow("Shortcuts", summary.counts.shortcuts, "command")
                breakdownRow("Context readers", summary.counts.contextReaders, "doc.text.magnifyingglass")
            }
        }
    }

    private func breakdownRow(_ title: String, _ value: Int, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(value == 0 ? .tertiary : .secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(value == 0 ? .secondary : .primary)
            Spacer(minLength: 6)
            Text("\(value)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(value == 0 ? .secondary : .primary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
    }
}
