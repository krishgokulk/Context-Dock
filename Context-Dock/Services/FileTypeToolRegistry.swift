// FileTypeToolRegistry.swift
// ILauncher
//
// Maps file extensions → CLI tools that can process them.
// Layer 1: Curated built-in map (shipped with app)
// Layer 2: Auto-registered from installed binaries (BinaryWatcherService)
// Layer 3: User-explicit additions (persisted via UserDefaults)

import Foundation
import SwiftUI
import Combine

// MARK: - Models

struct FileToolEntry: Codable, Identifiable, Equatable {
    var id: String { toolName }          // toolName is the unique key
    var toolName: String
    var extensions: [String]             // e.g. ["mp4", "mkv", "avi"]
    var category: ToolCategory
    var description: String
    var usageHint: String                // brief usage shown in AI prompt
    var isUserAdded: Bool
    var isInstalled: Bool = false        // computed at runtime
    var brewName: String? = nil          // optional override; falls back to brewLookup

    /// Brew package to install this tool (nil for macOS built-ins / tools not in Homebrew).
    var effectiveBrewName: String? {
        if let override = brewName { return override }
        return FileToolEntry.brewLookup[toolName]
    }

    // Maps CLI binary name → Homebrew formula
    private static let brewLookup: [String: String] = [
        "ffmpeg": "ffmpeg", "ffprobe": "ffmpeg",
        "yt-dlp": "yt-dlp",
        "HandBrakeCLI": "handbrake",
        "mediainfo": "mediainfo",
        "sox": "sox",
        "lame": "lame",
        "flac": "flac",
        "opusenc": "opus",
        "id3v2": "id3v2",
        "eyeD3": "eyed3",
        "convert": "imagemagick", "magick": "imagemagick",
        "exiftool": "exiftool",
        "cwebp": "webp", "dwebp": "webp",
        "pngcrush": "pngcrush",
        "jpegoptim": "jpegoptim",
        "optipng": "optipng",
        "vips": "vips",
        "pandoc": "pandoc",
        "gs": "ghostscript",
        "calibre": "calibre",
        "pdftk": "pdftk-java",
        "pdfinfo": "poppler", "pdftotext": "poppler", "pdftoppm": "poppler",
        "mutool": "mupdf",
        "qpdf": "qpdf",
        "rg": "ripgrep",
        "jq": "jq",
        "csvkit": "csvkit",
        "xlsx2csv": "xlsx2csv",
        "sqlite3": "sqlite",
        "zip": "zip", "unzip": "unzip",
        "p7zip": "p7zip", "7za": "p7zip",
        "unrar": "rar",
    ]

    enum ToolCategory: String, Codable, CaseIterable {
        case video      = "Video"
        case audio      = "Audio"
        case image      = "Image"
        case document   = "Document"
        case archive    = "Archive"
        case code       = "Code"
        case data       = "Data"
        case ebook      = "eBook"
        case threed     = "3D"
        case font       = "Font"
        case other      = "Other"

        var systemImage: String {
            switch self {
            case .video:    return "film"
            case .audio:    return "waveform"
            case .image:    return "photo"
            case .document: return "doc.text"
            case .archive:  return "archivebox"
            case .code:     return "chevron.left.forwardslash.chevron.right"
            case .data:     return "tablecells"
            case .ebook:    return "book"
            case .threed:   return "cube"
            case .font:     return "textformat"
            case .other:    return "wrench.and.screwdriver"
            }
        }
    }
}

// MARK: - Registry

@MainActor
class FileTypeToolRegistry: ObservableObject {
    static let shared = FileTypeToolRegistry()

    @Published var entries: [FileToolEntry] = []

    private let userDefaultsKey = "FileTypeToolRegistry_v2"

    private init() {
        load()
        // Defer install-status scan so it doesn't block app launch
        Task { self.refreshInstallStatus() }
    }

    // MARK: - Query API

    /// Returns all tools that can handle the given file extension.
    func tools(for fileExtension: String) -> [FileToolEntry] {
        let ext = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return entries.filter { $0.extensions.contains(ext) }
    }

    /// Returns all tools that can handle any extension in the set.
    func tools(forAnyOf extensions: [String]) -> [FileToolEntry] {
        let exts = Set(extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        return entries.filter { !Set($0.extensions).intersection(exts).isEmpty }
    }

    /// Builds a concise AI system prompt snippet for a given file extension.
    func systemPromptSnippet(for fileExtension: String) -> String {
        let tools = tools(for: fileExtension).filter { $0.isInstalled }
        guard !tools.isEmpty else { return "" }

        let lines = tools.map { t -> String in
            "- \(t.toolName): \(t.usageHint)"
        }.joined(separator: "\n")

        return """

        Installed CLI tools for .\(fileExtension) files (use via run_command):
        \(lines)
        """
    }

    /// Builds a snippet covering multiple extensions (e.g. for a folder).
    func systemPromptSnippet(forAnyOf extensions: [String]) -> String {
        let matchedTools = tools(forAnyOf: extensions).filter { $0.isInstalled }
        guard !matchedTools.isEmpty else { return "" }

        // Group by category
        var byCategory: [FileToolEntry.ToolCategory: [FileToolEntry]] = [:]
        for tool in matchedTools {
            byCategory[tool.category, default: []].append(tool)
        }

        var sections: [String] = []
        for (cat, catTools) in byCategory.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let lines = catTools.map { "  - \($0.toolName): \($0.usageHint)" }.joined(separator: "\n")
            sections.append("\(cat.rawValue):\n\(lines)")
        }
        return "\n\nInstalled file-processing CLI tools:\n" + sections.joined(separator: "\n")
    }

