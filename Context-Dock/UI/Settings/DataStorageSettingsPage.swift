import SwiftUI
import AppKit

struct DataStorageSettingsPage: View {
    @State private var menuCacheSize: String = "…"
    @State private var appDataSize: String = "…"
    @State private var aiHistorySize: String = "…"
    @State private var memoryFiles: [MarkdownMemoryFileSummary] = []
    @StateObject private var retrievalEvaluation = RetrievalEvaluationStore.shared
    @State private var retrievalQuery = ""
    @State private var expectedRetrievalText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CardSection(title: "Backup & Restore", systemImage: "arrow.up.arrow.down.circle") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Export or import settings, shortcuts, and extensions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button {
                                let result = SettingsBackupManager.shared.exportSettings().map { _ in () }
                                showAlert(result: result, successMessage: "Settings exported successfully.")
                            } label: {
                                Label("Export Settings", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                let result = SettingsBackupManager.shared.importSettings().map { _ in () }
                                showAlert(result: result, successMessage: "Settings imported. Some changes may require restart.")
                            } label: {
                                Label("Import Settings", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 12)
                }

                CardSection(title: "Cache", systemImage: "internaldrive") {
                    VStack(spacing: 0) {
                        CacheRow(
                            icon: "list.bullet.rectangle.fill",
                            iconColor: .orange,
                            title: "Menu Cache",
                            subtitle: "Indexed app menu items for instant lookup.",
                            size: menuCacheSize
                        ) {
                            clearMenuCache()
                        }
                        Divider()
                        CacheRow(
                            icon: "folder.fill.badge.gearshape",
                            iconColor: .blue,
                            title: "App Data",
                            subtitle: "Per-app context and shortcut records.",
                            size: appDataSize
                        ) {
                            clearAppData()
                        }
                        Divider()
                        CacheRow(
                            icon: "brain.head.profile",
                            iconColor: .purple,
                            title: "AI Assistant History",
                            subtitle: "Stored AI conversation context.",
                            size: aiHistorySize
                        ) {
                            clearAIHistory()
                        }
                    }
                }

                CardSection(title: "Markdown Memory", systemImage: "brain.head.profile.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Local, readable, and user-controlled")
                                    .font(.system(size: 13, weight: .medium))
                                Text("General memory and app-scoped memory are stored as plain Markdown files.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                NSWorkspace.shared.open(MarkdownMemoryStore.shared.folderURL)
                            } label: {
                                Label("Open Folder", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Divider()

                        if memoryFiles.isEmpty {
                            Text("Memory files are created when the feature is first used.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(memoryFiles.enumerated()), id: \.element.id) { index, file in
                                    MemoryFileRow(file: file) {
                                        NSWorkspace.shared.open(file.url)
                                    }
                                    if index < memoryFiles.count - 1 { Divider() }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }

                CardSection(title: "Retrieval Evaluation", systemImage: "scope") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Measure the existing local retrieval before considering GraphRAG. Enter a query and a piece of text that should appear in the results.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Query, for example: Context-Dock", text: $retrievalQuery)
                            .textFieldStyle(.roundedBorder)
                        TextField("Expected app, menu, file, or URL text", text: $expectedRetrievalText)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Run Evaluation") {
                                _ = retrievalEvaluation.run(
                                    query: retrievalQuery,
                                    expectedText: expectedRetrievalText)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                retrievalQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || expectedRetrievalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if !retrievalEvaluation.results.isEmpty {
                                Text("Hit@5 \(retrievalEvaluation.hitRateAt5, format: .percent.precision(.fractionLength(0)))  ·  MRR \(retrievalEvaluation.meanReciprocalRank, format: .number.precision(.fractionLength(2)))")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear Results", role: .destructive) {
                                    retrievalEvaluation.clear()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        if let result = retrievalEvaluation.results.first {
                            Divider()
                            RetrievalEvaluationResultRow(result: result)
                        }
                    }
                    .padding(.vertical, 12)
                }

                CardSection(title: "Search Directories", systemImage: "folder.fill") {
                    SearchDirectoriesListView()
                        .padding(.vertical, 12)
                }
            }
            .padding(28)
        }
        .task {
            await loadCacheSizes()
            memoryFiles = MarkdownMemoryStore.shared.fileSummaries()
        }
    }

    // MARK: - Sizes

    private func loadCacheSizes() async {
        let base = baseURL
        menuCacheSize = fileSize(at: base?.appendingPathComponent("AppMenuCapabilities.json"))
        appDataSize = directorySize(at: base?.appendingPathComponent("apps"))
        let historyData = UserDefaults.standard.data(forKey: "aiChatHistoryData")
        aiHistorySize = formatBytes(Int64(historyData?.count ?? 0))
    }

    private var baseURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Context-Dock", isDirectory: true)
    }

    private func fileSize(at url: URL?) -> String {
        guard let url else { return "—" }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        return formatBytes(size)
    }

    private func directorySize(at url: URL?) -> String {
        guard let url,
              let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey],
                options: .skipsHiddenFiles
              ) else { return "—" }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return formatBytes(total)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1_024
        return String(format: "%.0f KB", max(1, kb))
    }

    // MARK: - Clear actions

    private func clearMenuCache() {
        if let url = baseURL?.appendingPathComponent("AppMenuCapabilities.json") {
            try? FileManager.default.removeItem(at: url)
        }
        menuCacheSize = "0 KB"
    }

    private func clearAppData() {
        if let url = baseURL?.appendingPathComponent("apps") {
            try? FileManager.default.removeItem(at: url)
        }
        appDataSize = "0 KB"
    }

    private func clearAIHistory() {
        UserDefaults.standard.removeObject(forKey: "aiChatHistoryData")
        NotificationCenter.default.post(name: .chatHistoryCleared, object: nil)
        aiHistorySize = "0 KB"
    }

    private func showAlert(result: Result<Void, Error>, successMessage: String) {
        let alert = NSAlert()
        switch result {
        case .success:
            alert.messageText = "Success"
            alert.informativeText = successMessage
            alert.alertStyle = .informational
        case .failure(let error):
            alert.messageText = "Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct RetrievalEvaluationResultRow: View {
    let result: RetrievalEvaluationResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.hitAt5 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.hitAt5 ? .green : .red)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.hitAt5 ? "Pass · hit at rank \(result.rank ?? 0)" : "Miss · expected text not in top 5")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(result.resultCount) rows · \(result.latencyMilliseconds, format: .number.precision(.fractionLength(1))) ms")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let row = result.matchedRow {
                    Text(row)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }
}

private struct MemoryFileRow: View {
    let file: MarkdownMemoryFileSummary
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.relativePath.hasPrefix("cache/") ? "clock.arrow.circlepath" : "doc.text")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(file.relativePath.hasPrefix("apps/") ? .blue : .purple)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(file.relativePath)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Text(fileSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open", action: onOpen)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 9)
    }

    private var fileSubtitle: String {
        if let freshness = file.freshness { return freshness }
        if file.relativePath == "MEMORY.md" {
            return "Index · \(file.factCount) mapped location\(file.factCount == 1 ? "" : "s")"
        }
        return "\(file.factCount) saved fact\(file.factCount == 1 ? "" : "s")"
    }
}

private struct CacheRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let size: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(size)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)

            Button("Clear") {
                onClear()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
        .padding(.vertical, 11)
    }
}
