import AppKit
import SwiftUI

struct AppBundleIconView: View {
    let bundleId: String
    let fallbackSymbol: String
    var size: CGFloat = 32
    var cornerRadius: CGFloat = 7

    var body: some View {
        if let icon = InstalledApplicationsCatalog.icon(for: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .frame(width: size, height: size)
        }
    }
}