    // MARK: - Intent-Based Tool Suggestion

    /// Query intent keywords → tool categories that would help.
    private static let intentToCategories: [(words: [String], categories: [FileToolEntry.ToolCategory])] = [
        (["compress", "encode", "convert", "trim", "clip", "transcode",
          "video", "mp4", "mkv", "mov", "avi"],              [.video]),
        (["audio", "mp3", "m4a", "wav", "flac", "extract audio",
          "convert audio", "sound"],                          [.audio]),
        (["image", "photo", "picture", "resize", "compress image",
          "png", "jpg", "jpeg", "webp", "heic"],              [.image]),
        (["pdf", "word", "docx", "convert doc", "pages"],    [.document]),
        (["zip", "unzip", "archive", "extract", "tar", "compress file"], [.archive]),
        (["ebook", "epub", "mobi", "kindle"],                 [.ebook]),
    ]

    /// Returns not-installed tools from the catalog that match the query intent.
    /// Used to proactively suggest `brew install X` before the AI wastes a turn.
    func suggestMissingTools(for query: String, maxCount: Int = 2) -> [FileToolEntry] {
        let q = query.lowercased()
        var categories = Set<FileToolEntry.ToolCategory>()
        for entry in Self.intentToCategories {
            if entry.words.contains(where: { q.contains($0) }) {
                entry.categories.forEach { categories.insert($0) }
            }
        }
        guard !categories.isEmpty else { return [] }

        // Find tools in those categories that are NOT installed
        let missing = entries.filter {
            categories.contains($0.category) && !$0.isInstalled
        }

        // Prefer tools with short, well-known names (ffmpeg over HandBrakeCLI for brevity)
        let prioritised = missing.sorted { $0.toolName.count < $1.toolName.count }
        return Array(prioritised.prefix(maxCount))
    }

    // MARK: - Auto-register from binary watcher

    /// Called by BinaryWatcherService when a new binary is detected.
    /// Cross-references tool name against built-in catalog; if found, marks it installed.
    func autoRegister(toolName: String) {
        if let idx = entries.firstIndex(where: { $0.toolName == toolName }) {
            entries[idx].isInstalled = true
            save()
        }
    }

    /// Full install-status refresh (called on init and after package changes).
    func refreshInstallStatus() {
        let fm = FileManager.default
        let binPaths = ["/usr/bin",                          // macOS built-ins (sips, afconvert, etc.)
                        "/opt/homebrew/bin", "/opt/homebrew/sbin",
                        "/usr/local/bin", NSHomeDirectory() + "/.local/bin",
                        NSHomeDirectory() + "/.cargo/bin"]
        var installed = Set<String>()
        for dir in binPaths {
            if let contents = try? fm.contentsOfDirectory(atPath: dir) {
                contents.forEach { installed.insert($0) }
            }
        }
        for i in entries.indices {
            entries[i].isInstalled = installed.contains(entries[i].toolName)
        }
        // Don't save here — install status is computed, not persisted
    }

    // MARK: - User Mutations

