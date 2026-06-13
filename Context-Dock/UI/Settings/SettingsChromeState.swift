import Combine
import SwiftUI

/// Shared chrome state for the settings window so a native titlebar button can
/// drive the SwiftUI sidebar visibility.
final class SettingsChromeState: ObservableObject {
    static let shared = SettingsChromeState()
    @Published var sidebarVisible = true
    private init() {}

    func toggleSidebar() {
        withAnimation(.snappy(duration: 0.18)) { sidebarVisible.toggle() }
    }
}
