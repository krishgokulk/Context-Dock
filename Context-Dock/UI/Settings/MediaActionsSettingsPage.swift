import SwiftUI

struct MediaActionsSettingsPage: View {
    var body: some View {
        SettingsPlaceholderPage(
            icon: "photo.on.rectangle.angled",
            title: "Media Actions",
            message: "Media-specific actions will be grouped here for images, video, audio, and PDF workflows such as resize, convert, compress, OCR, and extract audio."
        )
    }
}
