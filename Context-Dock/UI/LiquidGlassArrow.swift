import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// The DoraX "D" play-arrow rendered as macOS 26 Liquid Glass instead of a flat white image.
///
/// The `DoraXD` asset is a baked white-on-black render with no alpha channel, so it could only be
/// screen-blended — it always looked white and never picked up the wallpaper behind it. Here we
/// derive an alpha mask from the asset's luminance (white arrow → opaque, black field → clear) and
/// clip a real `glassEffect` region to that silhouette. The glass samples the live backdrop
/// (dock material + wallpaper), so the arrow now refracts and tints with whatever is behind it.
struct LiquidGlassArrow: View {
    var size: CGFloat = 24

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .glassEffect(.regular, in: Rectangle())
            .mask(
                Image(nsImage: Self.silhouetteMask)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            )
            // A faint specular rim keeps the arrow legible over busy/bright wallpapers where the
            // glass alone is low-contrast.
            .overlay(
                Image(nsImage: Self.silhouetteMask)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white.opacity(0.22))
                    .blendMode(.overlay)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// Luminance → alpha mask of the logo, generated once and reused.
    static let silhouetteMask: NSImage = makeSilhouetteMask()

    private static func makeSilhouetteMask() -> NSImage {
        let fallback = NSImage(named: "DoraXD") ?? NSImage()
        guard
            let base = NSImage(named: "DoraXD"),
            let tiff = base.tiffRepresentation,
            let ciInput = CIImage(data: tiff)
        else { return fallback }

        // CIMaskToAlpha: bright pixels become opaque white, black pixels become fully transparent.
        let filter = CIFilter.maskToAlpha()
        filter.inputImage = ciInput
        guard let output = filter.outputImage else { return fallback }

        let rep = NSCIImageRep(ciImage: output)
        let masked = NSImage(size: rep.size)
        masked.addRepresentation(rep)
        return masked
    }
}
