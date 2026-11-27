// Context-Dock/UI/Plugins/DoraxPackMediaHelpers.swift
// Context-Dock
//
// Reusable .doraxpack v3 media helpers:
// - Async downsampled thumbnail cache & image view for local wallpaper / media grids and detail banners
// - Native macOS NSOpenPanel folder & multi-image file pickers for `directory` / `file` preferences
//   and `pick_folder` / `pick_files` item actions

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Downsampled Local Image Cache

@MainActor
final class DoraxThumbnailCache {
    static let shared = DoraxThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 250
        return c
    }()

    func cachedImage(path: String, maxPixelSize: Int) -> NSImage? {
        let key = "\(path)#\(maxPixelSize)" as NSString
        return cache.object(forKey: key)
    }

    func loadImage(path: String, maxPixelSize: Int) async -> NSImage? {
        let key = "\(path)#\(maxPixelSize)" as NSString
        if let existing = cache.object(forKey: key) {
            return existing
        }
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let sourceOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOpts as CFDictionary) else {
                return NSImage(contentsOf: url)
            }
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize),
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
                return NSImage(contentsOf: url)
            }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value

        if let img {
            cache.setObject(img, forKey: key)
        }
        return img
    }
}

struct DoraxThumbnailImage: View {
    let path: String
    var maxPixelSize: Int = 480
    var cornerRadius: CGFloat = 8

    @State private var loaded: NSImage? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                if let img = loaded ?? DoraxThumbnailCache.shared.cachedImage(path: path, maxPixelSize: maxPixelSize) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: "\(path)#\(maxPixelSize)") {
                loaded = await DoraxThumbnailCache.shared.loadImage(path: path, maxPixelSize: maxPixelSize)
            }
    }
}

// MARK: - Native NSOpenPanel Folder & File Pickers

@MainActor
enum DoraxMediaPickers {
    static func chooseDirectory(title: String = "Choose Folder", initialPath: String? = nil) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.level = .floating
        if let initialPath, !initialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: initialPath).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    static func chooseSingleFile(title: String = "Choose File", initialPath: String? = nil) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.level = .floating
        if let initialPath, !initialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: initialPath).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let dir = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.path) {
                panel.directoryURL = dir
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    static func chooseImageFiles(title: String = "Add Pictures", into destinationDir: URL) -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Add Pictures"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.level = .floating
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return [] }

        let fm = FileManager.default
        try? fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        var copied: [URL] = []
        for src in panel.urls {
            let base = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            var candidate = destinationDir.appendingPathComponent(src.lastPathComponent)
            var counter = 1
            while fm.fileExists(atPath: candidate.path) {
                let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                candidate = destinationDir.appendingPathComponent(name)
                counter += 1
            }
            if (try? fm.copyItem(at: src, to: candidate)) != nil {
                copied.append(candidate)
            }
        }
        return copied
    }
}

// MARK: - Preference Input Row (supports Secret, String, Select, Directory, File, Boolean)

struct DoraxPreferenceEditorRow: View {
    let pref: DoraxPackPreference
    let packID: String

    @State private var value: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(pref.title)
                .frame(width: 130, alignment: .leading)
                .font(.system(size: 12))

