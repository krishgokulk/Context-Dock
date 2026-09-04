import SwiftUI

/// The real app icon, falling back to the adapter's SF Symbol when the app is not installed
/// on this Mac — an adapter can outlive the app it was written for.
struct IntegrationAppIcon: View {
    let bundleID: String
    let fallbackSymbol: String

    var body: some View {
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }

        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: fallbackSymbol).resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
    }
}

/// One app integration: its identity, its enabled state, and the four sections everything
/// it can do is filed under.
struct AppIntegrationDetailView: View {
    let summary: AppIntegrationSummary
    @Binding var selectedTab: IntegrationDetailTab

    @ObservedObject private var adapterManager = AppAdapterManager.shared
    @State private var editingAction: AdapterAction?
    @State private var showActionEditor = false
    @State private var pendingRemoval: AdapterAction?

    init(summary: AppIntegrationSummary, selectedTab: Binding<IntegrationDetailTab>) {
        self.summary = summary
        self._selectedTab = selectedTab
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Section", selection: $selectedTab) {
                ForEach(IntegrationDetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityLabel("Integration section")

            Divider()
            tabContent
        }
        .sheet(isPresented: $showActionEditor) {
            AdapterActionEditorSheet(bundleId: summary.bundleID, existing: editingAction) {
                showActionEditor = false
                editingAction = nil
            }
        }
        .confirmationDialog(
            "Remove “\(pendingRemoval?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Action", role: .destructive) {
                guard let action = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await adapterManager.deleteAction(id: action.id, from: summary.bundleID) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This deletes the action from \(summary.appName). It cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IntegrationAppIcon(bundleID: summary.bundleID, fallbackSymbol: summary.icon)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.appName)
                    .font(.system(size: 18, weight: .semibold))
                Text(summary.bundleID)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            if let adapter = summary.adapter {
                Toggle("Enabled", isOn: Binding(
                    get: { adapter.isEnabled },
                    set: { adapterManager.setEnabled($0, for: summary.bundleID) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("\(summary.appName) integration enabled")

                Button {
                    editingAction = nil
                    showActionEditor = true
                } label: {
                    Label("Add Action", systemImage: "plus")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            AppIntegrationOverviewView(summary: summary)
        case .actions:
            AppIntegrationActionsView(
                bundleID: summary.bundleID,
                appActions: summary.appActions,
                browserActions: summary.browserActions,
                onAdd: {
                    editingAction = nil
                    showActionEditor = true
                },
                onEdit: { action in
                    editingAction = action
                    showActionEditor = true
                },
                onRemove: { action in pendingRemoval = action })
        case .resources, .access:
            IntegrationSectionPlaceholder(tab: selectedTab, appName: summary.appName)
        }
    }
}

/// Stands in for a section that has not been moved across yet, so the tab bar never lies
/// about how many sections exist.
struct IntegrationSectionPlaceholder: View {
    let tab: IntegrationDetailTab
    let appName: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: tab == .resources ? "wrench.and.screwdriver" : "lock.shield")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("\(tab.title) for \(appName)")
                .font(.system(size: 13, weight: .medium))
            Text("Still managed on the App Adapters page.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
