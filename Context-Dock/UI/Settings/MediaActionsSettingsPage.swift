import SwiftUI

private struct BuiltInMediaAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let accepts: String
    let engine: String
    let command: String
}

struct MediaActionsSettingsPage: View {
    private let actions: [BuiltInMediaAction] = [
        .init(
            id: "ocr-image",
            title: "OCR Image",
            subtitle: "Extract visible text from screenshots, photos, and document images.",
            icon: "text.viewfinder",
            tint: .pink,
            accepts: "PNG, JPEG, HEIC, TIFF, WebP",
            engine: "On-device Vision OCR",
            command: "Select image → OCR Image"
        ),
        .init(
            id: "describe-image",
            title: "Describe Image",
            subtitle: "Ask AI to describe objects, layout, visible text, and likely purpose.",
            icon: "photo",
            tint: .purple,
            accepts: "Images and screenshots",
            engine: "Selection Scope AI + converted context",
            command: "Select image → Describe Image"
        ),
        .init(
            id: "compress-image",
            title: "Compress Image",
            subtitle: "Create a smaller JPEG copy beside the selected image.",
            icon: "arrow.down.right.and.arrow.up.left",
            tint: .orange,
            accepts: "PNG, JPEG, HEIC, TIFF",
            engine: "macOS sips",
            command: "sips -s format jpeg -s formatOptions 72 <file> --out <copy>"
        ),
        .init(
            id: "convert-image",
            title: "Convert Image",
            subtitle: "Convert selected images to JPEG or PNG using built-in macOS tools.",
            icon: "photo.badge.arrow.down",
            tint: .blue,
            accepts: "PNG, JPEG, HEIC, TIFF",
            engine: "macOS sips",
            command: "sips -s format jpeg|png <file> --out <copy>"
        ),
        .init(
            id: "media-brief",
            title: "Video / Audio Brief",
            subtitle: "Summarize selected media file metadata and suggest useful next actions.",
            icon: "waveform.and.magnifyingglass",
            tint: .teal,
            accepts: "MOV, MP4, M4A, MP3, WAV, FLAC",
            engine: "MarkItDown / avmediainfo / on-device AI context",
            command: "Select media → Video Brief or Audio Brief"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Built-in Media Actions", systemImage: "photo.on.rectangle.angled")
                        .font(.system(size: 16, weight: .semibold))
                    Text("These actions ship with Context-Dock and appear from Selection Scope when the selected file is an image, video, audio, or PDF-like media document. Use them as templates when creating your own media workflows.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVStack(spacing: 12) {
                    ForEach(actions) { action in
                        mediaActionCard(action)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("How to create your own media action")
                        .font(.system(size: 13, weight: .semibold))
                    mediaStep("1", "Open Selection Scope", "Use selected files/images/media as the trigger input.")
                    mediaStep("2", "Pick a safe engine", "Use built-in macOS tools first: sips, avmediainfo, avconvert, Vision OCR, or MarkItDown.")
                    mediaStep("3", "Add approval for writes", "Transforms that create, overwrite, delete, or move files should ask for approval before running.")
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mediaActionCard(_ action: BuiltInMediaAction) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: action.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(action.tint)
                .frame(width: 38, height: 38)
                .background(action.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(action.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 8) {
                    mediaMeta("Accepts", action.accepts)
                    mediaMeta("Engine", action.engine)
                }

                Text(action.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    private func mediaMeta(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mediaStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.pink, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
