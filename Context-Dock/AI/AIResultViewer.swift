//
//  AIResultViewer.swift
//  ILauncher
//
//  Rich result viewer for AI extension responses
//  Displays structured data (events, emails, photos, etc.) beautifully
//

import SwiftUI
import AppKit
import Photos

// MARK: - Structured Result Types

struct StructuredResult: Codable, Identifiable {
    let id = UUID()
    let type: String
    let query: String?
    let timeframe: String?
    let status: String?
    let results: [ResultItem]
    let count: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type, query, timeframe, status, results, count, error
    }
}

struct ResultItem: Codable, Identifiable {
    var id: String { title + (date ?? "") + type + (path ?? "") }

    let type: String
    let title: String
    let subtitle: String?
    let date: String?
    let start: String?
    let location: String?
    let from: String?
    let preview: String?
    let modified: String?
    let list: String?
    let completed: Bool?
    let dueDate: String?
    let width: Int?
    let height: Int?
    let localId: String?

    // File-specific fields
    let path: String?
    let directory: String?
    let `extension`: String?
    let size: String?

    // Computed properties for display
    var displayTitle: String {
        title
    }

    var displaySubtitle: String {
        // File-specific subtitle
        if type == "file" || type == "folder" {
            var parts: [String] = []
            if let size = size, !size.isEmpty {
                parts.append(size)
            }
            if let dir = directory, !dir.isEmpty {
                // Shorten home directory
                let shortDir = dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                parts.append(shortDir)
            }
            if !parts.isEmpty {
                return parts.joined(separator: " • ")
            }
        }

        // Original subtitle logic
        if let from = from {
            return "From: \(from)"
        } else if let location = location, !location.isEmpty {
            return location
        } else if let list = list {
            return list
        } else if let preview = preview {
            return String(preview.prefix(100))
        } else if let subtitle = subtitle {
            return subtitle
        }
        return ""
    }

    var displayDate: String? {
        date ?? start ?? modified ?? dueDate
    }

    var icon: String {
        switch type {
        case "event": return "calendar"
        case "note": return "note.text"
        case "email": return "envelope.fill"
        case "photo": return "photo"
        case "reminder": return completed == true ? "checkmark.circle.fill" : "circle"
        case "file": return fileIcon
        case "folder": return "folder.fill"
        default: return "doc"
        }
    }

