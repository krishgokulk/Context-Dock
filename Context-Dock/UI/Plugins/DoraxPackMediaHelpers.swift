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
