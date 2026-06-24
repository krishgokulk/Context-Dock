//
//  DefaultAppResolver.swift
//  ILauncher
//
//  Detects default macOS apps for file types and suggests app-based actions
//  Works like macOS "Open With" menu - shows all apps that can handle the file
//  Only shows terminal commands when no suitable app is available
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import CoreServices

/// Resolves default applications for file types on macOS
class DefaultAppResolver {
    static let shared = DefaultAppResolver()

    private init() {}

    // MARK: - Data Types

    struct DefaultApp: Identifiable {
        let id = UUID()
        let name: String
        let bundleIdentifier: String
        let path: URL
        let icon: NSImage?
        let capabilities: [AppCapability]

        var displayName: String {
            name.replacingOccurrences(of: ".app", with: "")
        }
    }

    enum AppCapability: String, CaseIterable {
        case open = "Open"
        case view = "View"
        case edit = "Edit"
        case extract = "Extract"
        case compress = "Compress"
        case convert = "Convert"
        case preview = "Preview"
        case print = "Print"
        case share = "Share"

        var icon: String {
            switch self {
            case .open: return "arrow.up.doc"
            case .view: return "eye"
            case .edit: return "pencil"
            case .extract: return "archivebox"
            case .compress: return "archivebox.fill"
            case .convert: return "arrow.triangle.2.circlepath"
            case .preview: return "eye.fill"
            case .print: return "printer"
            case .share: return "square.and.arrow.up"
            }
        }
    }

    struct AppSuggestion: Identifiable {
        let id = UUID()
        let app: DefaultApp
        let capability: AppCapability
        let action: String // e.g., "Unzip with Archive Utility"
        let description: String
        let score: Double // 0-100, higher = more relevant
    }

    // MARK: - Default App Detection

