//
//  ExtensionModels.swift
//  ILauncher
//
//  Enhanced extension system with layers, tags, and smart discovery
//

import Foundation
import AppKit

// MARK: - Extension Layer
enum ExtensionLayer: String, Codable, CaseIterable {
    case l1_search = "L1"       // Search layer - file/app actions
    case l2_context = "L2"      // Context layer - app-specific shortcuts
    case l3_browser = "L3"      // Browser layer - web enhancements
    case crossLayer = "Cross"   // Works across multiple layers

    var displayName: String {
        switch self {
        case .l1_search: return "File Actions"        // deprecated — use l2_context with fileType trigger
        case .l2_context: return "Context Actions"
        case .l3_browser: return "Web Actions"
        case .crossLayer: return "Automations"
        }
    }

    var description: String {
        switch self {
        case .l1_search: return "Legacy file actions (use Context Actions instead)"
        case .l2_context: return "Auto-appear based on selected files, text, or frontmost app"
        case .l3_browser: return "Browser & webpage enhancements"
        case .crossLayer: return "Workflows that work across multiple apps"
        }
    }

    var icon: String {
        switch self {
        case .l1_search: return "doc.badge.gearshape"
        case .l2_context: return "app.connected.to.app.below.fill"
        case .l3_browser: return "globe"
        case .crossLayer: return "arrow.triangle.branch"
        }
    }
}

// MARK: - Extension Tags
enum ExtensionTag: String, Codable, CaseIterable {
    // Context tags - which app/environment
    case finder, safari, chrome, firefox, edge
    case vscode, xcode, textEdit, notes, mail
    case figma, photoshop, preview

    // Capability tags - what it does
    case fileManipulation, textProcessing, imageProcessing
    case webEnhancement, aiPowered, automation
    case compression, conversion, extraction
    case privacy, productivity, accessibility

    // Scope tags - how it operates
    case singleFile, batchOperation, streaming
    case requiresInternet, offline, background

    var displayName: String {
        rawValue.capitalized.replacingOccurrences(of: "_", with: " ")
    }

    var category: TagCategory {
        switch self {
        case .finder, .safari, .chrome, .firefox, .edge, .vscode, .xcode, .textEdit, .notes, .mail, .figma, .photoshop, .preview:
            return .context
        case .fileManipulation, .textProcessing, .imageProcessing, .webEnhancement, .aiPowered, .automation, .compression, .conversion, .extraction, .privacy, .productivity, .accessibility:
            return .capability
        case .singleFile, .batchOperation, .streaming, .requiresInternet, .offline, .background:
            return .scope
        }
    }

    enum TagCategory {
        case context, capability, scope
    }
}

// MARK: - Extension Trigger Type
enum ExtensionTrigger: Codable, Equatable {
    case keyword([String])              // Triggered by specific keywords
    case fileType([String])             // Triggered by file extensions
    case appContext(String)             // Triggered when specific app is frontmost
    case selection                      // Triggered when files are selected
    case always                         // Always available
    case urlPattern(String)             // For browser extensions - regex pattern

    enum CodingKeys: String, CodingKey {
        case type, value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keyword(let keywords):
            try container.encode("keyword", forKey: .type)
            try container.encode(keywords, forKey: .value)
        case .fileType(let types):
            try container.encode("fileType", forKey: .type)
            try container.encode(types, forKey: .value)
        case .appContext(let app):
            try container.encode("appContext", forKey: .type)
            try container.encode(app, forKey: .value)
        case .selection:
            try container.encode("selection", forKey: .type)
        case .always:
            try container.encode("always", forKey: .type)
        case .urlPattern(let pattern):
            try container.encode("urlPattern", forKey: .type)
            try container.encode(pattern, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "keyword":
            let keywords = try container.decode([String].self, forKey: .value)
            self = .keyword(keywords)
        case "fileType":
            let types = try container.decode([String].self, forKey: .value)
            self = .fileType(types)
        case "appContext":
            let app = try container.decode(String.self, forKey: .value)
            self = .appContext(app)
        case "selection":
            self = .selection
        case "always":
            self = .always
        case "urlPattern":
            let pattern = try container.decode(String.self, forKey: .value)
            self = .urlPattern(pattern)
        default:
            self = .always
        }
    }
}

// MARK: - Extension Intent
struct ExtensionIntent: Codable, Equatable {
    let action: String          // e.g., "compress", "convert", "translate"
    let target: String?         // e.g., "images", "pdfs", "webpage"
    let parameters: [String: String]?

    static func == (lhs: ExtensionIntent, rhs: ExtensionIntent) -> Bool {
        lhs.action == rhs.action && lhs.target == rhs.target
    }
}

// MARK: - Enhanced Extension Model
struct ILExtension: Identifiable, Codable {
    let id: UUID
    var name: String
    var description: String
    var icon: String                    // SF Symbol name

    // Organization
    var layer: ExtensionLayer
    var tags: [ExtensionTag]
    var category: String                // L1: file-actions, L2: browser, L3: page-enhancers

