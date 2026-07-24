import SwiftUI

struct SettingsSidebar: View {
    @Binding var selectedPage: SettingsPage

    var body: some View {
        // Native sidebar List → macOS 26 Liquid Glass chrome (translucent,
        // floating, system selection highlight) handled by NavigationSplitView.
        // Flat icon rows under grey section headers — every row shares one icon
        // column and one text indent, matching System Settings / Raycast.
        List(selection: $selectedPage) {
            ForEach(SettingsSidebarSection.all) { section in
                Section {
                    ForEach(section.rows) { row in
                        if let page = row.page {
                            sidebarLabel(page, title: row.title)
                                .tag(page)
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
                .font(.system(size: 13))
                .foregroundStyle(page.color)
                .frame(width: 20, alignment: .center)
        }
    }
}
