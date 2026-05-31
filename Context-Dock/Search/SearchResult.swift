import AppKit
import Foundation

// MARK: - Search Result Model

struct SearchResult: Identifiable {
    let id = UUID()
    let title: String
    let titleLower: String      // cached — avoids repeated lowercased() in hot path
    let subtitle: String
    let icon: NSImage?
    let action: () -> Void
    var score: Double = 0.0
    let type: ResultType
    let filePath: String?  // For files and folders
    let contactData: ContactData?  // For contacts
    var displayBadges: [String] = []
    var showsTypeLabel: Bool = true
    var dismissesLauncher: Bool = true
    var dragProvider: (() -> NSItemProvider?)? = nil

    init(
        title: String, subtitle: String, icon: NSImage?,
        action: @escaping () -> Void, score: Double = 0.0,
        type: ResultType, filePath: String?, contactData: ContactData?,
        displayBadges: [String] = [],
        showsTypeLabel: Bool = true,
        dismissesLauncher: Bool = true,
        dragProvider: (() -> NSItemProvider?)? = nil
    ) {
        self.title = title
        self.titleLower = title.lowercased()
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
        self.score = score
        self.type = type
        self.filePath = filePath
        self.contactData = contactData
        self.displayBadges = displayBadges
        self.showsTypeLabel = showsTypeLabel
        self.dismissesLauncher = dismissesLauncher
        self.dragProvider = dragProvider
    }

    // Unique identifier for usage tracking (e.g., app bundle ID, file path, contact ID)
    nonisolated var trackingIdentifier: String {
        switch type {
        case .application:
            return "app:\(subtitle)"  // subtitle contains the full path
        case .shortcut:
            return "shortcut:\(title)"
        case .file, .folder, .document:
            return "file:\(filePath ?? subtitle)"
        case .contact:
            return "contact:\(contactData?.identifier ?? title)"
        case .calendarEvent:
            return "calendar:\(title)"
        case .reminder:
            return "reminder:\(title)"
        case .note:
            return "note:\(title)"
        case .mail:
            return "mail:\(title)"
        case .photo:
            return "photo:\(title)"
        case .message:
            return "message:\(title)"
        case .extensionCommand:
            return "extension:\(title)"
        case .webSearch:
            return "web:\(title)"
        case .cliTool:
            return "cli:\(title)"
        }
    }

    enum ResultType: Sendable {
        case application
        case shortcut
        case file
        case folder
        case document
        case contact
        case calendarEvent
        case reminder
        case note
        case mail
        case photo
        case message
        case extensionCommand
        case webSearch
        case cliTool  // installed CLI/TUI tool (from TerminalPackageManager)
    }

    struct ContactData {
        let primaryEmail: String
        let allEmails: [String]
        let primaryPhone: String
        let allPhones: [String]
        let identifier: String
    }
}

// MARK: - Shortcut Metadata

struct ShortcutMetadata {
    let acceptsFiles: Bool
    let acceptsText: Bool
    let acceptsImages: Bool
    let acceptsContacts: Bool
    let acceptsPDFs: Bool
    let fileExtensions: [String]  // e.g., ["pdf", "docx", "png"]

    nonisolated func matches(context: UserContext) -> Bool {
        switch context {
        case .filesSelected(let urls):
            if acceptsFiles {
                if fileExtensions.isEmpty { return true }
                return urls.contains { url in
                    let ext = url.pathExtension.lowercased()
                    return fileExtensions.contains(ext)
                }
            }
            if acceptsImages {
                return urls.contains { url in
                    ["jpg", "jpeg", "png", "gif", "heic"].contains(url.pathExtension.lowercased())
                }
            }
            if acceptsPDFs {
                return urls.contains { $0.pathExtension.lowercased() == "pdf" }
            }
            return false
        case .textSelected:
            return acceptsText
        case .url:
            return acceptsText  // URLs can be treated as text input
        case .contactSelected:
            return acceptsContacts
        case .appFocused, .none:
            return false
        }
    }
}

// JSON decodable version
struct ShortcutMetadataJSON: Codable {
    let acceptsFiles: Bool
    let acceptsText: Bool
    let acceptsImages: Bool
    let acceptsContacts: Bool
    let acceptsPDFs: Bool
    let fileExtensions: [String]
}

// MARK: - Result Grouping

struct GroupedResults {
    var pinnedResults: [SearchResult] = []
    var pinnedSectionTitle: String?
    var suggestedShortcuts: [SearchResult] = []  // Context-aware suggestions
    var shortcuts: [SearchResult] = []
    var apps: [SearchResult] = []
    var files: [SearchResult] = []
    var contacts: [SearchResult] = []
    var system: [SearchResult] = []  // Calendar, Reminders, Notes, Mail, Messages
    var commands: [SearchResult] = []  // Extension commands
    var webResults: [SearchResult] = []  // Web search results

    nonisolated var allResults: [SearchResult] {
        pinnedResults + apps + commands + shortcuts + suggestedShortcuts + system + contacts + files
            + webResults
    }

    nonisolated var isEmpty: Bool {
        allResults.isEmpty
    }

    nonisolated mutating func add(_ result: SearchResult, isSuggested: Bool = false) {
        if isSuggested && result.type == .shortcut {
            suggestedShortcuts.append(result)
            return
        }

        switch result.type {
        case .extensionCommand:
            commands.append(result)
        case .shortcut:
            shortcuts.append(result)
        case .application:
            apps.append(result)
        case .file, .folder, .document, .photo:
            files.append(result)
        case .contact:
            contacts.append(result)
        case .calendarEvent, .reminder, .note, .mail, .message:
            system.append(result)
        case .webSearch:
            webResults.append(result)
        case .cliTool:
            apps.append(result)  // CLI tools appear in the Applications section
        }
    }

    nonisolated var sections: [(String, [SearchResult])] {
        var result: [(String, [SearchResult])] = []
        if !pinnedResults.isEmpty {
            result.append((pinnedSectionTitle ?? "Top Results", pinnedResults))
        }
        if !apps.isEmpty { result.append(("Applications", apps)) }
        if !commands.isEmpty { result.append(("Commands", commands)) }
        if !shortcuts.isEmpty { result.append(("Shortcuts", shortcuts)) }
        if !suggestedShortcuts.isEmpty { result.append(("Suggestions", suggestedShortcuts)) }
        if !system.isEmpty { result.append(("Calendar & Notes", system)) }
        if !contacts.isEmpty { result.append(("Contacts", contacts)) }
        if !files.isEmpty { result.append(("Files & Folders", files)) }
        if !webResults.isEmpty { result.append(("Web Results", webResults)) }
        return result
    }
}