    // Activation
    var triggers: [ExtensionTrigger]
    var intents: [ExtensionIntent]      // What user intents this handles
    var enabled: Bool

    // Script/Implementation
    var scriptPath: String              // Relative path to script
    var scriptContent: String?          // Inline script content
    var scriptType: ScriptType

    // Permissions & Requirements
    var requiresPermissions: [String]   // e.g., ["contacts", "calendar"]
    var requiresInternet: Bool
    var canChain: Bool                  // Can be chained with other extensions

    // Metadata
    var author: String
    var version: String
    var isBuiltIn: Bool                 // Bundled with app vs user-installed
    var lastUsed: Date?
    var usageCount: Int

    enum ScriptType: String, Codable {
        case bash           // Shell script
        case javascript     // For web extensions
        case applescript    // macOS automation
        case python         // Python script
        case swift          // Swift executable
    }

    init(
        id: UUID = UUID(),
        name: String,
        description: String,
        icon: String = "gear",
        layer: ExtensionLayer,
        tags: [ExtensionTag] = [],
        category: String,
        triggers: [ExtensionTrigger] = [.always],
        intents: [ExtensionIntent] = [],
        enabled: Bool = true,
        scriptPath: String = "",
        scriptContent: String? = nil,
        scriptType: ScriptType = .bash,
        requiresPermissions: [String] = [],
        requiresInternet: Bool = false,
        canChain: Bool = false,
        author: String = "ILauncher",
        version: String = "1.0",
        isBuiltIn: Bool = false,
        lastUsed: Date? = nil,
        usageCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.layer = layer
        self.tags = tags
        self.category = category
        self.triggers = triggers
        self.intents = intents
        self.enabled = enabled
        self.scriptPath = scriptPath
        self.scriptContent = scriptContent
        self.scriptType = scriptType
        self.requiresPermissions = requiresPermissions
        self.requiresInternet = requiresInternet
        self.canChain = canChain
        self.author = author
        self.version = version
        self.isBuiltIn = isBuiltIn
        self.lastUsed = lastUsed
        self.usageCount = usageCount
    }

    // MARK: - Intent Matching
    func matchesIntent(_ intent: ExtensionIntent) -> Bool {
        intents.contains(intent)
    }

    func matchesKeyword(_ keyword: String) -> Bool {
        for trigger in triggers {
            if case .keyword(let keywords) = trigger {
                return keywords.contains { keyword.lowercased().contains($0.lowercased()) }
            }
        }
        return false
    }

    func matchesFileType(_ fileExtension: String) -> Bool {
        for trigger in triggers {
            if case .fileType(let types) = trigger {
                return types.contains(fileExtension.lowercased())
            }
        }
        return false
    }

    func matchesContext(frontmostApp: String?) -> Bool {
        guard let app = frontmostApp else { return false }

        for trigger in triggers {
            if case .appContext(let triggerApp) = trigger {
                return app.lowercased().contains(triggerApp.lowercased())
            }
        }
        return false
    }

    // MARK: - Usage Tracking
    mutating func recordUsage() {
        lastUsed = Date()
        usageCount += 1
    }
}

// MARK: - Extension Discovery Result
struct ExtensionDiscoveryResult {
    let ilExtension: ILExtension
    let relevanceScore: Double      // 0.0 - 1.0
    let matchReason: MatchReason

    enum MatchReason {
        case keywordMatch(String)
        case fileTypeMatch(String)
        case contextMatch(String)
        case intentMatch(ExtensionIntent)
        case tagMatch([ExtensionTag])
        case frequentlyUsed
        case alwaysAvailable
    }
}

// MARK: - Extension Chain
struct ExtensionChain: Identifiable {
    let id: UUID
    var name: String
    var extensions: [ILExtension]
    var autoExecute: Bool           // Execute automatically or ask first

    init(id: UUID = UUID(), name: String, extensions: [ILExtension], autoExecute: Bool = false) {
        self.id = id
        self.name = name
        self.extensions = extensions
        self.autoExecute = autoExecute
    }
}

// MARK: - Built-in Extension Templates
extension ILExtension {

    // MARK: L1 Extensions (Search Layer)
    static let compressImages = ILExtension(
        name: "Compress Images",
        description: "Reduce file size of images while maintaining quality",
        icon: "arrow.down.circle",
        layer: .l1_search,
        tags: [.imageProcessing, .compression, .batchOperation],
        category: "file-actions",
        triggers: [
            .keyword(["compress", "reduce", "optimize", "shrink"]),
            .fileType([".jpg", ".jpeg", ".png", ".heic"])
        ],
        intents: [
            ExtensionIntent(action: "compress", target: "images", parameters: nil)
        ],
        scriptPath: "AIExtensions/compress-images.sh",
        scriptType: .bash,
        canChain: true,
        isBuiltIn: true
    )

