import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var selectedPage: SettingsPage = .general
    // Sidebar visibility lives in shared chrome state so the native titlebar
    // button (added in AppDelegate) toggles the same value.
    @ObservedObject private var chrome = SettingsChromeState.shared

    var body: some View {
        HStack(spacing: 0) {
            if chrome.sidebarVisible {
                SettingsSidebar(selectedPage: $selectedPage)
                    .frame(width: 220)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            SettingsDetailView(page: selectedPage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
