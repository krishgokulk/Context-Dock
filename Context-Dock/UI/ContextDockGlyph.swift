import SwiftUI

/// Context Dock logo mark — black D on transparent background, @1x/@2x/@3x variants.
/// Renders pixel-perfect at any size on all Retina displays.
struct ContextDockGlyph: View {
    var size: CGFloat = 20
    var opacity: Double = 0.75

    var body: some View {
        ZStack {
            Image("DLogo")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Color.black)
                .frame(width: size + 2.4, height: size + 2.4)
                .blur(radius: 0.35)

            Image("DLogo")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Color.black)
                .frame(width: size, height: size)
                .overlay(alignment: .topLeading) {
                    Image("DLogo")
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(Color.white.opacity(0.10))
                        .frame(width: size, height: size)
                        .mask(
                            LinearGradient(
                                colors: [.white, .clear],
                                startPoint: .topLeading,
                                endPoint: .center
                            )
                        )
                }
        }
        .frame(width: size + 2, height: size + 2)
        .opacity(opacity)
        .shadow(color: Color.black.opacity(0.85), radius: 1.4, x: 0, y: 1)
    }
}