    static let convertImage = ILExtension(
        name: "Convert Image Format",
        description: "Convert images between formats (JPG, PNG, WebP, HEIC)",
        icon: "arrow.triangle.2.circlepath",
        layer: .l1_search,
        tags: [.imageProcessing, .conversion, .batchOperation],
        category: "file-actions",
        triggers: [
            .keyword(["convert", "format", "webp", "jpg", "png"]),
            .fileType([".jpg", ".jpeg", ".png", ".heic", ".webp"])
        ],
        intents: [
            ExtensionIntent(action: "convert", target: "images", parameters: nil)
        ],
        scriptPath: "AIExtensions/convert-image.sh",
        scriptType: .bash,
        canChain: true,
        isBuiltIn: true
    )

    static let extractTextOCR = ILExtension(
        name: "Extract Text (OCR)",
        description: "Extract text from images using OCR",
        icon: "doc.text.viewfinder",
        layer: .l1_search,
        tags: [.imageProcessing, .extraction, .aiPowered],
        category: "file-actions",
        triggers: [
            .keyword(["ocr", "extract", "text", "read"]),
            .fileType([".jpg", ".jpeg", ".png", ".heic", ".pdf"])
        ],
        intents: [
            ExtensionIntent(action: "extract", target: "text", parameters: nil)
        ],
        scriptPath: "AIExtensions/ocr-extract.sh",
        scriptType: .bash,
        canChain: true,
        isBuiltIn: true
    )

    // MARK: L2 Extensions (Context Layer)
    static let summarizePage = ILExtension(
        name: "Summarize Webpage",
        description: "AI-powered webpage summarization",
        icon: "doc.text.magnifyingglass",
        layer: .l2_context,
        tags: [.safari, .chrome, .aiPowered, .textProcessing, .requiresInternet],
        category: "browser",
        triggers: [
            .keyword(["summarize", "summary", "tldr"]),
            .appContext("Safari")
        ],
        intents: [
            ExtensionIntent(action: "summarize", target: "webpage", parameters: nil)
        ],
        scriptPath: "AIExtensions/summarize-page.sh",
        scriptType: .bash,
        requiresInternet: true,
        isBuiltIn: true
    )

    static let translateSelection = ILExtension(
        name: "Translate Text",
        description: "Translate selected text to any language",
        icon: "character.bubble",
        layer: .l2_context,
        tags: [.textProcessing, .aiPowered, .requiresInternet],
        category: "text-editor",
        triggers: [
            .keyword(["translate", "translation"]),
            .selection
        ],
        intents: [
            ExtensionIntent(action: "translate", target: "text", parameters: nil)
        ],
        scriptPath: "AIExtensions/translate.sh",
        scriptType: .bash,
        requiresInternet: true,
        isBuiltIn: true
    )

    // MARK: L2 Extensions (Safari)
    static let safariCopyURL = ILExtension(
        name: "Safari: Copy Current URL",
        description: "Copies the current Safari tab URL",
        icon: "link",
        layer: .l2_context,
        tags: [.safari, .automation, .productivity],
        category: "browser",
        triggers: [
            .appContext("Safari")
        ],
        scriptContent: """
        tell application "Safari"
            if (count of windows) = 0 then return ""
            set currentTab to current tab of front window
            return URL of currentTab
        end tell
        """,
        scriptType: .applescript,
        isBuiltIn: true
    )

    static let safariCopyTitle = ILExtension(
        name: "Safari: Copy Page Title",
        description: "Copies the current Safari tab title",
        icon: "textformat",
        layer: .l2_context,
        tags: [.safari, .automation, .productivity],
        category: "browser",
        triggers: [
            .appContext("Safari")
        ],
        scriptContent: """
        tell application "Safari"
            if (count of windows) = 0 then return ""
            set currentTab to current tab of front window
            return name of currentTab
        end tell
        """,
        scriptType: .applescript,
        isBuiltIn: true
    )

    static let safariListImages = ILExtension(
        name: "Safari: List Images on Page",
        description: "Returns all image URLs from the current Safari tab",
        icon: "photo.on.rectangle",
        layer: .l2_context,
        tags: [.safari, .automation, .productivity],
        category: "browser",
        triggers: [
            .appContext("Safari")
        ],
        scriptContent: """
        tell application "Safari"
            if (count of windows) = 0 then return ""
            set currentTab to current tab of front window
            set js to "Array.from(document.images).map(i => i.src).join('\\\\n')"
            return do JavaScript js in currentTab
        end tell
        """,
        scriptType: .applescript,
        isBuiltIn: true
    )

    // MARK: L2 Extensions (Messages)
    static let messagesOpenAttachments = ILExtension(
        name: "Messages: Open Attachments Folder",
        description: "Open the Messages attachments folder in Finder",
        icon: "paperclip",
        layer: .l2_context,
        tags: [.automation, .productivity],
        category: "messaging",
        triggers: [
            .appContext("Messages")
        ],
        scriptContent: """
        tell application "Finder"
            open (POSIX file (POSIX path of (path to library folder from user domain) & "Messages/Attachments/"))
            activate
        end tell
        """,
        scriptType: .applescript,
        isBuiltIn: true
    )

