import SwiftUI

struct ContextDockGlyph: View {
    var size: CGFloat = 20
    var opacity: Double = 0.75

    var body: some View {
        Image("DLogo")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .opacity(opacity)
            .shadow(color: Color.black.opacity(0.5), radius: 1.5, x: 0, y: 1)
    }
}
