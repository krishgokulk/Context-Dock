import SwiftUI

struct LauncherShell: View {
    var onClose: () -> Void = {}

    var body: some View {
        LauncherView(onClose: onClose)
    }
}