    static let messagesSaveAttachments = ILExtension(
        name: "Messages: Save Attachments",
        description: "Copy recent Messages attachments to Desktop folder",
        icon: "square.and.arrow.down",
        layer: .l2_context,
        tags: [.automation, .productivity],
        category: "messaging",
        triggers: [
            .appContext("Messages")
        ],
        scriptContent: """
        #!/bin/bash
        DEST="$HOME/Desktop/MessageAttachments"
        mkdir -p "$DEST"
        SRC="$HOME/Library/Messages/Attachments"
        COUNT=0
        find "$SRC" -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" -o -iname "*.gif" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.pdf" \\) -newer "$DEST" 2>/dev/null | head -50 | while read f; do
            cp "$f" "$DEST/" 2>/dev/null && COUNT=$((COUNT+1))
        done
        SAVED=$(ls "$DEST" | wc -l | tr -d ' ')
        echo "Saved attachments to: $DEST"
        echo "Total files in folder: $SAVED"
        open "$DEST"
        """,
        scriptType: .bash,
        isBuiltIn: true
    )

    static let messagesConvertHEIC = ILExtension(
        name: "Messages: Convert HEIC → JPEG",
        description: "Convert all HEIC images from Messages attachments to JPEG on Desktop",
        icon: "photo.badge.arrow.down",
        layer: .l2_context,
        tags: [.automation, .productivity],
        category: "messaging",
        triggers: [
            .appContext("Messages"),
            .keyword(["heic", "convert", "jpeg"])
        ],
        scriptContent: """
        #!/bin/bash
        DEST="$HOME/Desktop/ConvertedPhotos"
        mkdir -p "$DEST"
        SRC="$HOME/Library/Messages/Attachments"
        COUNT=0
        find "$SRC" -type f -iname "*.heic" 2>/dev/null | head -100 | while read f; do
            BASENAME=$(basename "$f" .heic)
            OUT="$DEST/${BASENAME}.jpg"
            if [ ! -f "$OUT" ]; then
                sips -s format jpeg "$f" --out "$OUT" 2>/dev/null && COUNT=$((COUNT+1))
            fi
        done
        TOTAL=$(ls "$DEST"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
        echo "Converted HEIC files to JPEG"
        echo "Saved to: $DEST ($TOTAL files)"
        open "$DEST"
        """,
        scriptType: .bash,
        isBuiltIn: true
    )

    // MARK: File Operation Extensions (L2 — any file/folder selected)

    static let zipSelected = ILExtension(
        name: "Zip",
        description: "Compress selected file or folder into a .zip archive",
        icon: "archivebox.fill",
        layer: .l2_context,
        tags: [.compression, .fileManipulation],
        category: "file-ops",
        triggers: [.selection, .keyword(["zip", "compress", "archive"])],
        scriptContent: """
        #!/bin/bash
        TARGET="$1"
        if [ -z "$TARGET" ]; then echo "No file provided"; exit 1; fi
        DIR=$(dirname "$TARGET")
        BASE=$(basename "$TARGET")
        NAME="${BASE%.*}"
        OUT="$DIR/$NAME.zip"
        zip -r "$OUT" "$TARGET" && echo "✅ Saved to: $OUT"
        """,
        scriptType: .bash,
        isBuiltIn: true
    )

    static let unzipSelected = ILExtension(
        name: "Unzip",
        description: "Extract a .zip file into a folder",
        icon: "archivebox",
        layer: .l2_context,
        tags: [.extraction, .fileManipulation],
        category: "file-ops",
        triggers: [.fileType(["zip", "gz", "tar"]), .keyword(["unzip", "extract"])],
        scriptContent: """
        #!/bin/bash
        TARGET="$1"
        if [ -z "$TARGET" ]; then echo "No file provided"; exit 1; fi
        DIR=$(dirname "$TARGET")
        BASE=$(basename "$TARGET")
        NAME="${BASE%.*}"
        OUT="$DIR/${NAME}_extracted"
        mkdir -p "$OUT"
        unzip -o "$TARGET" -d "$OUT" && echo "✅ Extracted to: $OUT"
        """,
        scriptType: .bash,
        isBuiltIn: true
    )

    static let openInTerminal = ILExtension(
        name: "Open in Terminal",
        description: "Open a Terminal window at this file's location",
        icon: "terminal.fill",
        layer: .l2_context,
        tags: [.automation],
        category: "file-ops",
        triggers: [.selection, .keyword(["terminal", "shell", "open terminal"])],
        scriptContent: """
        #!/bin/bash
        TARGET="$1"
        if [ -d "$TARGET" ]; then DIR="$TARGET"; else DIR=$(dirname "$TARGET"); fi
        open -a Terminal "$DIR"
        """,
        scriptType: .bash,
        isBuiltIn: true
    )

