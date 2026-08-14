// GeneralChatSessionStore.swift
// Context-Dock
//
// Conversations kept per scope, so the general chat window can act as one hub for every app
// and CLI tool rather than a single rolling chat.
//
// A session is just stored text: it does not require its app to be running, or installed, or
// frontmost. That is the point — "what did I ask Reminders last week" should be answerable
// with Reminders closed, the same way a desktop chat app keeps a thread per topic.
//
// Message bodies stay in GeneralAIChatConversationStore's format. This adds the index — which
// sessions exist, what each is about — and one conversation blob per session, so the existing
// sheet/window round trip is untouched.

import AppKit
import Foundation

/// What a session is scoped to. The raw value is the storage key, so it must stay stable.
enum GeneralChatScope: Codable, Hashable {
    /// A durable, unscoped conversation created from the General Chat window.
    case thread(id: String)
    /// An installed app, by bundle identifier.
    case app(bundleId: String)
    /// A pinned CLI tool, by command.
    case cli(command: String)
    /// A directory the user attached, by absolute path.
    ///
    /// A folder is not an app, and scoping a chat to Finder is not the same as scoping it
    /// to ~/Documents/Invoices: Finder is wherever the user last clicked, a folder stays
    /// put. Files are the thing most worth asking about, and until this existed the only
    /// way to ask about a directory was to open it and hope the question landed while it
    /// was still frontmost.
    case folder(path: String)
    /// The unscoped conversation — the one the result sheet and the window already share.
    case general

    var storageKey: String {
        switch self {
        case .thread(let id): return "thread:\(id)"
        case .app(let bundleId): return "app:\(bundleId)"
        case .cli(let command): return "cli:\(command.lowercased())"
        case .folder(let path): return "folder:\(path)"
        case .general: return "general"
        }
    }

    /// The directory this scope is about, when it is about one.
    var folderURL: URL? {
        guard case .folder(let path) = self else { return nil }
        return URL(fileURLWithPath: path)
    }

    var isGeneralChat: Bool {
        switch self {
        case .general, .thread: return true
        default: return false
        }
    }

    /// The dock identifies a scope by bundle id, using a `cli://` prefix for tools. Given the
    /// same string, both surfaces name the same thread — which is what lets a command run in
    /// the dock show up on the console of the window thread for that app or tool.
    init(dockBundleId: String?) {
        guard let dockBundleId, !dockBundleId.isEmpty else {
            self = .general
            return
        }
        if dockBundleId.hasPrefix("cli://") {
            self = .cli(command: String(dockBundleId.dropFirst("cli://".count)))
        } else {
            self = .app(bundleId: dockBundleId)
        }
    }
}

struct GeneralChatSession: Identifiable, Codable, Equatable {
    var id: String { scope.storageKey }
    let scope: GeneralChatScope
    /// Shown in the sidebar. Held rather than derived so a renamed or removed app still reads
    /// as what the user was talking to.
    var title: String
    /// Sidebar order. Fixed at first open and never touched again: sorting by last use meant
    /// the row you clicked jumped to the top, moving the list under the cursor.
    var createdAt: Date?
    var updatedAt: Date
    var messageCount: Int

    /// Sessions written before ordering was stable have no createdAt; their last-updated
    /// time is the closest thing to when they were opened.
    var sortDate: Date { createdAt ?? updatedAt }

    static func == (lhs: GeneralChatSession, rhs: GeneralChatSession) -> Bool {
        lhs.scope == rhs.scope && lhs.updatedAt == rhs.updatedAt
            && lhs.messageCount == rhs.messageCount && lhs.title == rhs.title
    }
}

enum GeneralChatSessionStore {
    private static let indexKey = "dorax.generalAI.sessionIndex.v1"

    /// Sessions in the order they were opened — a stable list, like tabs.
    static func index() -> [GeneralChatSession] {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
            let sessions = try? JSONDecoder().decode([GeneralChatSession].self, from: data)
        else { return [] }
        return sessions.sorted { $0.sortDate < $1.sortDate }
    }

