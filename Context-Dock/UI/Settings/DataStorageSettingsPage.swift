import SwiftUI
import AppKit

struct DataStorageSettingsPage: View {
    @State private var menuCacheSize: String = "…"
    @State private var appDataSize: String = "…"
    @State private var aiHistorySize: String = "…"

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
                            title: "AI Chat History",
                            subtitle: "Stored AI conversation context.",
                            size: aiHistorySize
                        ) {
                            clearAIHistory()
                        }
                    }
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