    static let showFileSize = ILExtension(
        name: "File Size",
        description: "Show disk size of selected file or folder",
        icon: "externaldrive.fill",
        layer: .l2_context,
        tags: [.fileManipulation],
        category: "file-ops",
        triggers: [.selection, .keyword(["size", "how big", "disk usage", "folder size"])],
        scriptContent: """
        #!/bin/bash
        TARGET="$1"
        if [ -z "$TARGET" ]; then echo "No file provided"; exit 1; fi
        du -sh "$TARGET"
        """,
        scriptType: .bash,
        isBuiltIn: true
    )

    // MARK: L3 Extensions (Browser Layer)
    static let darkModeWeb = ILExtension(
        name: "Dark Mode",
        description: "Apply dark theme to any webpage",
        icon: "moon.fill",
        layer: .l3_browser,
        tags: [.webEnhancement, .accessibility, .offline],
        category: "page-enhancers",
        triggers: [
            .urlPattern(".*"),
            .keyword(["dark", "night"])
        ],
        scriptContent: """
        (function() {
            const style = document.createElement('style');
            style.textContent = `
                * { background-color: #1a1a1a !important; color: #e0e0e0 !important; }
                img, video { opacity: 0.8; }
            `;
            document.head.appendChild(style);
        })();
        """,
        scriptType: .javascript,
        isBuiltIn: true
    )

    static let removeAds = ILExtension(
        name: "Remove Ads",
        description: "Block ads and tracking scripts",
        icon: "shield.fill",
        layer: .l3_browser,
        tags: [.webEnhancement, .privacy, .offline],
        category: "privacy",
        triggers: [
            .urlPattern(".*"),
            .keyword(["ad", "block", "privacy"])
        ],
        scriptContent: """
        (function() {
            const adSelectors = ['.ad', '.ads', '[class*="advertisement"]', '#ad', '[id*="google_ads"]'];
            adSelectors.forEach(selector => {
                document.querySelectorAll(selector).forEach(el => el.remove());
            });
        })();
        """,
        scriptType: .javascript,
        isBuiltIn: true
    )

    // MARK: - All Built-in Extensions
    static var allBuiltIn: [ILExtension] {
        return [
            // L1 Extensions
            compressImages,
            convertImage,
            extractTextOCR,

            // L2 Extensions
            translateSelection,
            safariCopyURL,
            safariCopyTitle,
            safariListImages,
            messagesOpenAttachments,
            messagesSaveAttachments,
            messagesConvertHEIC,
            zipSelected,
            unzipSelected,
            openInTerminal,
            showFileSize,

            // L3 Extensions
            darkModeWeb,
            removeAds
        ]
    }
}

// MARK: - AI Import Schema

enum ContextDockAIImportError: LocalizedError {
    case emptyPayload
    case invalidKind
    case invalidVersion(String)
    case missingName
    case missingAction
    case missingScript
    case missingOpenURL

    var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "Paste a Context-Dock extension JSON payload first."
        case .invalidKind:
            return "The JSON is not a Context-Dock extension payload."
        case .invalidVersion(let version):
            return "Unsupported Context-Dock extension version: \(version)"
        case .missingName:
            return "The extension name is required."
        case .missingAction:
            return "The action type is required."
        case .missingScript:
            return "The payload is missing script content."
        case .missingOpenURL:
            return "The payload is missing an open_url target."
        }
    }
}

struct ContextDockAIImportPayload: Codable {
    struct Placement: Codable {
        var quick_action: Bool
        var context_dock: Bool
        var automation: Bool
    }

    struct Visibility: Codable {
        struct ShowWhen: Codable {
            var requires_url: Bool
            var requires_selected_text: Bool
            var requires_clipboard_text: Bool
            var requires_files: Bool
            var requires_current_file: Bool
        }

        var apps: [String]
        var bundle_ids: [String]
        var show_when: ShowWhen
    }

    struct Action: Codable {
        var type: String
        var script: String
        var open_url: String
    }

    struct Inputs: Codable {
        var use_current_url: Bool
        var use_selected_text: Bool
        var use_clipboard_text: Bool
        var use_selected_files: Bool
        var use_current_file: Bool
        var use_current_app: Bool
        var use_current_bundle_id: Bool
        var use_window_title: Bool
    }

    struct Requirements: Codable {
        var apps: [String]
        var cli_tools: [String]
        var notes: String
    }

    struct Output: Codable {
        var success_message: String
        var failure_message: String
    }

    var version: String
    var kind: String
    var name: String
    var description: String
    var category: String
    var placement: Placement
    var visibility: Visibility
    var action: Action
    var inputs: Inputs
    var requirements: Requirements
    var output: Output