    private static func writeIndex(_ sessions: [GeneralChatSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: indexKey)
    }

    /// Registers a session, or refreshes what the sidebar shows for it.
    static func upsert(scope: GeneralChatScope, title: String, messageCount: Int) {
        let existing = index().first { $0.scope == scope }
        var sessions = index().filter { $0.scope != scope }
        sessions.append(
            GeneralChatSession(
                scope: scope, title: title,
                // Keep the original position: re-opening a thread is not a reason to move it.
                createdAt: existing?.sortDate ?? Date(),
                updatedAt: Date(), messageCount: messageCount))
        writeIndex(sessions)
    }

    /// Removes the thread from the sidebar. The conversation itself is left on disk: the
    /// dock still shows it for that app, and closing a window row is not a request to
    /// erase what was said.
    static func remove(scope: GeneralChatScope) {
        writeIndex(index().filter { $0.scope != scope })
        UserDefaults.standard.removeObject(forKey: attachedAppsKey(scope))
    }

    // MARK: - Conversations

    private static func conversationKey(_ scope: GeneralChatScope) -> String {
        "dorax.generalAI.session.\(scope.storageKey).v1"
    }

    /// The dock's own key for a scope's conversation. App and CLI threads read and write
    /// the file the dock's frontmost/scoped chat already uses, so the window is a second
    /// view of that conversation rather than a copy of it — continue in either and the
    /// other is current.
    static func dockPanelKey(_ scope: GeneralChatScope) -> String? {
        switch scope {
        case .app(let bundleId): return "dock_app_\(bundleId)"
        case .cli(let command): return "dock_app_cli://\(command.lowercased())"
        // The dock's Finder-window chat is this same conversation: ask about the folder
        // in the dock, press the window glyph, and the thread that opens must be the one
        // you were just having. Threads written before this shared key existed are merged
        // in by migratedIfNeeded, so nothing said earlier is lost.
        case .folder(let path): return "dock_folder_\(path)"
        case .general, .thread: return nil
        }
    }

    /// The unscoped session deliberately reads and writes the existing store, so a chat
    /// started in the result sheet is the same conversation the window opens on.
    static func load(scope: GeneralChatScope) -> [AIChatMessage] {
        guard scope != .general else { return GeneralAIChatConversationStore.load() }
        guard let panelKey = dockPanelKey(scope) else {
            return GeneralAIChatConversationStore.load(key: conversationKey(scope))
        }
        return migratedIfNeeded(scope: scope, panelKey: panelKey)
    }

    /// One-time merge for threads created before app storage was shared. The window's old
    /// UserDefaults copy may hold messages the dock file never saw (and the reverse), so
    /// the union is kept, in timestamp order, rather than one side silently winning.
    private static func migratedIfNeeded(
        scope: GeneralChatScope, panelKey: String
    ) -> [AIChatMessage] {
        let dockMessages = AppPanelChatStore.shared.load(for: panelKey)
        let legacy = GeneralAIChatConversationStore.load(key: conversationKey(scope))
        guard !legacy.isEmpty else { return dockMessages }

        var seen = Set(dockMessages.map(fingerprint))
        var merged = dockMessages
        for message in legacy where seen.insert(fingerprint(message)).inserted {
            merged.append(message)
        }
        merged.sort { $0.timestamp < $1.timestamp }
        AppPanelChatStore.shared.save(merged, for: panelKey)
        // Consumed: leaving it would re-merge (and re-append) on every open.
        UserDefaults.standard.removeObject(forKey: conversationKey(scope))
        return merged
    }

    /// Role + text + whole-second timestamp. The same message saved by both surfaces has
    /// different UUIDs, so identity cannot be used to spot a duplicate.
    private static func fingerprint(_ message: AIChatMessage) -> String {
        "\(message.role)|\(message.content)|\(Int(message.timestamp.timeIntervalSince1970))"
    }

