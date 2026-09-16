import SwiftUI

/// Left column of the Integrations workspace: the scope switch, the search field, and the
/// selectable list of integrations for that scope.
///
/// Apps and Global are separate authority scopes, so the list never mixes them — switching
/// scope replaces the list rather than filtering one combined collection.
struct IntegrationBrowserView: View {
    @Binding var scope: IntegrationScope
    @Binding var query: String
    @Binding var selectedAppID: String?
    let apps: [AppIntegrationSummary]
    let global: GlobalIntegrationSummary
    let onRemove: (AppIntegrationSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Scope", selection: $scope) {
                Text("Apps").tag(IntegrationScope.apps)
                Text("Global").tag(IntegrationScope.global)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .accessibilityLabel("Integration scope")

            searchField
            Divider()
            list
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search integrations", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var list: some View {
        switch scope {
        case .apps:
            if apps.isEmpty {
                emptyState(
                    icon: "app.dashed",
                    message: query.isEmpty
                        ? "No app integrations yet."
                        : "No integrations match “\(query)”.")
            } else {
                List(selection: $selectedAppID) {
                    ForEach(apps) { app in
                        appRow(app)
                            .tag(app.id)
                            .contentShape(Rectangle())
                            // Double-click and right-click both reach removal, because an
                            // integration for an app that is gone has no other way out.
                            .onTapGesture(count: 2) {
                                selectedAppID = app.id
                                onRemove(app)
                            }
                            .contextMenu {
                                Button("Remove Integration…", role: .destructive) {
                                    onRemove(app)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        case .global:
            List {
                globalRow
            }
            .listStyle(.sidebar)
        }
    }

    private func appRow(_ app: AppIntegrationSummary) -> some View {
        HStack(spacing: 9) {
            IntegrationAppIcon(bundleID: app.bundleID, fallbackSymbol: app.icon)
                .frame(width: 18, height: 18)
                .opacity(app.adapter?.isEnabled == false ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.appName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(for: app))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if !IntegrationAppPresence.isInstalled(bundleID: app.bundleID) {
                Text("Not installed")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.16), in: Capsule())
            } else if case .needsAttention = app.health {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Needs attention")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.appName)
        .accessibilityValue(
            IntegrationAppPresence.isInstalled(bundleID: app.bundleID)
                ? subtitle(for: app)
                : "\(subtitle(for: app)), app not installed")
    }

    private var globalRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "globe")
                .font(.system(size: 13))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Global")
                    .font(.system(size: 12, weight: .medium))
                Text(globalSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Global capabilities")
        .accessibilityValue(globalSubtitle)
    }

    private func subtitle(for app: AppIntegrationSummary) -> String {
        let actions = app.counts.actions
        let resources = app.counts.resources
        return "\(actions) action\(actions == 1 ? "" : "s") · \(resources) resource\(resources == 1 ? "" : "s")"
    }

    private var globalSubtitle: String {
        let actions = global.commands.count
            + global.selectionExtensions.count
            + global.selectionRules.count
        let resources = global.cliTools.count + global.mcpServers.count
        return "\(actions) action\(actions == 1 ? "" : "s") · \(resources) resource\(resources == 1 ? "" : "s")"
    }

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }
}
