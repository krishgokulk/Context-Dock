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
                Section(section.title) {
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
            Text(title)
                .font(.system(size: 13))
        } icon: {
            Image(systemName: page.icon)
                .foregroundStyle(page.color)
        }
    }
}