    static func decode(from text: String) throws -> ContextDockAIImportPayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ContextDockAIImportError.emptyPayload }
        let data = Data(trimmed.utf8)
        let decoder = JSONDecoder()
        let payload = try decoder.decode(ContextDockAIImportPayload.self, from: data)
        try payload.validate()
        return payload
    }

    func validate() throws {
        guard version == "1.0" else { throw ContextDockAIImportError.invalidVersion(version) }
        guard kind == "context_dock_extension" else { throw ContextDockAIImportError.invalidKind }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextDockAIImportError.missingName
        }

        let actionType = action.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !actionType.isEmpty else { throw ContextDockAIImportError.missingAction }
        if actionType == "open_url" {
            guard !action.open_url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ContextDockAIImportError.missingOpenURL
            }
        } else {
            guard !action.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ContextDockAIImportError.missingScript
            }
        }
    }

    func makeILExtension() -> ILExtension {
        let layer = inferredLayer
        let scriptBody = normalizedScriptBody()
        let scriptType = normalizedLayeredScriptType(for: layer)
        let keywords = inferredKeywords
        let triggers = inferredTriggers(keywords: keywords)

        return ILExtension(
            name: name,
            description: description.isEmpty ? "Imported from AI" : description,
            icon: inferredIcon,
            layer: layer,
            tags: inferredTags,
            category: inferredCategory(for: layer),
            triggers: triggers,
            intents: [],
            enabled: true,
            scriptPath: scriptType == .javascript ? "script.js" : "script.\(scriptType.fileExtension)",
            scriptContent: scriptBody,
            scriptType: scriptType,
            requiresPermissions: inferredPermissions,
            requiresInternet: requiresInternet,
            canChain: placement.automation,
            author: "AI Import",
            version: version,
            isBuiltIn: false
        )
    }

    func makeLegacyToolExtension(using settings: AppSettings = .shared) -> AppToolExtension? {
        guard let language = legacyScriptLanguage else { return nil }

        let sanitizedName = sanitizedFileStem
        let scriptBody = normalizedScriptBody()
        let savedPath = settings.saveScript(
            appKey: preferredLegacyAppKey,
            name: sanitizedName,
            language: language,
            code: scriptBody
        ) ?? ""

        let hintSections = [
            description,
            requirements.notes,
            requirements.cli_tools.isEmpty ? "" : "Requires: \(requirements.cli_tools.joined(separator: ", "))",
            output.success_message.isEmpty ? "" : "Success: \(output.success_message)"
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return AppToolExtension(
            appKey: preferredLegacyAppKey,
            toolName: name,
            toolPath: savedPath,
            aiHint: hintSections.joined(separator: "\n"),
            profile: AppToolProfile(
                capabilities: inferredKeywords,
                exampleCommands: [],
                fileTypes: [],
                isDestructive: false
            ),
            kind: .script,
            scriptLanguage: language,
            scriptCode: scriptBody
        )
    }

    var preferredAutomationCategory: AutomationCategory {
        if action.type.lowercased() == "open_url" || visibility.show_when.requires_url {
            return .appActions
        }
        return .scripts
    }

    private var inferredLayer: ExtensionLayer {
        if placement.automation {
            return .crossLayer
        }
        if visibility.show_when.requires_url || visibility.apps.contains(where: { Self.isBrowserName($0) }) {
            return .l3_browser
        }
        return .l2_context
    }

    private func inferredCategory(for layer: ExtensionLayer) -> String {
        switch layer {
        case .l3_browser:
            switch category.lowercased() {
            case "privacy": return "privacy"
            case "media": return "extractors"
            case "productivity", "communication", "notes": return "productivity"
            default: return "page-enhancers"
            }
        case .l2_context:
            if visibility.apps.contains(where: { Self.isBrowserName($0) }) { return "browser" }
            if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["finder", "com.apple.finder"]) { return "finder" }
            if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["mail", "com.apple.mail"]) { return "mail" }
            if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["xcode", "com.apple.dt.xcode", "vscode", "visual studio code", "com.microsoft.vscode"]) { return "code-editor" }
            if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["notes", "textedit", "com.apple.notes", "com.apple.textedit"]) { return "text-editor" }
            return "custom"
        case .l1_search:
            return "file-actions"
        case .crossLayer:
            return "automation"
        }
    }

    private var inferredIcon: String {
        switch category.lowercased() {
        case "browser": return "globe"
        case "notes": return "note.text"
        case "media": return "play.rectangle"
        case "developer": return "chevron.left.forwardslash.chevron.right"
        case "communication": return "bubble.left.and.bubble.right"
        case "files": return "doc"
        case "automation": return "bolt.badge.automatic"
        default: return visibility.show_when.requires_url ? "globe" : "sparkles"
        }
    }

    private var inferredTags: [ExtensionTag] {
        var tags: [ExtensionTag] = [.automation]
        if visibility.apps.contains(where: { $0.localizedCaseInsensitiveContains("Safari") }) { tags.append(.safari) }
        if visibility.apps.contains(where: { $0.localizedCaseInsensitiveContains("Chrome") }) { tags.append(.chrome) }
        if visibility.apps.contains(where: { $0.localizedCaseInsensitiveContains("Finder") }) { tags.append(.finder) }
        if visibility.apps.contains(where: { $0.localizedCaseInsensitiveContains("Mail") }) { tags.append(.mail) }
        if visibility.apps.contains(where: { $0.localizedCaseInsensitiveContains("Notes") }) { tags.append(.notes) }
        if visibility.apps.contains(where: { $0.localizedCaseInsensitiveContains("Xcode") }) { tags.append(.xcode) }
        if visibility.apps.contains(where: { $0.localizedCaseInsensitiveContains("Code") }) { tags.append(.vscode) }
        if visibility.show_when.requires_files || visibility.show_when.requires_current_file { tags.append(.fileManipulation) }
        if visibility.show_when.requires_selected_text || visibility.show_when.requires_clipboard_text { tags.append(.textProcessing) }
        if visibility.show_when.requires_url { tags.append(.webEnhancement) }
        if !requirements.cli_tools.isEmpty { tags.append(.offline) }
        if requiresInternet { tags.append(.requiresInternet) }
        return Array(Set(tags))
    }

    private var inferredPermissions: [String] {
        var permissions: [String] = []
        if visibility.show_when.requires_selected_text { permissions.append("accessibility") }
        if visibility.show_when.requires_url { permissions.append("browser") }
        if action.type.lowercased() == "applescript" || action.type.lowercased() == "jxa" {
            permissions.append("automation")
        }
        return permissions
    }

    private var inferredKeywords: [String] {
        let baseWords = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        let categoryWord = category.lowercased()
        let appWords = visibility.apps.map { $0.lowercased() }
        return Array(Set(baseWords + [categoryWord] + appWords)).sorted()
    }

    private func inferredTriggers(keywords: [String]) -> [ExtensionTrigger] {
        var triggers: [ExtensionTrigger] = []
        if !keywords.isEmpty {
            triggers.append(.keyword(keywords))
        }
        for app in visibility.apps where !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            triggers.append(.appContext(app))
        }
        if visibility.show_when.requires_files || visibility.show_when.requires_current_file || visibility.show_when.requires_selected_text {
            triggers.append(.selection)
        }
        if visibility.show_when.requires_url {
            triggers.append(.urlPattern(".*"))
        }
        if triggers.isEmpty {
            triggers = [.always]
        }
        return triggers
    }

    private var requiresInternet: Bool {
        visibility.show_when.requires_url || category.lowercased() == "browser"
    }

    private var legacyScriptLanguage: AppScriptLanguage? {
        switch action.type.lowercased() {
        case "shell", "open_url":
            return .bash
        case "python":
            return .python
        case "applescript":
            return .applescript
        case "jxa":
            return .jxa
        default:
            return nil
        }
    }

    private func normalizedLayeredScriptType(for layer: ExtensionLayer) -> ILExtension.ScriptType {
        switch action.type.lowercased() {
        case "python":
            return .python
        case "applescript":
            return .applescript
        case "javascript":
            return layer == .l3_browser ? .javascript : .bash
        default:
            return .bash
        }
    }

    private func normalizedScriptBody() -> String {
        let rawType = action.type.lowercased()
        switch rawType {
        case "open_url":
            let target = action.open_url.trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            #!/usr/bin/env bash
            set -euo pipefail

            TARGET='\(target.replacingOccurrences(of: "'", with: "'\"'\"'"))'
            open "$TARGET"
            echo "\(output.success_message.isEmpty ? "Opened target URL" : output.success_message.replacingOccurrences(of: "\"", with: "\\\""))"
            """
        case "jxa":
            let trimmed = action.script.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#!/usr/bin/env osascript -l JavaScript") {
                return trimmed
            }
            return """
            #!/usr/bin/env osascript -l JavaScript
            \(trimmed)
            """
        case "javascript":
            let trimmed = action.script.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed
        default:
            return action.script.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var preferredLegacyAppKey: String {
        if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["com.apple.safari", "safari"]) { return "safari" }
        if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["com.google.chrome", "chrome"]) { return "chrome" }
        if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["com.apple.finder", "finder"]) { return "finder" }
        if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["com.apple.mail", "mail"]) { return "mail" }
        if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["com.apple.notes", "notes"]) { return "notes" }
        if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["com.apple.dt.xcode", "xcode"]) { return "xcode" }
        if matchesAny(bundleIDs: visibility.bundle_ids, names: visibility.apps, against: ["com.microsoft.vscode", "visual studio code", "vscode"]) { return "vscode" }
        return "global"
    }

    private var sanitizedFileStem: String {
        let base = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return base.isEmpty ? "imported-extension" : base
    }

    private func matchesAny(bundleIDs: [String], names: [String], against values: [String]) -> Bool {
        let haystack = (bundleIDs + names.map { $0.lowercased() })
        return haystack.contains { candidate in
            values.contains { candidate.localizedCaseInsensitiveContains($0) || $0.localizedCaseInsensitiveContains(candidate) }
        }
    }

    private static func isBrowserName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("safari") || lower.contains("chrome") || lower.contains("arc") || lower.contains("firefox") || lower.contains("edge")
    }
}

// MARK: - Simple AI Import (new prompt-based format)

enum SimpleAIImportError: LocalizedError {
    case emptyPayload
    case invalidJSON(String)
    case noExtensions

    var errorDescription: String? {
        switch self {
        case .emptyPayload:       return "Paste a JSON extension payload first."
        case .invalidJSON(let m): return "JSON parse error: \(m)"
        case .noExtensions:       return "No extensions found in the payload."
        }
    }
}

/// Decodes the simplified JSON schema produced by Context Dock's AI extension prompt.
struct SimpleAIExtensionImport: Codable {

    struct TriggerSpec: Codable {
        var type: String
        var value: String?
    }

    struct ExtensionSpec: Codable {
        var id: String?
        var name: String
        var description: String
        var icon: String?
        var layer: String
        var tags: [String]?
        var triggers: [TriggerSpec]
        var scriptType: String
        var script: String
        var permissions: [String]?
        var outputMode: String?
        var version: String?
    }

    var version: String
    var source: String?
    var extensions: [ExtensionSpec]

    // MARK: Decode

    static func decode(from text: String) throws -> SimpleAIExtensionImport {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown code fences if present
        if json.hasPrefix("```") {
            let lines = json.components(separatedBy: .newlines)
            json = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !json.isEmpty else { throw SimpleAIImportError.emptyPayload }
        guard let data = json.data(using: .utf8) else { throw SimpleAIImportError.emptyPayload }
        do {
            let payload = try JSONDecoder().decode(SimpleAIExtensionImport.self, from: data)
            guard !payload.extensions.isEmpty else { throw SimpleAIImportError.noExtensions }
            return payload
        } catch let e as SimpleAIImportError { throw e }
        catch { throw SimpleAIImportError.invalidJSON(error.localizedDescription) }
    }

    // MARK: Convert

    func toILExtensions() -> [ILExtension] {
        extensions.map { spec in
            let layer    = parseLayer(spec.layer)
            let sType    = parseScriptType(spec.scriptType)
            let triggers = spec.triggers.compactMap { parseTrigger($0) }
            let tags     = (spec.tags ?? []).compactMap { ExtensionTag(rawValue: $0) }

            return ILExtension(
                name:               spec.name,
                description:        spec.description,
                icon:               spec.icon ?? "gear",
                layer:              layer,
                tags:               tags,
                category:           inferCategory(layer: layer, tags: spec.tags ?? []),
                triggers:           triggers.isEmpty ? [.always] : triggers,
                enabled:            true,
                scriptPath:         "script.\(sType.fileExtension)",
                scriptContent:      spec.script,
                scriptType:         sType,
                requiresPermissions: spec.permissions ?? [],
                requiresInternet:   (spec.permissions ?? []).contains("network"),
                author:             "AI Import",
                version:            spec.version ?? "1.0",
                isBuiltIn:          false
            )
        }
    }

    // MARK: Private helpers

    private func parseLayer(_ s: String) -> ExtensionLayer {
        switch s.uppercased().trimmingCharacters(in: .whitespaces) {
        case "L1": return .l1_search
        case "L2": return .l2_context
        case "L3": return .l3_browser
        case "CROSSLAYER", "CROSS", "CROSS-LAYER": return .crossLayer
        default:   return .l2_context
        }
    }

    private func parseScriptType(_ s: String) -> ILExtension.ScriptType {
        switch s.lowercased() {
        case "bash", "sh", "shell": return .bash
        case "python", "python3":   return .python
        case "applescript":         return .applescript
        case "javascript", "js":    return .javascript
        case "swift":               return .swift
        default:                    return .bash
        }
    }

    private func parseTrigger(_ spec: TriggerSpec) -> ExtensionTrigger? {
        switch spec.type {
        case "keyword":    return spec.value.map { .keyword([$0]) }
        case "fileType":   return spec.value.map { .fileType([$0]) }
        case "appContext": return spec.value.map { .appContext($0) }
        case "selection":  return .selection
        case "always":     return .always
        case "urlPattern": return spec.value.map { .urlPattern($0) }
        default:           return nil
        }
    }

    private func inferCategory(layer: ExtensionLayer, tags: [String]) -> String {
        if tags.contains(where: { ["video", "download", "media", "music", "audio"].contains($0) }) { return "media" }
        if tags.contains("mail")    { return "mail" }
        if tags.contains("finder")  { return "finder" }
        if tags.contains(where: { ["safari", "chrome", "browser"].contains($0) }) { return "browser" }
        if tags.contains(where: { ["compress", "zip", "archive"].contains($0) }) { return "file-actions" }
        switch layer {
        case .l3_browser: return "page-enhancers"
        case .l2_context: return "context"
        case .crossLayer: return "utilities"
        default:          return "custom"
        }
    }
}
