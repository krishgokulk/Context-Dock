import Foundation

struct PendingFinderOperation {
    let intent: FinderIntent
    let folderPath: String
}

enum FinderIntent {
    case showRecentFiles(limit: Int)
    case filterFiles(category: FinderFileCategory)
    case organizeByType
}

struct FinderSemanticQueryProfile {
    let originalQuery: String
    let residualQuery: String
    let category: FinderFileCategory?
    let wantsFoldersOnly: Bool
    let wantsFilesOnly: Bool
    let wantsRecent: Bool
    let wantsToday: Bool
    let wantsYesterday: Bool
    let wantsThisWeek: Bool
    let wantsLargeFiles: Bool
    let wantsSmallFiles: Bool
    let explicitLocationPath: String?
    let minSizeBytes: Int64?
    let maxSizeBytes: Int64?

    var hasSemanticConstraint: Bool {
        category != nil || wantsFoldersOnly || wantsFilesOnly || wantsRecent || wantsToday
            || wantsYesterday || wantsThisWeek || wantsLargeFiles || wantsSmallFiles
            || explicitLocationPath != nil || minSizeBytes != nil || maxSizeBytes != nil
    }

    var hasAdvancedDataConstraint: Bool {
        category != nil || wantsFoldersOnly || wantsFilesOnly || wantsRecent || wantsToday
            || wantsYesterday || wantsThisWeek || wantsLargeFiles || wantsSmallFiles
            || explicitLocationPath != nil || minSizeBytes != nil || maxSizeBytes != nil
    }
}

enum FinderFileCategory: CaseIterable {
    case pdf
    case image
    case video
    case audio
    case archive
    case app
    case folder
    case document

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        case .archive: return "archive"
        case .app: return "app"
        case .folder: return "folder"
        case .document: return "document"
        }
    }

    var resultTitle: String {
        switch self {
        case .pdf: return "PDF Files"
        case .image: return "Images"
        case .video: return "Videos"
        case .audio: return "Audio Files"
        case .archive: return "Archives"
        case .app: return "Apps"
        case .folder: return "Folders"
        case .document: return "Documents"
        }
    }

    var destinationFolderName: String {
        switch self {
        case .pdf: return "PDFs"
        case .image: return "Images"
        case .video: return "Videos"
        case .audio: return "Audio"
        case .archive: return "Archives"
        case .app: return "Apps"
        case .folder: return "Folders"
        case .document: return "Documents"
        }
    }

    func matches(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch self {
        case .pdf:
            return ext == "pdf"
        case .image:
            return ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "webp", "svg"].contains(
                ext)
        case .video:
            return ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
        case .audio:
            return ["mp3", "wav", "aac", "m4a", "flac", "aiff"].contains(ext)
        case .archive:
            return ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg", "torrent"]
                .contains(ext)
        case .app:
            return ext == "app"
        case .folder:
            return url.hasDirectoryPath
        case .document:
            return [
                "doc", "docx", "pages", "txt", "md", "rtf", "ppt", "pptx", "xls", "xlsx", "csv",
            ].contains(ext)
        }
    }

    var fileExtensions: Set<String>? {
        switch self {
        case .pdf:
            return ["pdf"]
        case .image:
            return ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "webp", "svg"]
        case .video:
            return ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        case .audio:
            return ["mp3", "wav", "aac", "m4a", "flac", "aiff"]
        case .archive:
            return ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg", "torrent"]
        case .app:
            return ["app"]
        case .document:
            return [
                "doc", "docx", "pages", "txt", "md", "rtf", "ppt", "pptx", "xls", "xlsx", "csv",
            ]
        case .folder:
            return nil
        }
    }

    static func detect(in query: String) -> FinderFileCategory? {
        let normalized = query.lowercased()
        let mappings: [(FinderFileCategory, [String])] = [
            (.pdf, [" pdf", "pdfs", "pdf file", "pdfs from", "pdf files"]),
            (
                .image,
                [
                    "image", "images", "photo", "photos", "picture", "pictures", "screenshot",
                    "screenshots",
                ]
            ),
            (.video, ["video", "videos", "movie", "movies"]),
            (.audio, ["audio", "music", "song", "songs", "mp3"]),
            (
                .archive,
                [
                    "archive", "archives", "zip", "zips", "dmg", "dmgs", "torrent", "torrents",
                    ".torrent",
                ]
            ),
            (.app, ["app", "apps", "application", "applications"]),
            (.folder, ["folder", "folders", "directory", "directories"]),
            (.document, ["document", "documents", "doc", "docs", "text file", "text files"]),
        ]

        for (category, keywords) in mappings {
            if keywords.contains(where: normalized.contains) {
                return category
            }
        }
        return nil
    }
}

struct FinderSemanticMatch {
    let path: String
    let title: String
    let subtitle: String
    let isDirectory: Bool
    let score: Double
    let source: String
    let searchTerms: [String]
    var sizeBytes: Int64? = nil
}
