import SwiftUI

struct SettingsSidebar: View {
    @Binding var selectedPage: SettingsPage
    @State private var expandedGroups: Set<String> = Set(
        SettingsSidebarSection.all.flatMap { section in
            section.rows.compactMap { $0.children.isEmpty ? nil : $0.id }
        }
    )

    var body: some View {
        // Native sidebar List → macOS 26 Liquid Glass chrome (translucent,
        // floating, system selection highlight) handled by NavigationSplitView.
        List(selection: $selectedPage) {
            ForEach(SettingsSidebarSection.all) { section in
                Section {
                    ForEach(section.rows) { row in
                        if let page = row.page {
                            sidebarLabel(page, title: row.title)
                                .tag(page)
                        } else {
                            DisclosureGroup(
                                isExpanded: bindingForGroup(row.id)
                            ) {
                                ForEach(row.children, id: \.self) { child in
                                    sidebarLabel(child, title: child.title)
                                        .tag(child)
                                }
                            } label: {
                                Text(row.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(section.title)
                        if section.id == "extensions" {
                            Text("BETA")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func bindingForGroup(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { isOn in
                if isOn { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
            }
        )
    }

    private func sidebarLabel(_ page: SettingsPage, title: String) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13))
                if page == .aiProviders {
                    Text("BETA")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.15), in: Capsule())
                }
            }
        } icon: {
            Image(systemName: page.icon)
                .foregroundStyle(page.color)
        }
    }
}
