import SwiftUI

struct LauncherShell: View {
    @ObservedObject private var settings = AppSettings.shared
    var onClose: () -> Void = {}

    var body: some View {
        LauncherView(onClose: onClose)
            .preferredColorScheme(resolvedColorScheme)
    }

    private var resolvedColorScheme: ColorScheme? {
        switch settings.appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
