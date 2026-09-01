import SwiftUI

@MainActor
enum ChatSlashAppPicker {
    static func matches(for text: String) -> [ChatAppEntry] {
        guard text.hasPrefix("/") else { return [] }
        let filter = String(text.dropFirst())
        guard !filter.contains(" ") else { return [] }
        return ChatAppDirectory.matching(filter.lowercased())
    }

    @discardableResult
    static func pickLeadingMatch(
        text: inout String,
        onPick: (ChatAppEntry) -> Void
    ) -> Bool {
        guard let match = matches(for: text).first else { return false }
        onPick(match)
        text = ""
        return true
    }
}

struct ChatSlashAppChipStrip: View {
    let matches: [ChatAppEntry]
    let onPick: (ChatAppEntry) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(matches) { app in
                    Button { onPick(app) } label: {
                        HStack(spacing: 7) {
                            Group {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    Image(systemName: "app.dashed")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(alignment: .bottomTrailing) {
                                if app.isRunning {
                                    Circle()
                                        .fill(.green)
                                        .frame(width: 6, height: 6)
                                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                                }
                            }

                            Text(app.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(
                            app.id == matches.first?.id
                                ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(
                                app.id == matches.first?.id
                                    ? Color.accentColor.opacity(0.75)
                                    : Color.white.opacity(0.16),
                                lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(app.isRunning ? "\(app.name) — running" : app.name)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}
