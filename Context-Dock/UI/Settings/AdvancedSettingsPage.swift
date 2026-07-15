import SwiftUI

extension Notification.Name {
    static let globalSearchIndexRebuildRequested = Notification.Name("globalSearchIndexRebuildRequested")
}

struct AdvancedSettingsPage: View {
    var body: some View {
        VStack(spacing: 0) {
            GlobalSearchIndexSettingsPanel()
                .padding(.horizontal, 24)
                .padding(.vertical, 14)

            Divider()

            AutomationSettingsView(settingsPage: .advanced)
        }
    }
}

private struct GlobalSearchIndexSettingsPanel: View {
    @ObservedObject private var status = GlobalSearchIndexStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: status.isIndexing ? "arrow.triangle.2.circlepath" : "bolt.horizontal.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(status.isIndexing ? Color.orange : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Global Search Index")
                        .font(.system(size: 13, weight: .semibold))
                    Text(status.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(status.documentCount) items")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Button(status.isIndexing ? "Indexing..." : "Reindex") {
                    NotificationCenter.default.post(name: .globalSearchIndexRebuildRequested, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(status.isIndexing)
            }

            if status.isIndexing {
                ProgressView(value: status.progress)
                    .progressViewStyle(.linear)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            status.sync(documentCount: GlobalSearchService.shared.documentCount)
        }
    }
}