    static func save(_ messages: [AIChatMessage], scope: GeneralChatScope, title: String) {
        if scope == .general {
            GeneralAIChatConversationStore.save(messages)
        } else if let panelKey = dockPanelKey(scope) {
            AppPanelChatStore.shared.save(messages, for: panelKey)
        } else {
            GeneralAIChatConversationStore.save(messages, key: conversationKey(scope))
        }
        upsert(scope: scope, title: title, messageCount: messages.count)
    }

    // MARK: - Discovery

    /// Registers threads the dock created so they appear in the window's sidebar.
    ///
    /// A conversation held in the dock — frontmost-app chat, a scoped app, a CLI tool —
    /// is written to AppPanelChatStore whether or not the window ever saw it. Without this
    /// the window only listed threads it had opened itself, so a chat the user never
    /// cleared simply did not exist as far as the window was concerned.
    @MainActor
    static func discoverDockThreads() {
        let onDisk = Set(AppPanelChatStore.shared.allPanelKeys())
        var known = Set(index().map(\.scope.storageKey))

        func adopt(_ scope: GeneralChatScope, title: String) {
            guard !known.contains(scope.storageKey) else { return }
            guard let panelKey = dockPanelKey(scope),
                onDisk.contains(AppPanelChatStore.sanitizedKey(panelKey))
            else { return }
            let messages = AppPanelChatStore.shared.load(for: panelKey)
            // An empty file is a scope that was entered and never used; listing it would
            // fill the sidebar with apps the user never actually talked to.
            guard !messages.isEmpty else { return }
            known.insert(scope.storageKey)
            var sessions = index().filter { $0.scope != scope }
            sessions.append(
                GeneralChatSession(
                    scope: scope, title: title,
                    createdAt: messages.first?.timestamp ?? Date(),
                    updatedAt: messages.last?.timestamp ?? Date(),
                    messageCount: messages.count))
            writeIndex(sessions)
        }

        for adapter in AppAdapterManager.shared.adapters where !adapter.bundleId.isEmpty {
            adopt(.app(bundleId: adapter.bundleId), title: adapter.appName)
        }
        for entry in InstalledApplicationsCatalog.cachedInstalledApps() {
            adopt(.app(bundleId: entry.bundleId), title: entry.name)
        }
        for package in TerminalPackageManager.shared.packages where package.isEnabled {
            adopt(.cli(command: package.command), title: package.command)
        }
    }

    // MARK: - Attached apps

    private static func attachedAppsKey(_ scope: GeneralChatScope) -> String {
        "dorax.generalAI.session.\(scope.storageKey).apps.v1"
    }

    /// The extra apps a thread is scoped to — what makes it a combined chat. Stored per
    /// thread so a scope the user set survives switching away, closing the window and
    /// relaunching; an app picked once and silently dropped on the next visit is worse
    /// than not offering the picker.
    static func loadAttachedApps(scope: GeneralChatScope) -> [String] {
        UserDefaults.standard.stringArray(forKey: attachedAppsKey(scope)) ?? []
    }

    static func saveAttachedApps(_ names: [String], scope: GeneralChatScope) {
        if names.isEmpty {
            UserDefaults.standard.removeObject(forKey: attachedAppsKey(scope))
        } else {
            UserDefaults.standard.set(names, forKey: attachedAppsKey(scope))
        }
    }

    // MARK: - Presentation

    /// Icon for a session row: the app's real icon, or a terminal glyph for a CLI tool.
    @MainActor
    static func icon(for scope: GeneralChatScope) -> NSImage? {
        switch scope {
        case .app(let bundleId):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .cli:
            return NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
        case .folder(let path):
            // The real folder icon, so a tagged or custom-iconed directory looks in the
            // sidebar the way it looks in Finder.
            return NSWorkspace.shared.icon(forFile: path)
        case .general, .thread:
            return NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        }
    }
}
