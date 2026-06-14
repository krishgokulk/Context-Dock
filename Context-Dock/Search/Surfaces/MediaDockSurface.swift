import SwiftUI

struct MediaDockSurface: View {
    @State var title: String = "Now Playing"
    @State var artist: String = "Unknown Artist"
    @State var isPlaying: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Button(action: { isPlaying.toggle() }) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Slider(value: .constant(0.5))
                    .disabled(true)

                Image(systemName: "forward.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }
}
