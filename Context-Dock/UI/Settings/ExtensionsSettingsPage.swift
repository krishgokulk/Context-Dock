import SwiftUI

struct ExtensionsSettingsPage: View {
    let page: SettingsPage

    var body: some View {
        AutomationSettingsView(settingsPage: page)
            .id(page)
    }
}
