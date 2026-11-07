import SwiftUI

extension Notification.Name {
    static let globalSearchIndexRebuildRequested = Notification.Name("globalSearchIndexRebuildRequested")
}

struct AdvancedSettingsPage: View {
    @State private var showingAIDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                GlobalSearchIndexSettingsPanel()

                RetrievalEvaluationCard()

                DoraXMCPServerCard()

                // A compact row that opens the full, scrollable diagnostics in a sheet, so the
                // long test/rate/QA surface does not crowd the automation split view below.
                Button {
                    showingAIDiagnostics = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Provider Diagnostics")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Connection & QA tests, per-model pricing, and the AppleScript specialist model.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Divider()

            AutomationSettingsView(settingsPage: .advanced)
        }
        .sheet(isPresented: $showingAIDiagnostics) {
            AIProviderDiagnosticsSheet(isPresented: $showingAIDiagnostics)
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
