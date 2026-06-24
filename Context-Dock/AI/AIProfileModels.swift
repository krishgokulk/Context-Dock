import Foundation

struct AIProfile: Identifiable, Codable, Hashable {
    enum RoutingStrategy: String, Codable, CaseIterable, Identifiable {
        case onDeviceFirst
        case selectedProvider
        case fixedProvider
        case cloudFirst

        var id: String { rawValue }
    }

    var id: UUID
    var name: String
    var icon: String
    var enabled: Bool
    var priority: Int
    var appBundleIds: [String]
    var triggerKeywords: [String]
    var routingStrategy: RoutingStrategy
    var preferredProvider: AIProvider
    var allowCloudFallback: Bool
    var enableAppAdapterActions: Bool
    var enableCLITools: Bool
    var enableScreenOCRFallback: Bool
    var systemInstruction: String

    init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        enabled: Bool = true,
        priority: Int = 0,
        appBundleIds: [String] = [],
        triggerKeywords: [String] = [],
        routingStrategy: RoutingStrategy = .onDeviceFirst,
        preferredProvider: AIProvider = .onDevice,
        allowCloudFallback: Bool = true,
        enableAppAdapterActions: Bool = true,
        enableCLITools: Bool = true,
        enableScreenOCRFallback: Bool = false,
        systemInstruction: String
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.enabled = enabled
        self.priority = priority
        self.appBundleIds = appBundleIds
        self.triggerKeywords = triggerKeywords
        self.routingStrategy = routingStrategy
        self.preferredProvider = preferredProvider
        self.allowCloudFallback = allowCloudFallback
        self.enableAppAdapterActions = enableAppAdapterActions
        self.enableCLITools = enableCLITools
        self.enableScreenOCRFallback = enableScreenOCRFallback
        self.systemInstruction = systemInstruction
    }
}

extension AIProfile {
    static let developer = AIProfile(
        name: "Developer",
        icon: "chevron.left.forwardslash.chevron.right",
        priority: 100,
        appBundleIds: [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "com.apple.Terminal",
            "com.googlecode.iterm2"
        ],
        triggerKeywords: ["code", "build", "error", "test", "git", "github", "commit", "pr"],
        routingStrategy: .onDeviceFirst,
        preferredProvider: .onDevice,
        allowCloudFallback: true,
        enableAppAdapterActions: true,
        enableCLITools: true,
        enableScreenOCRFallback: true,
        systemInstruction: """
        You are a Developer Profile assistant. Use current Mac app, selected code, open file, terminal output, and git/gh tools when useful. Prefer local/on-device reasoning. Do not invent files, issues, branches, or commands. Ask for approval before destructive commands.
        """
    )

    static let meeting = AIProfile(
        name: "Meeting Assistant",
        icon: "calendar.badge.clock",
        priority: 90,
        appBundleIds: [
            "com.apple.iCal",
            "com.apple.mail",
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.tinyspeck.slackmacgap"
        ],
        triggerKeywords: ["meeting", "calendar", "schedule", "agenda", "prepare", "reschedule"],
        routingStrategy: .onDeviceFirst,
        preferredProvider: .onDevice,
        allowCloudFallback: true,
        enableAppAdapterActions: true,
        enableCLITools: true,
        enableScreenOCRFallback: true,
        systemInstruction: """
        You are a Meeting Assistant profile. Use Calendar/Mail/current app context to prepare agendas, summarize meetings, draft follow-ups, and plan schedule changes. Do not invent attendees, times, locations, or decisions. Ask for approval before creating, moving, or deleting calendar events.
        """
    )

    static let files = AIProfile(
        name: "Files & Finder",
        icon: "folder.fill",
        priority: 80,
        appBundleIds: ["com.apple.finder", "com.apple.Preview"],
        triggerKeywords: ["file", "folder", "pdf", "rename", "move", "organize", "summarize"],
        routingStrategy: .onDeviceFirst,
        preferredProvider: .onDevice,
        allowCloudFallback: true,
        enableAppAdapterActions: true,
        enableCLITools: true,
        enableScreenOCRFallback: true,
        systemInstruction: """
        You are a Files & Finder profile. Use selected Finder files/folders and document context. Help summarize, rename, organize, convert, and find files. Never delete, overwrite, move, or rename files without explicit approval.
        """
    )

    static let general = AIProfile(
        name: "General Mac Context",
        icon: "sparkles",
        priority: 0,
        appBundleIds: [],
        triggerKeywords: [],
        routingStrategy: .selectedProvider,
        preferredProvider: .onDevice,
        allowCloudFallback: true,
        enableAppAdapterActions: true,
        enableCLITools: false,
        enableScreenOCRFallback: false,
        systemInstruction: """
        You are a contextual macOS assistant. Use current app context, selected text, files, URLs, and safe app actions. Be concise. Do not claim access to apps or cloud services unless context/tool results prove it.
        """
    )

    static let defaults: [AIProfile] = [.developer, .meeting, .files, .general]
}