    // Smart file icon based on extension
    var fileIcon: String {
        guard let ext = `extension`?.lowercased() else { return "doc" }

        switch ext {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "gif", "heic": return "photo"
        case "mp4", "mov", "avi": return "film"
        case "mp3", "m4a", "wav": return "music.note"
        case "zip", "tar", "gz": return "archivebox"
        case "txt", "md": return "doc.text"
        case "doc", "docx": return "doc.richtext"
        case "xls", "xlsx": return "tablecells"
        case "ppt", "pptx": return "play.rectangle"
        case "swift", "py", "js", "cpp", "java": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    var iconColor: Color {
        switch type {
        case "event": return .blue
        case "note": return .yellow
        case "email": return .blue
        case "photo": return .pink
        case "reminder": return completed == true ? .green : .orange
        case "file": return fileColor
        case "folder": return .blue
        default: return .gray
        }
    }

    var fileColor: Color {
        guard let ext = `extension`?.lowercased() else { return .gray }

        switch ext {
        case "pdf": return .red
        case "jpg", "jpeg", "png", "gif", "heic": return .pink
        case "mp4", "mov", "avi": return .purple
        case "mp3", "m4a", "wav": return .orange
        case "zip", "tar", "gz": return .gray
        case "txt", "md": return .blue
        case "doc", "docx": return .blue
        case "xls", "xlsx": return .green
        case "ppt", "pptx": return .orange
        case "swift", "py", "js", "cpp", "java": return .cyan
        default: return .gray
        }
    }
}

// MARK: - AI Result Viewer Component

struct AIResultViewer: View {
    let jsonString: String
    @State private var structuredResult: StructuredResult?
    @State private var parseError: String?

    var body: some View {
        Group {
            if let error = parseError {
                errorView(error)
            } else if let result = structuredResult {
                resultView(result)
            } else {
                loadingView
            }
        }
        .onAppear {
            parseJSON()
        }
    }

    // MARK: - Views

    private var loadingView: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.7)
            Text("Loading results...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func errorView(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func resultView(_ result: StructuredResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: typeIcon(result.type))
                    .foregroundColor(typeColor(result.type))
                Text("\(result.count) \(result.type)")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                if let query = result.query, !query.isEmpty {
                    Text("'\(query)'")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                }
            }

            // Results content
            if result.results.isEmpty {
                emptyStateView(result)
            } else if result.type.lowercased() == "photos" {
                photoResultsView(result.results)
            } else {
                resultsListView(result.results)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }

    private func emptyStateView(_ result: StructuredResult) -> some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            Text("No results found")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func resultsListView(_ items: [ResultItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.prefix(10)) { item in
                resultItemView(item)
            }

            if items.count > 10 {
                Text("...and \(items.count - 10) more")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func photoResultsView(_ items: [ResultItem]) -> some View {
        PhotoGridView(items: items)
    }

    // MARK: - Photo Grid for Photos Results

    struct PhotoGridView: View {
        let items: [ResultItem]

        @State private var showAll = false

        private var photoItems: [ResultItem] {
            items.filter { $0.localId != nil }
        }

        private var visibleItems: [ResultItem] {
            let base = photoItems
            if showAll || base.count <= 10 {
                return base
            }
            return Array(base.prefix(10))
        }

        // 5 columns → 2 rows for the first 10 items
        private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(visibleItems) { item in
                        if let localId = item.localId {
                            PhotoThumbnailView(localIdentifier: localId)
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                                .cornerRadius(6)
                        }
                    }
                }

                if photoItems.count > 10 {
                    Button(action: { withAnimation { showAll.toggle() } }) {
                        Text(showAll ? "Show less" : "Show more")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
    }

    struct PhotoThumbnailView: View {
        let localIdentifier: String

        @State private var image: NSImage?

        var body: some View {
            Group {
                if let image = image {
                    Image(nsImage: image)
                        .resizable()
                } else {
                    Rectangle()
                        .opacity(0.1)
                }
            }
            .onAppear(perform: load)
        }

        private func load() {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = assets.firstObject else { return }

            let manager = PHImageManager.default()
            let targetSize = CGSize(width: 80, height: 80)
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isSynchronous = false

            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { nsImage, _ in
                if let nsImage = nsImage {
                    self.image = nsImage
                }
            }
        }
    }

    private func resultItemView(_ item: ResultItem) -> some View {
        Button(action: {
            handleItemAction(item)
        }) {
            HStack(alignment: .top, spacing: 12) {
                // Icon
                Image(systemName: item.icon)
                    .font(.system(size: 20))
                    .foregroundColor(item.iconColor)
                    .frame(width: 32, height: 32)
                    .background(item.iconColor.opacity(0.1))
                    .cornerRadius(8)

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    if !item.displaySubtitle.isEmpty {
                        Text(item.displaySubtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    if let date = item.displayDate, !date.isEmpty {
                        Text(formatDate(date))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Action buttons for files
                if item.type == "file" || item.type == "folder" {
                    fileActionButtons(item)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func fileActionButtons(_ item: ResultItem) -> some View {
        HStack(spacing: 4) {
            // Reveal in Finder button
            Button(action: {
                revealInFinder(item)
            }) {
                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
    }

    private func handleItemAction(_ item: ResultItem) {
        switch item.type {
        case "file", "folder":
            if let path = item.path {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        default:
            break
        }
    }

    private func revealInFinder(_ item: ResultItem) {
        guard let path = item.path else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    // MARK: - Helpers

    private func parseJSON() {
        guard let data = jsonString.data(using: .utf8) else {
            parseError = "Invalid JSON data"
            return
        }

        do {
            let decoder = JSONDecoder()
            structuredResult = try decoder.decode(StructuredResult.self, from: data)
        } catch {
            print("JSON Parse Error: \(error)")
            parseError = "Failed to parse results"
        }
    }

    private func typeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "calendar_events", "events": return "calendar"
        case "notes": return "note.text"
        case "mail": return "envelope.fill"
        case "photos": return "photo.on.rectangle"
        case "reminders": return "checklist"
        case "files": return "doc.on.doc"
        case "folders": return "folder"
        default: return "doc.text"
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "calendar_events", "events": return .blue
        case "notes": return .yellow
        case "mail": return .blue
        case "photos": return .pink
        case "reminders": return .orange
        case "files": return .blue
        case "folders": return .cyan
        default: return .gray
        }
    }

    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }

        // Try simple date format (YYYY-MM-DD)
        let simpleDateFormatter = DateFormatter()
        simpleDateFormatter.dateFormat = "yyyy-MM-dd"
        if let date = simpleDateFormatter.date(from: dateString) {
            simpleDateFormatter.dateStyle = .medium
            simpleDateFormatter.timeStyle = .none
            return simpleDateFormatter.string(from: date)
        }

        // Try date with time (YYYY-MM-DD HH:mm)
        simpleDateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = simpleDateFormatter.date(from: dateString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }

        return dateString
    }
}

// MARK: - Preview

struct AIResultViewer_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Calendar events preview
            AIResultViewer(jsonString: """
            {
                "type": "calendar_events",
                "query": "meeting",
                "timeframe": "today",
                "results": [
                    {
                        "title": "Project Review Meeting",
                        "start": "2025-12-06 14:00",
                        "location": "Conference Room A",
                        "type": "event"
                    },
                    {
                        "title": "Team Standup",
                        "start": "2025-12-06 09:00",
                        "location": "Zoom",
                        "type": "event"
                    }
                ],
                "count": 2
            }
            """)

            // Notes preview
            AIResultViewer(jsonString: """
            {
                "type": "notes",
                "query": "vacation",
                "results": [
                    {
                        "title": "Vacation Planning",
                        "modified": "2025-12-05",
                        "preview": "Need to book flights and hotel...",
                        "type": "note"
                    }
                ],
                "count": 1
            }
            """)
        }
        .frame(width: 600)
        .padding()
    }
}