    func addUserEntry(_ entry: FileToolEntry) {
        if let idx = entries.firstIndex(where: { $0.toolName == entry.toolName }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        save()
        refreshInstallStatus()
    }

    func removeUserEntry(toolName: String) {
        entries.removeAll { $0.toolName == toolName && $0.isUserAdded }
        save()
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        load()
        refreshInstallStatus()
    }

    // MARK: - Persistence

    private func save() {
        let userEntries = entries.filter { $0.isUserAdded }
        if let data = try? JSONEncoder().encode(userEntries) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func load() {
        // Start from built-in catalog
        var all = Self.builtInCatalog

        // Overlay user-saved entries
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let saved = try? JSONDecoder().decode([FileToolEntry].self, from: data) {
            for userEntry in saved {
                if let idx = all.firstIndex(where: { $0.toolName == userEntry.toolName }) {
                    all[idx] = userEntry // user overrides built-in
                } else {
                    all.append(userEntry)
                }
            }
        }
        entries = all
    }
}

// MARK: - Built-in Catalog (Layer 1)

extension FileTypeToolRegistry {
    static var builtInCatalog: [FileToolEntry] {
        [
            // ── VIDEO ─────────────────────────────────────────────────────────
            .init(toolName: "ffmpeg",
                  extensions: ["mp4","mkv","avi","mov","wmv","flv","webm","m4v","ts","mts","m2ts","3gp","ogv","vob"],
                  category: .video,
                  description: "FFmpeg — convert, trim, compress, or extract audio from video files",
                  usageHint: "convert/trim/compress video (e.g. ffmpeg -i in.mp4 -vcodec libx264 out.mp4)",
                  isUserAdded: false),

            .init(toolName: "ffprobe",
                  extensions: ["mp4","mkv","avi","mov","wmv","flv","webm","m4v","mp3","flac","aac","wav"],
                  category: .video,
                  description: "FFprobe — inspect video/audio metadata and stream info",
                  usageHint: "inspect media info (e.g. ffprobe -v quiet -print_format json -show_format file.mp4)",
                  isUserAdded: false),

            .init(toolName: "yt-dlp",
                  extensions: ["url","webloc"],
                  category: .video,
                  description: "yt-dlp — download videos from YouTube and 1000+ sites",
                  usageHint: "download video (e.g. yt-dlp -f best URL)",
                  isUserAdded: false),

            .init(toolName: "HandBrakeCLI",
                  extensions: ["mp4","mkv","avi","mov","m4v","ts"],
                  category: .video,
                  description: "HandBrake CLI — encode/compress video files",
                  usageHint: "compress video (e.g. HandBrakeCLI -i input.mkv -o output.mp4 --preset=\"Fast 1080p30\")",
                  isUserAdded: false),

            .init(toolName: "mediainfo",
                  extensions: ["mp4","mkv","avi","mov","mp3","flac","aac","wav","m4a"],
                  category: .video,
                  description: "MediaInfo — detailed technical info about media files",
                  usageHint: "show media details (e.g. mediainfo --Output=JSON file.mp4)",
                  isUserAdded: false),

            // ── VIDEO (macOS built-ins) ───────────────────────────────────────
            .init(toolName: "avconvert",
                  extensions: ["mp4","mov","m4v","m4a","mp3","aac","wav","aiff","caf"],
                  category: .video,
                  description: "macOS avconvert — built-in AV Foundation media converter (always available)",
                  usageHint: "convert media (e.g. avconvert --source input.mov --output output.mp4 --preset AVAssetExportPresetHighestQuality)",
                  isUserAdded: false),

            .init(toolName: "avmediainfo",
                  extensions: ["mp4","mov","m4v","m4a","mp3","aac","wav","aiff","heic"],
                  category: .video,
                  description: "macOS avmediainfo — show detailed media file info (always available)",
                  usageHint: "show media info (e.g. avmediainfo file.mp4)",
                  isUserAdded: false),

            .init(toolName: "avmetareadwrite",
                  extensions: ["mp4","mov","m4v","m4a","mp3","aac"],
                  category: .video,
                  description: "macOS avmetareadwrite — read/write media file metadata (always available)",
                  usageHint: "read/write metadata (e.g. avmetareadwrite -r file.mp4 or avmetareadwrite -w file.mp4 metadata.txt)",
                  isUserAdded: false),

            // ── AUDIO (macOS built-ins) ───────────────────────────────────────
            .init(toolName: "afconvert",
                  extensions: ["aiff","aif","wav","caf","m4a","mp3","flac","au","sd2","ac3"],
                  category: .audio,
                  description: "macOS afconvert — built-in Core Audio format converter (always available)",
                  usageHint: "convert audio (e.g. afconvert -f m4af -d aac input.wav output.m4a)",
                  isUserAdded: false),

            .init(toolName: "afinfo",
                  extensions: ["aiff","aif","wav","caf","m4a","mp3","flac","au","sd2","aac"],
                  category: .audio,
                  description: "macOS afinfo — show audio file properties (always available)",
                  usageHint: "show audio info (e.g. afinfo file.wav)",
                  isUserAdded: false),

            .init(toolName: "afplay",
                  extensions: ["aiff","aif","wav","m4a","mp3","caf","flac","aac"],
                  category: .audio,
                  description: "macOS afplay — play audio files from terminal (always available)",
                  usageHint: "play audio (e.g. afplay file.mp3 or afplay -t 5 file.wav for first 5 seconds)",
                  isUserAdded: false),

            // ── AUDIO CONVERTER (ILauncher built-in wrapper) ──────────────────
            .init(toolName: "audio-convert",
                  extensions: ["webm","mp4","mov","mkv","avi","m4v","flv","ts",  // video sources
                                "mp3","m4a","aac","wav","flac","ogg","opus","wma","aiff","caf","au"],
                  category: .audio,
                  description: "audio-convert — convert any audio/video file to mp3, m4a, wav, flac, ogg, opus, alac",
                  usageHint: "audio-convert \"file.webm\" mp3  |  audio-convert \"file.mp4\" m4a  |  audio-convert \"file.wav\" flac",
                  isUserAdded: false),

            // ── AUDIO ─────────────────────────────────────────────────────────
            .init(toolName: "sox",
                  extensions: ["wav","aiff","au","flac","mp3","ogg","m4a"],
                  category: .audio,
                  description: "SoX — convert, trim, mix, or apply effects to audio files",
                  usageHint: "convert/process audio (e.g. sox input.wav output.mp3 trim 0 30)",
                  isUserAdded: false),

            .init(toolName: "lame",
                  extensions: ["wav","mp3"],
                  category: .audio,
                  description: "LAME — encode WAV to MP3",
                  usageHint: "encode to MP3 (e.g. lame -V 2 input.wav output.mp3)",
                  isUserAdded: false),

            .init(toolName: "flac",
                  extensions: ["flac","wav","aiff"],
                  category: .audio,
                  description: "FLAC encoder/decoder",
                  usageHint: "encode/decode FLAC (e.g. flac -d file.flac)",
                  isUserAdded: false),

            .init(toolName: "opusenc",
                  extensions: ["wav","flac","aiff"],
                  category: .audio,
                  description: "Opus encoder — compress audio with Opus codec",
                  usageHint: "encode to Opus (e.g. opusenc --bitrate 128 input.wav output.opus)",
                  isUserAdded: false),

            .init(toolName: "id3v2",
                  extensions: ["mp3"],
                  category: .audio,
                  description: "id3v2 — read/write MP3 ID3 tags",
                  usageHint: "edit MP3 tags (e.g. id3v2 -t \"Title\" -a \"Artist\" file.mp3)",
                  isUserAdded: false),

            .init(toolName: "eyeD3",
                  extensions: ["mp3"],
                  category: .audio,
                  description: "eyeD3 — read/write/remove MP3 ID3 tags",
                  usageHint: "manage MP3 tags (e.g. eyeD3 --title \"Song\" file.mp3)",
                  isUserAdded: false),

            // ── IMAGE ─────────────────────────────────────────────────────────
            .init(toolName: "convert",
                  extensions: ["jpg","jpeg","png","gif","bmp","tiff","tif","webp","svg","heic","heif","avif","psd"],
                  category: .image,
                  description: "ImageMagick convert — convert, resize, crop, and transform images",
                  usageHint: "convert/resize/crop image (e.g. convert input.png -resize 800x600 output.jpg)",
                  isUserAdded: false),

            .init(toolName: "magick",
                  extensions: ["jpg","jpeg","png","gif","bmp","tiff","webp","svg","heic","avif","psd"],
                  category: .image,
                  description: "ImageMagick 7 — all-in-one image processing",
                  usageHint: "process image (e.g. magick input.heic -quality 85 output.jpg)",
                  isUserAdded: false),

            .init(toolName: "sips",
                  extensions: ["jpg","jpeg","png","tiff","heic","gif","bmp","webp"],
                  category: .image,
                  description: "macOS sips — built-in macOS image processing (always available)",
                  usageHint: "resize/convert image (e.g. sips -z 600 800 photo.jpg --out resized.jpg)",
                  isUserAdded: false),

            .init(toolName: "exiftool",
                  extensions: ["jpg","jpeg","png","tiff","heic","mp4","mov","avi","pdf","psd","xmp"],
                  category: .image,
                  description: "ExifTool — read/write/remove image and media EXIF metadata",
                  usageHint: "read/write metadata (e.g. exiftool -json file.jpg or exiftool -Author=\"\" file.jpg)",
                  isUserAdded: false),

            .init(toolName: "cwebp",
                  extensions: ["png","jpg","jpeg","tiff","bmp"],
                  category: .image,
                  description: "cwebp — convert images to WebP format",
                  usageHint: "convert to WebP (e.g. cwebp -q 80 input.png -o output.webp)",
                  isUserAdded: false),

            .init(toolName: "dwebp",
                  extensions: ["webp"],
                  category: .image,
                  description: "dwebp — decode WebP images to PNG/other formats",
                  usageHint: "decode WebP (e.g. dwebp input.webp -o output.png)",
                  isUserAdded: false),

            .init(toolName: "pngcrush",
                  extensions: ["png"],
                  category: .image,
                  description: "pngcrush — losslessly compress PNG files",
                  usageHint: "compress PNG (e.g. pngcrush -reduce input.png output.png)",
                  isUserAdded: false),

            .init(toolName: "jpegoptim",
                  extensions: ["jpg","jpeg"],
                  category: .image,
                  description: "jpegoptim — compress JPEG files",
                  usageHint: "compress JPEG (e.g. jpegoptim --max=85 photo.jpg)",
                  isUserAdded: false),

            .init(toolName: "optipng",
                  extensions: ["png"],
                  category: .image,
                  description: "OptiPNG — optimize PNG files",
                  usageHint: "optimize PNG (e.g. optipng -o5 image.png)",
                  isUserAdded: false),

            .init(toolName: "vips",
                  extensions: ["jpg","jpeg","png","tiff","webp","heic","avif"],
                  category: .image,
                  description: "libvips — fast large-image processing",
                  usageHint: "process image (e.g. vips resize input.jpg output.jpg 0.5)",
                  isUserAdded: false),

            // ── IMAGE (macOS built-ins) ───────────────────────────────────────
            .init(toolName: "tiff2icns",
                  extensions: ["tiff","tif"],
                  category: .image,
                  description: "macOS tiff2icns — convert TIFF to .icns app icon (always available)",
                  usageHint: "make app icon (e.g. tiff2icns -noLarge image.tiff icon.icns)",
                  isUserAdded: false),

            .init(toolName: "tiffutil",
                  extensions: ["tiff","tif"],
                  category: .image,
                  description: "macOS tiffutil — combine, inspect, and fix TIFF files (always available)",
                  usageHint: "combine TIFFs (e.g. tiffutil -cat a.tiff b.tiff -out combined.tiff)",
                  isUserAdded: false),

            .init(toolName: "iconutil",
                  extensions: ["icns","iconset"],
                  category: .image,
                  description: "macOS iconutil — convert .iconset folder ↔ .icns (always available)",
                  usageHint: "create .icns (e.g. iconutil -c icns icon.iconset) or expand (iconutil -c iconset icon.icns)",
                  isUserAdded: false),

            .init(toolName: "qlmanage",
                  extensions: ["jpg","jpeg","png","pdf","heic","tiff","gif","svg","mp4","mov","docx","xlsx","pptx","md"],
                  category: .image,
                  description: "macOS qlmanage — generate Quick Look thumbnails and previews (always available)",
                  usageHint: "generate thumbnail (e.g. qlmanage -t -s 512 -o ~/Desktop file.pdf)",
                  isUserAdded: false),

            // ── DOCUMENT ──────────────────────────────────────────────────────
            .init(toolName: "pandoc",
                  extensions: ["md","markdown","rst","org","tex","html","docx","odt","epub","txt","adoc"],
                  category: .document,
                  description: "Pandoc — convert between document formats",
                  usageHint: "convert document (e.g. pandoc input.md -o output.pdf or pandoc doc.docx -o doc.md)",
                  isUserAdded: false),

            .init(toolName: "pdftotext",
                  extensions: ["pdf"],
                  category: .document,
                  description: "pdftotext (Poppler) — extract text from PDF files",
                  usageHint: "extract PDF text (e.g. pdftotext -layout file.pdf - )",
                  isUserAdded: false),

            .init(toolName: "pdfinfo",
                  extensions: ["pdf"],
                  category: .document,
                  description: "pdfinfo — show PDF metadata and properties",
                  usageHint: "show PDF info (e.g. pdfinfo file.pdf)",
                  isUserAdded: false),

            .init(toolName: "pdftoppm",
                  extensions: ["pdf"],
                  category: .document,
                  description: "pdftoppm — render PDF pages to images",
                  usageHint: "render PDF pages (e.g. pdftoppm -jpeg -r 150 file.pdf page)",
                  isUserAdded: false),

            .init(toolName: "pdfseparate",
                  extensions: ["pdf"],
                  category: .document,
                  description: "pdfseparate — split PDF into individual pages",
                  usageHint: "split PDF pages (e.g. pdfseparate input.pdf page-%d.pdf)",
                  isUserAdded: false),

            .init(toolName: "pdfunite",
                  extensions: ["pdf"],
                  category: .document,
                  description: "pdfunite — merge multiple PDFs into one",
                  usageHint: "merge PDFs (e.g. pdfunite a.pdf b.pdf merged.pdf)",
                  isUserAdded: false),

            .init(toolName: "gs",
                  extensions: ["pdf","ps","eps"],
                  category: .document,
                  description: "Ghostscript — compress, merge, or convert PDF/PS files",
                  usageHint: "process PDF (e.g. gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/ebook -o out.pdf in.pdf)",
                  isUserAdded: false),

            .init(toolName: "tesseract",
                  extensions: ["png","jpg","jpeg","tiff","bmp","pdf"],
                  category: .document,
                  description: "Tesseract OCR — extract text from images",
                  usageHint: "run OCR (e.g. tesseract image.png output txt or tesseract image.png output pdf)",
                  isUserAdded: false),

            .init(toolName: "libreoffice",
                  extensions: ["docx","doc","xlsx","xls","pptx","ppt","odt","ods","odp","rtf","csv"],
                  category: .document,
                  description: "LibreOffice CLI — convert Office documents to PDF and other formats",
                  usageHint: "convert document (e.g. libreoffice --headless --convert-to pdf file.docx)",
                  isUserAdded: false),

            // ── DOCUMENT (macOS built-ins) ────────────────────────────────────
            .init(toolName: "textutil",
                  extensions: ["rtf","rtfd","doc","docx","odt","html","htm","txt","webarchive","wordml"],
                  category: .document,
                  description: "macOS textutil — convert between rich text formats (always available)",
                  usageHint: "convert doc (e.g. textutil -convert html file.rtf or textutil -convert txt file.docx)",
                  isUserAdded: false),

            .init(toolName: "plutil",
                  extensions: ["plist","json","xml"],
                  category: .document,
                  description: "macOS plutil — convert/validate plist and JSON files (always available)",
                  usageHint: "convert plist (e.g. plutil -convert json file.plist or plutil -lint file.plist)",
                  isUserAdded: false),

            .init(toolName: "mdls",
                  extensions: ["jpg","jpeg","png","pdf","mp4","mov","mp3","docx","xlsx","pptx","heic","txt","swift","py"],
                  category: .document,
                  description: "macOS mdls — show Spotlight metadata for any file (always available)",
                  usageHint: "show metadata (e.g. mdls file.jpg or mdls -name kMDItemPixelWidth photo.jpg)",
                  isUserAdded: false),

            // ── ARCHIVE ───────────────────────────────────────────────────────
            .init(toolName: "p7zip",
                  extensions: ["7z","zip","tar","gz","bz2","xz","rar","iso","cab"],
                  category: .archive,
                  description: "7-Zip — compress/extract archives",
                  usageHint: "compress/extract archive (e.g. 7z x archive.7z or 7z a output.7z files/)",
                  isUserAdded: false),

            .init(toolName: "unrar",
                  extensions: ["rar"],
                  category: .archive,
                  description: "unrar — extract RAR archives",
                  usageHint: "extract RAR (e.g. unrar x archive.rar)",
                  isUserAdded: false),

            .init(toolName: "pigz",
                  extensions: ["gz","tar"],
                  category: .archive,
                  description: "pigz — parallel gzip for fast compression",
                  usageHint: "fast gzip (e.g. tar -I pigz -cf output.tar.gz folder/)",
                  isUserAdded: false),

            // ── ARCHIVE (macOS built-ins) ─────────────────────────────────────
            .init(toolName: "ditto",
                  extensions: ["zip","cpgz"],
                  category: .archive,
                  description: "macOS ditto — copy/archive preserving resource forks and metadata (always available)",
                  usageHint: "create zip (e.g. ditto -c -k --keepParent folder/ out.zip) or extract (ditto -x -k archive.zip dest/)",
                  isUserAdded: false),

            .init(toolName: "yaa",
                  extensions: ["yaa","aar"],
                  category: .archive,
                  description: "macOS yaa — Apple Archive format (fast, lossless, macOS 11+) (always available)",
                  usageHint: "create archive (e.g. yaa archive -d folder/ -o output.yaa) or extract (yaa extract -i file.yaa -d dest/)",
                  isUserAdded: false),

            .init(toolName: "xar",
                  extensions: ["xar","pkg"],
                  category: .archive,
                  description: "macOS xar — eXtensible ARchive format used for .pkg files (always available)",
                  usageHint: "list/extract xar (e.g. xar -tf file.xar or xar -xf file.pkg -C dest/)",
                  isUserAdded: false),

            // ── DATA / CODE ───────────────────────────────────────────────────
            .init(toolName: "jq",
                  extensions: ["json"],
                  category: .data,
                  description: "jq — query and transform JSON data",
                  usageHint: "query JSON (e.g. jq '.name' file.json or jq 'keys' file.json)",
                  isUserAdded: false),

            .init(toolName: "yq",
                  extensions: ["yaml","yml"],
                  category: .data,
                  description: "yq — query and edit YAML/JSON/XML/TOML files",
                  usageHint: "query YAML (e.g. yq '.key' file.yaml or yq -i '.version = \"2.0\"' config.yaml)",
                  isUserAdded: false),

            .init(toolName: "xmllint",
                  extensions: ["xml","svg","xhtml","rss","atom"],
                  category: .data,
                  description: "xmllint — validate, format, and query XML files",
                  usageHint: "query/validate XML (e.g. xmllint --xpath '//item/title' feed.xml or xmllint --format file.xml)",
                  isUserAdded: false),

            .init(toolName: "csvkit",
                  extensions: ["csv","tsv"],
                  category: .data,
                  description: "csvkit — inspect, filter, and convert CSV files",
                  usageHint: "inspect CSV (e.g. csvstat data.csv or csvcut -c 1,3 data.csv)",
                  isUserAdded: false),

            .init(toolName: "miller",
                  extensions: ["csv","tsv","json","ndjson"],
                  category: .data,
                  description: "Miller (mlr) — process CSV/TSV/JSON like awk",
                  usageHint: "process data (e.g. mlr --csv filter '$age > 30' data.csv)",
                  isUserAdded: false),

            .init(toolName: "sqlite3",
                  extensions: ["sqlite","sqlite3","db"],
                  category: .data,
                  description: "SQLite3 — query SQLite database files",
                  usageHint: "query SQLite (e.g. sqlite3 db.sqlite \".tables\" or sqlite3 db.sqlite \"SELECT * FROM table\")",
                  isUserAdded: false),

            .init(toolName: "bat",
                  extensions: ["swift","py","js","ts","sh","rb","go","rs","cpp","c","java","md","json","yaml","toml","ini","xml"],
                  category: .code,
                  description: "bat — syntax-highlighted cat replacement",
                  usageHint: "view file with syntax highlighting (e.g. bat file.swift)",
                  isUserAdded: false),

            .init(toolName: "rg",
                  extensions: ["swift","py","js","ts","sh","rb","go","rs","cpp","c","java","md","json","yaml"],
                  category: .code,
                  description: "ripgrep — fast regex search in files",
                  usageHint: "search in file (e.g. rg 'pattern' file.py or rg -l 'TODO' .)",
                  isUserAdded: false),

            .init(toolName: "prettier",
                  extensions: ["js","ts","jsx","tsx","json","css","scss","html","md","yaml"],
                  category: .code,
                  description: "Prettier — format code files",
                  usageHint: "format code (e.g. prettier --write file.js)",
                  isUserAdded: false),

            .init(toolName: "black",
                  extensions: ["py"],
                  category: .code,
                  description: "Black — opinionated Python code formatter",
                  usageHint: "format Python (e.g. black file.py)",
                  isUserAdded: false),

            .init(toolName: "swiftformat",
                  extensions: ["swift"],
                  category: .code,
                  description: "SwiftFormat — format Swift source files",
                  usageHint: "format Swift (e.g. swiftformat file.swift)",
                  isUserAdded: false),

            .init(toolName: "clang-format",
                  extensions: ["c","cpp","h","hpp","m","mm","objc"],
                  category: .code,
                  description: "clang-format — format C/C++/ObjC source code",
                  usageHint: "format C/C++ (e.g. clang-format -i file.cpp)",
                  isUserAdded: false),

            // ── DATA (macOS built-ins) ────────────────────────────────────────
            .init(toolName: "xxd",
                  extensions: ["bin","exe","dmg","dylib","o","a","iso","img","dat","class"],
                  category: .data,
                  description: "macOS xxd — hex dump any binary file (always available)",
                  usageHint: "hex dump (e.g. xxd file.bin | head or xxd -l 256 file.dmg)",
                  isUserAdded: false),

            .init(toolName: "shasum",
                  extensions: ["zip","dmg","pkg","iso","tar","gz","pdf","mp4","ipa","apk"],
                  category: .data,
                  description: "macOS shasum — compute SHA checksums for any file (always available)",
                  usageHint: "checksum (e.g. shasum -a 256 file.dmg or shasum -a 512 file.zip)",
                  isUserAdded: false),

            // ── eBOOK ─────────────────────────────────────────────────────────
            .init(toolName: "ebook-convert",
                  extensions: ["epub","mobi","azw","azw3","fb2","lit","lrf","pdb","pdf","cbz","cbr","djvu"],
                  category: .ebook,
                  description: "Calibre ebook-convert — convert between ebook formats",
                  usageHint: "convert ebook (e.g. ebook-convert input.epub output.mobi)",
                  isUserAdded: false),

            // ── 3D (macOS built-ins) ──────────────────────────────────────────
            .init(toolName: "usdcat",
                  extensions: ["usd","usda","usdc","usdz"],
                  category: .threed,
                  description: "macOS usdcat — inspect/convert USD 3D scene files (always available, macOS 12+)",
                  usageHint: "inspect USD (e.g. usdcat file.usdz or usdcat --flatten scene.usd output.usda)",
                  isUserAdded: false),

            .init(toolName: "usdchecker",
                  extensions: ["usd","usda","usdc","usdz"],
                  category: .threed,
                  description: "macOS usdchecker — validate USD/USDZ 3D scene files (always available, macOS 12+)",
                  usageHint: "validate USD (e.g. usdchecker scene.usdz)",
                  isUserAdded: false),

            .init(toolName: "usdzip",
                  extensions: ["usd","usda","usdc","usdz"],
                  category: .threed,
                  description: "macOS usdzip — package USD assets into .usdz (always available, macOS 12+)",
                  usageHint: "package usdz (e.g. usdzip -r output.usdz scene.usda textures/)",
                  isUserAdded: false),

            // ── 3D ────────────────────────────────────────────────────────────
            .init(toolName: "meshlabserver",
                  extensions: ["stl","obj","ply","off","3ds","dae","fbx"],
                  category: .threed,
                  description: "MeshLab server — process/convert 3D mesh files",
                  usageHint: "process 3D mesh (e.g. meshlabserver -i input.stl -o output.obj)",
                  isUserAdded: false),

            .init(toolName: "openscad",
                  extensions: ["scad","stl"],
                  category: .threed,
                  description: "OpenSCAD — render .scad models to STL",
                  usageHint: "render 3D model (e.g. openscad -o output.stl model.scad)",
                  isUserAdded: false),

            // ── FONT ──────────────────────────────────────────────────────────
            .init(toolName: "fontforge",
                  extensions: ["ttf","otf","woff","woff2","sfd","ufo"],
                  category: .font,
                  description: "FontForge — convert and inspect font files",
                  usageHint: "convert font (e.g. fontforge -c 'Open(argv[1]); Generate(argv[2])' in.ttf out.otf)",
                  isUserAdded: false),

            // ── OTHER (macOS built-ins) ───────────────────────────────────────
            .init(toolName: "say",
                  extensions: ["txt","md","rtf","html","htm"],
                  category: .other,
                  description: "macOS say — text-to-speech, read any text file aloud (always available)",
                  usageHint: "speak text (e.g. say -f file.txt or say -v Samantha 'Hello' -o speech.aiff)",
                  isUserAdded: false),

            .init(toolName: "shortcuts",
                  extensions: ["shortcut"],
                  category: .other,
                  description: "macOS shortcuts — run Apple Shortcuts from terminal (always available, macOS 12+)",
                  usageHint: "run shortcut (e.g. shortcuts run 'My Shortcut' or shortcuts list)",
                  isUserAdded: false),
        ]
    }
}

// MARK: - Settings View

struct FileToolsSettingsView: View {
    @ObservedObject private var registry = FileTypeToolRegistry.shared
    @State private var selectedCategory: FileToolEntry.ToolCategory? = nil
    @State private var showAddSheet = false
    @State private var searchText = ""

    var filteredEntries: [FileToolEntry] {
        var list = registry.entries
        if let cat = selectedCategory { list = list.filter { $0.category == cat } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.toolName.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
                || $0.extensions.contains(where: { $0.contains(q) })
            }
        }
        return list.sorted { a, b in
            if a.isInstalled != b.isInstalled { return a.isInstalled }
            return a.toolName < b.toolName
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("File-Type Tool Registry")
                    .font(.system(size: 18, weight: .bold))
                Text("ILauncher automatically detects installed CLI tools and injects them into the AI's system prompt when you work with matching file types.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 12)

            Divider()

            HStack(spacing: 0) {
                // Left: category sidebar
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: { selectedCategory = nil }) {
                        HStack {
                            Image(systemName: "square.grid.2x2")
                                .frame(width: 16)
                            Text("All Tools")
                            Spacer()
                            let count = registry.entries.filter { $0.isInstalled }.count
                            Text("\(count)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(selectedCategory == nil ? Color.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.vertical, 4)

                    ForEach(FileToolEntry.ToolCategory.allCases, id: \.self) { cat in
                        Button(action: { selectedCategory = cat }) {
                            HStack {
                                Image(systemName: cat.systemImage)
                                    .frame(width: 16)
                                Text(cat.rawValue)
                                Spacer()
                                let count = registry.entries.filter { $0.category == cat && $0.isInstalled }.count
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(selectedCategory == cat ? Color.accentColor.opacity(0.12) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button(action: { registry.refreshInstallStatus() }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(width: 140)
                .padding(.top, 8)

                Divider()

                // Right: tool list
                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                        TextField("Search tools or extensions…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredEntries) { entry in
                                FileToolRow(entry: entry)
                                Divider().padding(.leading, 36)
                            }
                            if filteredEntries.isEmpty {
                                Text("No tools found")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .padding(24)
                            }
                        }
                    }

                    Divider()

                    // Footer
                    HStack {
                        Text("\(registry.entries.filter { $0.isInstalled }.count) of \(registry.entries.count) tools installed")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        let missingBrewable = registry.entries.filter { !$0.isInstalled && $0.effectiveBrewName != nil }
                        if !missingBrewable.isEmpty {
                            Button(action: { installAllMissing(missingBrewable) }) {
                                Label("Install All (\(missingBrewable.count))", systemImage: "arrow.down.circle")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Button(action: { showAddSheet = true }) {
                            Label("Add Custom Tool", systemImage: "plus")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddFileToolSheet { entry in
                registry.addUserEntry(entry)
            }
        }
    }

    private func installAllMissing(_ entries: [FileToolEntry]) {
        Task {
            let brewPath: String
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") {
                brewPath = "/opt/homebrew/bin/brew"
            } else if FileManager.default.fileExists(atPath: "/usr/local/bin/brew") {
                brewPath = "/usr/local/bin/brew"
            } else { return }

            // Deduplicate brew formula names (e.g. ffmpeg covers both ffmpeg + ffprobe)
            let formulae = Array(Set(entries.compactMap { $0.effectiveBrewName }))
            for formula in formulae {
                _ = await Task.detached(priority: .background) { () -> Bool in
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: brewPath)
                    p.arguments = ["install", formula]
                    p.standardOutput = Pipe(); p.standardError = Pipe()
                    guard (try? p.run()) != nil else { return false }
                    p.waitUntilExit()
                    return p.terminationStatus == 0
                }.value
            }
            await BinaryWatcherService.shared.scanNow(skipHelpScan: false)
            await MainActor.run { registry.refreshInstallStatus() }
        }
    }
}

// MARK: - Tool Row

struct FileToolRow: View {
    let entry: FileToolEntry
    @ObservedObject private var registry = FileTypeToolRegistry.shared
    @State private var showInstallSheet = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Install indicator
            Circle()
                .fill(entry.isInstalled ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    Text(entry.toolName)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(entry.isInstalled ? .primary : .secondary)

                    if entry.isUserAdded {
                        Text("custom")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(4)
                    }

                    if !entry.isInstalled {
                        Text("not installed")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Extension chips
                    HStack(spacing: 3) {
                        ForEach(entry.extensions.prefix(6), id: \.self) { ext in
                            Text(".\(ext)")
                                .font(.system(size: 9, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(3)
                        }
                        if entry.extensions.count > 6 {
                            Text("+\(entry.extensions.count - 6)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Text("Usage: \(entry.usageHint)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }

            VStack(alignment: .trailing, spacing: 6) {
                if entry.isUserAdded {
                    Button(action: { registry.removeUserEntry(toolName: entry.toolName) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if !entry.isInstalled {
                    if let brewName = entry.effectiveBrewName {
                        BrewInstallButton(toolName: brewName)
                    }
                    // Always offer other install methods (git clone, cargo, go install, etc.)
                    Button(action: { showInstallSheet = true }) {
                        HStack(spacing: 3) {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 10))
                            Text("Other methods")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showInstallSheet) {
                        ToolInstallSheet(toolName: entry.toolName) { _ in
                            registry.refreshInstallStatus()
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Add Custom Tool Sheet

struct AddFileToolSheet: View {
    var onAdd: (FileToolEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var toolName = ""
    @State private var extensions = ""
    @State private var category: FileToolEntry.ToolCategory = .other
    @State private var description = ""
    @State private var usageHint = ""

    var canAdd: Bool {
        !toolName.trimmingCharacters(in: .whitespaces).isEmpty
        && !extensions.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Custom File Tool")
                .font(.system(size: 15, weight: .bold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Tool name").gridColumnAlignment(.trailing)
                    TextField("e.g. ffmpeg", text: $toolName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text("Extensions").gridColumnAlignment(.trailing)
                    TextField("e.g. mp4, mkv, avi", text: $extensions)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                GridRow {
                    Text("Category").gridColumnAlignment(.trailing)
                    Picker("", selection: $category) {
                        ForEach(FileToolEntry.ToolCategory.allCases, id: \.self) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                GridRow {
                    Text("Description").gridColumnAlignment(.trailing)
                    TextField("What this tool does…", text: $description)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                GridRow {
                    Text("Usage hint").gridColumnAlignment(.trailing)
                    TextField("e.g. convert file (e.g. tool -i in.mp4 out.mp3)", text: $usageHint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Add Tool") {
                    let exts = extensions
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                        .filter { !$0.isEmpty }
                    let entry = FileToolEntry(
                        toolName: toolName.trimmingCharacters(in: .whitespaces),
                        extensions: exts,
                        category: category,
                        description: description.isEmpty ? "\(toolName) - CLI tool" : description,
                        usageHint: usageHint.isEmpty ? "run \(toolName) on file" : usageHint,
                        isUserAdded: true
                    )
                    onAdd(entry)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