            switch pref.type {
            case .secret:
                SecureField(pref.placeholder ?? "Stored in Keychain", text: textBinding)
                    .textFieldStyle(.roundedBorder)
            case .directory:
                TextField(pref.placeholder ?? "Auto-detected or choose folder…", text: textBinding)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    if let picked = DoraxMediaPickers.chooseDirectory(
                        title: pref.title,
                        initialPath: value.isEmpty ? nil : value
                    ) {
                        setValue(picked)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .file:
                TextField(pref.placeholder ?? "Choose file…", text: textBinding)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    if let picked = DoraxMediaPickers.chooseSingleFile(
                        title: pref.title,
                        initialPath: value.isEmpty ? nil : value
                    ) {
                        setValue(picked)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .select:
                if let options = pref.options, !options.isEmpty {
                    Picker("", selection: textBinding) {
                        ForEach(options, id: \.self) { opt in
                            Text(opt).tag(opt)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(pref.placeholder ?? pref.title, text: textBinding)
                        .textFieldStyle(.roundedBorder)
                }
            case .boolean:
                Toggle("", isOn: Binding(
                    get: { value.lowercased() == "true" || value == "1" },
                    set: { setValue($0 ? "true" : "false") }
                ))
                .labelsHidden()
                Spacer()
            case .string:
                TextField(pref.placeholder ?? pref.title, text: textBinding)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .onAppear {
            value = DoraxPackPreferenceStore.value(for: pref, packID: packID) ?? ""
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { value },
            set: { setValue($0) }
        )
    }

    private func setValue(_ newValue: String) {
        value = newValue
        DoraxPackPreferenceStore.setValue(newValue.isEmpty ? nil : newValue, for: pref, packID: packID)
    }
}

// MARK: - Inline Keyboard-Navigable Actions Drawer (`→` / `⌘K`)

enum DoraxSheetActionEntry: Identifiable, Equatable {
    case item(DoraxItemAction)
    case upgradeWithAI
    case configurePack
    case viewLogs(Int)
    case forceRefresh

    var id: String {
        switch self {
        case .item(let a): return "item:\(a.id):\(a.title)"
        case .upgradeWithAI: return "pack:upgrade-ai"
        case .configurePack: return "pack:configure"
        case .viewLogs: return "pack:logs"
        case .forceRefresh: return "pack:refresh"
        }
    }

    var title: String {
        switch self {
        case .item(let a): return a.title
        case .upgradeWithAI: return "Upgrade Pack with AI…"
        case .configurePack: return "Configure Command & Pack"
        case .viewLogs(let count): return "View Pack Logs (\(count))"
        case .forceRefresh: return "Force Refresh"
        }
    }

    var icon: String {
        switch self {
        case .item(let a): return a.icon
        case .upgradeWithAI: return "wand.and.stars"
        case .configurePack: return "slider.horizontal.3"
        case .viewLogs: return "doc.text.magnifyingglass"
        case .forceRefresh: return "arrow.clockwise"
        }
    }

    var shortcut: String? {
        switch self {
        case .item(let a): return a.shortcut
        case .upgradeWithAI: return "⌘E"
        case .configurePack: return "⌘,"
        case .viewLogs: return "⌘L"
        case .forceRefresh: return "⌘R"
        }
    }

    var isDestructive: Bool {
        if case .item(let a) = self { return a.destructive }
        return false
    }

    var isPackSectionStart: Bool {
        if case .upgradeWithAI = self { return true }
        return false
    }
}

struct DoraxInlineActionsDrawer: View {
    let entries: [DoraxSheetActionEntry]
    let itemTitle: String?
    let accentColor: Color
    @Binding var searchText: String
    @Binding var selectedIndex: Int
    let onSelect: (DoraxSheetActionEntry) -> Void
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(itemTitle ?? "Actions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("↑↓ ↵ · Esc")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 4)

            TextField("Search actions…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onKeyPress(.upArrow) {
                    step(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    step(1)
                    return .handled
                }
                .onKeyPress(.return) {
                    runSelected()
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    if searchText.isEmpty {
                        onDismiss()
                        return .handled
                    }
                    return .ignored
                }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                            if entry.isPackSectionStart, idx > 0 {
                                Divider().padding(.vertical, 4)
                            }
                            let isSelected = idx == clampedIndex
                            Button {
                                selectedIndex = idx
                                onSelect(entry)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.icon)
                                        .frame(width: 14)
                                        .foregroundStyle(entry.isDestructive ? .red : accentColor)
                                    Text(entry.title)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(entry.isDestructive ? .red : .primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if let sc = entry.shortcut, !sc.isEmpty {
                                        Text(sc)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected ? accentColor.opacity(0.22) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(entry.id)
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, _ in
                    if let target = currentEntry {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(target.id, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 276, height: 248)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
    }

    private var clampedIndex: Int {
        guard !entries.isEmpty else { return 0 }
        return min(max(0, selectedIndex), entries.count - 1)
    }

    private var currentEntry: DoraxSheetActionEntry? {
        guard !entries.isEmpty else { return nil }
        return entries[clampedIndex]
    }

    private func step(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = min(entries.count - 1, max(0, clampedIndex + delta))
    }

    private func runSelected() {
        guard let target = currentEntry else { return }
        onSelect(target)
    }
}