    /// Get the default app for opening a file
    func getDefaultApp(for fileURL: URL) -> DefaultApp? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: fileURL) else {
            return nil
        }

        return createDefaultApp(from: appURL)
    }

    /// Get the default app for a file extension
    func getDefaultApp(forExtension ext: String) -> DefaultApp? {
        // Create a temporary file path with the extension
        let tempURL = URL(fileURLWithPath: "/tmp/temp.\(ext)")

        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: tempURL) else {
            return nil
        }

        return createDefaultApp(from: appURL)
    }

    /// Get all apps that can open a file type - works like macOS "Open With" menu
    func getAllApps(for fileURL: URL) -> [DefaultApp] {
        var apps: [DefaultApp] = []
        var seenBundleIds = Set<String>()

        // Get URLs of all apps that can open this file type using LaunchServices
        if let appURLs = LSCopyApplicationURLsForURL(fileURL as CFURL, .all)?.takeRetainedValue() as? [URL] {
            for appURL in appURLs {
                if let app = createDefaultApp(from: appURL) {
                    // Avoid duplicates
                    if !seenBundleIds.contains(app.bundleIdentifier) {
                        seenBundleIds.insert(app.bundleIdentifier)
                        apps.append(app)
                    }
                }
            }
        }

        // Sort: default app first, then alphabetically
        if let defaultApp = getDefaultApp(for: fileURL) {
            apps.sort { lhs, rhs in
                if lhs.bundleIdentifier == defaultApp.bundleIdentifier { return true }
                if rhs.bundleIdentifier == defaultApp.bundleIdentifier { return false }
                return lhs.name < rhs.name
            }
        }

        return apps
    }

    /// Get all apps that can open files with a specific extension
    func getAllApps(forExtension ext: String) -> [DefaultApp] {
        // Create a temp file reference to query LaunchServices
        let tempURL = URL(fileURLWithPath: "/tmp/temp.\(ext)")
        return getAllApps(for: tempURL)
    }

    /// Structure for "Open With" style suggestions
    struct OpenWithSuggestion: Identifiable {
        let id = UUID()
        let app: DefaultApp
        let isDefault: Bool
        let action: String

        var displayName: String {
            isDefault ? "\(app.displayName) (default)" : app.displayName
        }
    }

    /// Get "Open With" style suggestions for a file - exactly like macOS context menu
    func getOpenWithSuggestions(for fileURL: URL) -> [OpenWithSuggestion] {
        let allApps = getAllApps(for: fileURL)
        let defaultApp = getDefaultApp(for: fileURL)

        return allApps.map { app in
            OpenWithSuggestion(
                app: app,
                isDefault: app.bundleIdentifier == defaultApp?.bundleIdentifier,
                action: "Open with \(app.displayName)"
            )
        }
    }

    /// Get "Open With" suggestions for multiple files
    func getOpenWithSuggestions(for fileURLs: [URL]) -> [OpenWithSuggestion] {
        guard let firstURL = fileURLs.first else { return [] }

        // If all files have same extension, get apps for that extension
        let extensions = Set(fileURLs.map { $0.pathExtension.lowercased() })

        if extensions.count == 1 {
            return getOpenWithSuggestions(for: firstURL)
        } else {
            // For mixed file types, find common apps that can open all types
            var commonApps: [DefaultApp]?

            for url in fileURLs {
                let apps = getAllApps(for: url)
                let bundleIds = Set(apps.map { $0.bundleIdentifier })

                if commonApps == nil {
                    commonApps = apps
                } else {
                    commonApps = commonApps?.filter { bundleIds.contains($0.bundleIdentifier) }
                }
            }

            return (commonApps ?? []).map { app in
                OpenWithSuggestion(
                    app: app,
                    isDefault: false,
                    action: "Open with \(app.displayName)"
                )
            }
        }
    }

    /// Get app suggestions based on file type with capabilities
    func getAppSuggestions(for fileURLs: [URL]) -> [AppSuggestion] {
        guard let firstURL = fileURLs.first else { return [] }

        let fileExtension = firstURL.pathExtension.lowercased()
        var suggestions: [AppSuggestion] = []

        // Get default app
        if let defaultApp = getDefaultApp(for: firstURL) {
            let capability = determineCapability(for: fileExtension, app: defaultApp)
            let action = generateActionName(for: fileExtension, app: defaultApp, capability: capability)

            suggestions.append(AppSuggestion(
                app: defaultApp,
                capability: capability,
                action: action,
                description: "Default app for .\(fileExtension) files",
                score: 100.0
            ))
        }

        // Add specialized apps based on file type
        let specializedSuggestions = getSpecializedAppSuggestions(for: fileExtension, fileURLs: fileURLs)
        suggestions.append(contentsOf: specializedSuggestions)

        // Sort by score
        suggestions.sort { $0.score > $1.score }

        return suggestions
    }

    // MARK: - Specialized App Suggestions

    private func getSpecializedAppSuggestions(for fileExtension: String, fileURLs: [URL]) -> [AppSuggestion] {
        var suggestions: [AppSuggestion] = []

        switch fileExtension {
        // Archive files
        case "zip", "tar", "gz", "7z", "rar", "bz2":
            // Archive Utility (built-in)
            if let archiveApp = findApp(bundleId: "com.apple.archiveutility") {
                suggestions.append(AppSuggestion(
                    app: archiveApp,
                    capability: .extract,
                    action: "Extract with Archive Utility",
                    description: "Built-in macOS archive extractor",
                    score: 95.0
                ))
            }

            // The Unarchiver
            if let unarchiverApp = findApp(bundleId: "com.macpaw.site.theunarchiver") ?? findApp(bundleId: "cx.c3.theunarchiver") {
                suggestions.append(AppSuggestion(
                    app: unarchiverApp,
                    capability: .extract,
                    action: "Extract with The Unarchiver",
                    description: "Supports many archive formats",
                    score: 90.0
                ))
            }

            // Keka
            if let kekaApp = findApp(bundleId: "com.aone.keka") {
                suggestions.append(AppSuggestion(
                    app: kekaApp,
                    capability: .extract,
                    action: "Extract with Keka",
                    description: "Fast archive extraction",
                    score: 85.0
                ))
            }

        // Image files
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff", "svg":
            // Preview (built-in)
            if let previewApp = findApp(bundleId: "com.apple.Preview") {
                suggestions.append(AppSuggestion(
                    app: previewApp,
                    capability: .view,
                    action: "View with Preview",
                    description: "Built-in macOS image viewer",
                    score: 90.0
                ))
            }

            // Photos
            if let photosApp = findApp(bundleId: "com.apple.Photos") {
                suggestions.append(AppSuggestion(
                    app: photosApp,
                    capability: .edit,
                    action: "Edit with Photos",
                    description: "Built-in photo editor",
                    score: 85.0
                ))
            }

            // Pixelmator
            if let pixelmatorApp = findApp(bundleId: "com.pixelmatorteam.pixelmator.x") {
                suggestions.append(AppSuggestion(
                    app: pixelmatorApp,
                    capability: .edit,
                    action: "Edit with Pixelmator Pro",
                    description: "Professional image editing",
                    score: 80.0
                ))
            }

        // PDF files
        case "pdf":
            // Preview (built-in)
            if let previewApp = findApp(bundleId: "com.apple.Preview") {
                suggestions.append(AppSuggestion(
                    app: previewApp,
                    capability: .view,
                    action: "View with Preview",
                    description: "Built-in PDF viewer",
                    score: 95.0
                ))
            }

            // Adobe Acrobat
            if let acrobatApp = findApp(bundleId: "com.adobe.Acrobat.Pro") ?? findApp(bundleId: "com.adobe.Reader") {
                suggestions.append(AppSuggestion(
                    app: acrobatApp,
                    capability: .edit,
                    action: "Edit with Adobe Acrobat",
                    description: "Professional PDF editing",
                    score: 85.0
                ))
            }

        // Video files
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv":
            // QuickTime Player (built-in)
            if let quickTimeApp = findApp(bundleId: "com.apple.QuickTimePlayerX") {
                suggestions.append(AppSuggestion(
                    app: quickTimeApp,
                    capability: .view,
                    action: "Play with QuickTime",
                    description: "Built-in video player",
                    score: 90.0
                ))
            }

            // VLC
            if let vlcApp = findApp(bundleId: "org.videolan.vlc") {
                suggestions.append(AppSuggestion(
                    app: vlcApp,
                    capability: .view,
                    action: "Play with VLC",
                    description: "Plays almost any video format",
                    score: 85.0
                ))
            }

            // IINA
            if let iinaApp = findApp(bundleId: "com.colliderli.iina") {
                suggestions.append(AppSuggestion(
                    app: iinaApp,
                    capability: .view,
                    action: "Play with IINA",
                    description: "Modern macOS video player",
                    score: 85.0
                ))
            }

        // Audio files
        case "mp3", "m4a", "wav", "aac", "flac", "aiff":
            // Music (built-in)
            if let musicApp = findApp(bundleId: "com.apple.Music") {
                suggestions.append(AppSuggestion(
                    app: musicApp,
                    capability: .open,
                    action: "Play with Music",
                    description: "Built-in music player",
                    score: 90.0
                ))
            }

            // VLC
            if let vlcApp = findApp(bundleId: "org.videolan.vlc") {
                suggestions.append(AppSuggestion(
                    app: vlcApp,
                    capability: .view,
                    action: "Play with VLC",
                    description: "Universal media player",
                    score: 80.0
                ))
            }

        // Document files
        case "doc", "docx":
            // Pages (built-in)
            if let pagesApp = findApp(bundleId: "com.apple.iWork.Pages") {
                suggestions.append(AppSuggestion(
                    app: pagesApp,
                    capability: .edit,
                    action: "Edit with Pages",
                    description: "Built-in document editor",
                    score: 85.0
                ))
            }

            // Microsoft Word
            if let wordApp = findApp(bundleId: "com.microsoft.Word") {
                suggestions.append(AppSuggestion(
                    app: wordApp,
                    capability: .edit,
                    action: "Edit with Word",
                    description: "Microsoft Word",
                    score: 90.0
                ))
            }

        // Spreadsheet files
        case "xls", "xlsx", "csv":
            // Numbers (built-in)
            if let numbersApp = findApp(bundleId: "com.apple.iWork.Numbers") {
                suggestions.append(AppSuggestion(
                    app: numbersApp,
                    capability: .edit,
                    action: "Edit with Numbers",
                    description: "Built-in spreadsheet editor",
                    score: 85.0
                ))
            }

            // Microsoft Excel
            if let excelApp = findApp(bundleId: "com.microsoft.Excel") {
                suggestions.append(AppSuggestion(
                    app: excelApp,
                    capability: .edit,
                    action: "Edit with Excel",
                    description: "Microsoft Excel",
                    score: 90.0
                ))
            }

        // Text/Code files
        case "txt", "md", "json", "xml", "html", "css", "js", "swift", "py":
            // TextEdit (built-in)
            if let textEditApp = findApp(bundleId: "com.apple.TextEdit") {
                suggestions.append(AppSuggestion(
                    app: textEditApp,
                    capability: .edit,
                    action: "Edit with TextEdit",
                    description: "Built-in text editor",
                    score: 70.0
                ))
            }

            // VS Code
            if let vscodeApp = findApp(bundleId: "com.microsoft.VSCode") {
                suggestions.append(AppSuggestion(
                    app: vscodeApp,
                    capability: .edit,
                    action: "Edit with VS Code",
                    description: "Popular code editor",
                    score: 90.0
                ))
            }

            // Xcode
            if let xcodeApp = findApp(bundleId: "com.apple.dt.Xcode") {
                suggestions.append(AppSuggestion(
                    app: xcodeApp,
                    capability: .edit,
                    action: "Edit with Xcode",
                    description: "Apple's IDE",
                    score: 85.0
                ))
            }

        default:
            break
        }

        return suggestions
    }

    // MARK: - Terminal Command Suggestions

    /// Returns terminal command suggestions only when no suitable app is found
    func getTerminalSuggestions(for fileExtension: String, fileURLs: [URL]) -> [TerminalSuggestion] {
        var suggestions: [TerminalSuggestion] = []

        switch fileExtension {
        // Archive files
        case "zip":
            suggestions.append(TerminalSuggestion(
                command: "unzip",
                fullCommand: "unzip \"$FILE\"",
                description: "Extract zip archive",
                requiresTool: "unzip",
                isBuiltIn: true
            ))

        case "tar":
            suggestions.append(TerminalSuggestion(
                command: "tar",
                fullCommand: "tar -xvf \"$FILE\"",
                description: "Extract tar archive",
                requiresTool: "tar",
                isBuiltIn: true
            ))

        case "gz", "tgz":
            suggestions.append(TerminalSuggestion(
                command: "tar",
                fullCommand: "tar -xzvf \"$FILE\"",
                description: "Extract gzip archive",
                requiresTool: "tar",
                isBuiltIn: true
            ))

        case "7z":
            suggestions.append(TerminalSuggestion(
                command: "7z",
                fullCommand: "7z x \"$FILE\"",
                description: "Extract 7-zip archive",
                requiresTool: "7z",
                isBuiltIn: false
            ))

        case "rar":
            suggestions.append(TerminalSuggestion(
                command: "unrar",
                fullCommand: "unrar x \"$FILE\"",
                description: "Extract RAR archive",
                requiresTool: "unrar",
                isBuiltIn: false
            ))

        // Image files - for compression/conversion
        case "jpg", "jpeg", "png", "gif", "webp":
            suggestions.append(TerminalSuggestion(
                command: "sips",
                fullCommand: "sips -Z 1024 \"$FILE\"",
                description: "Resize image (built-in)",
                requiresTool: "sips",
                isBuiltIn: true
            ))

            suggestions.append(TerminalSuggestion(
                command: "convert",
                fullCommand: "convert \"$FILE\" -quality 85 \"$OUTPUT\"",
                description: "Compress with ImageMagick",
                requiresTool: "imagemagick",
                isBuiltIn: false
            ))

        // PDF files
        case "pdf":
            suggestions.append(TerminalSuggestion(
                command: "gs",
                fullCommand: "gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dBATCH -sOutputFile=\"$OUTPUT\" \"$FILE\"",
                description: "Compress PDF with Ghostscript",
                requiresTool: "ghostscript",
                isBuiltIn: false
            ))

        // Video files
        case "mp4", "mov", "avi", "mkv":
            suggestions.append(TerminalSuggestion(
                command: "ffmpeg",
                fullCommand: "ffmpeg -i \"$FILE\" -c:v libx264 -crf 23 -c:a aac \"$OUTPUT\"",
                description: "Convert/compress video",
                requiresTool: "ffmpeg",
                isBuiltIn: false
            ))

        default:
            break
        }

        return suggestions
    }

    // MARK: - Helper Methods

    private func createDefaultApp(from appURL: URL) -> DefaultApp? {
        guard let bundle = Bundle(url: appURL),
              let bundleId = bundle.bundleIdentifier else {
            return nil
        }

        let name = appURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)

        return DefaultApp(
            name: name,
            bundleIdentifier: bundleId,
            path: appURL,
            icon: icon,
            capabilities: inferCapabilities(for: bundleId)
        )
    }

    private func findApp(bundleId: String) -> DefaultApp? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }

        return createDefaultApp(from: appURL)
    }

    private func inferCapabilities(for bundleId: String) -> [AppCapability] {
        // Map known apps to their capabilities
        let capabilities: [String: [AppCapability]] = [
            "com.apple.archiveutility": [.extract, .compress],
            "com.apple.Preview": [.view, .edit, .print],
            "com.apple.Photos": [.view, .edit, .share],
            "com.apple.QuickTimePlayerX": [.view, .edit],
            "com.apple.Music": [.open],
            "com.apple.TextEdit": [.edit],
            "org.videolan.vlc": [.view, .convert],
            "com.colliderli.iina": [.view],
        ]

        return capabilities[bundleId] ?? [.open]
    }

    private func determineCapability(for fileExtension: String, app: DefaultApp) -> AppCapability {
        switch fileExtension {
        case "zip", "tar", "gz", "7z", "rar":
            return .extract
        case "jpg", "jpeg", "png", "gif", "pdf":
            return app.capabilities.contains(.view) ? .view : .open
        case "mp4", "mov", "avi", "mkv":
            return .view
        default:
            return .open
        }
    }

    private func generateActionName(for fileExtension: String, app: DefaultApp, capability: AppCapability) -> String {
        switch capability {
        case .extract:
            return "Extract with \(app.displayName)"
        case .view:
            return "View with \(app.displayName)"
        case .edit:
            return "Edit with \(app.displayName)"
        case .compress:
            return "Compress with \(app.displayName)"
        case .convert:
            return "Convert with \(app.displayName)"
        case .preview:
            return "Preview with \(app.displayName)"
        case .print:
            return "Print with \(app.displayName)"
        case .share:
            return "Share with \(app.displayName)"
        default:
            return "Open with \(app.displayName)"
        }
    }

    // MARK: - Open File with App

    /// Open a file with a specific app
    func openFile(_ fileURL: URL, with app: DefaultApp) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: app.path,
            configuration: config
        ) { _, error in
            if let error = error {
                #if DEBUG
                print("Error opening file: \(error.localizedDescription)")
                #endif
            }
        }

        return true
    }

    /// Check if any app exists for a file type
    func hasDefaultApp(for fileURL: URL) -> Bool {
        return NSWorkspace.shared.urlForApplication(toOpen: fileURL) != nil
    }

    /// Check if any app exists for an extension
    func hasDefaultApp(forExtension ext: String) -> Bool {
        let tempURL = URL(fileURLWithPath: "/tmp/temp.\(ext)")
        return NSWorkspace.shared.urlForApplication(toOpen: tempURL) != nil
    }
}

// MARK: - Terminal Suggestion

struct TerminalSuggestion: Identifiable {
    let id = UUID()
    let command: String
    let fullCommand: String
    let description: String
    let requiresTool: String
    let isBuiltIn: Bool

    var displayCommand: String {
        // Format for display
        fullCommand.replacingOccurrences(of: "\"$FILE\"", with: "[file]")
            .replacingOccurrences(of: "\"$OUTPUT\"", with: "[output]")
    }
}
