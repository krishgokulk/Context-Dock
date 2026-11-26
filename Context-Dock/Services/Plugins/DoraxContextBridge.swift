// Context-Dock/Services/Plugins/DoraxContextBridge.swift
// Context-Dock
//
// Bridges DoraX's native Swift engines into .doraxpack v3 packs:
// 1. Keychain-backed preference storage (`DoraxPackSecretStore`) for `preferences[]` with `type: "secret"`
//    (and UserDefaults storage for non-secret preferences).
// 2. Permission-gated `$DORAX_CONTEXT` JSON payload passed on `stdin` to v3 pack scripts/tools/hooks.
// 3. Zero-script built-in `dorax.*` native data sources (`dorax.clipboard`, `dorax.windows`,
//    `dorax.frontmost.menus`, `dorax.nowPlaying`, `dorax.browser.tabs`, `dorax.files`,
//    `dorax.calendar`, `dorax.notifications`).

import AppKit
import EventKit
import Foundation
import Security

// MARK: - Keychain Secret & Preference Store

enum DoraxPackPreferenceStore {

    private static let keychainService = "com.contextdock.doraxpack.preferences"
    private static let plainDefaultsPrefix = "doraxpack_v3_pref_"
    private static let lock = NSLock()
    /// In-memory override used under XCTest so tests never trigger macOS Keychain prompts.
    private static var testSecrets: [String: String] = [:]

    private static func accountKey(packID: String, prefID: String) -> String {
        "\(packID)::\(prefID)"
    }

    static func value(for pref: DoraxPackPreference, packID: String) -> String? {
        if pref.type == .secret {
            return readSecret(packID: packID, prefID: pref.id) ?? pref.defaultValue
        }
        let key = plainDefaultsPrefix + accountKey(packID: packID, prefID: pref.id)
        return UserDefaults.standard.string(forKey: key) ?? pref.defaultValue
    }

    static func setValue(_ value: String?, for pref: DoraxPackPreference, packID: String) {
        if pref.type == .secret {
            if let value, !value.isEmpty {
                writeSecret(value, packID: packID, prefID: pref.id)
            } else {
                deleteSecret(packID: packID, prefID: pref.id)
            }
            return
        }
        let key = plainDefaultsPrefix + accountKey(packID: packID, prefID: pref.id)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func allValues(for pack: DoraxPackMetadata) -> [String: String] {
        var result: [String: String] = [:]
        for pref in pack.preferences ?? [] {
            if let val = value(for: pref, packID: pack.id) {
                result[pref.id] = val
            }
        }
        return result
    }

    // MARK: - Keychain CRUD

    static func writeSecret(_ secret: String, packID: String, prefID: String) {
        let account = accountKey(packID: packID, prefID: prefID)
        if AppDelegate.isHostingTests {
            lock.withLock { testSecrets[account] = secret }
            return
        }
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func readSecret(packID: String, prefID: String) -> String? {
        let account = accountKey(packID: packID, prefID: prefID)
        if AppDelegate.isHostingTests {
            return lock.withLock { testSecrets[account] }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteSecret(packID: String, prefID: String) {
        let account = accountKey(packID: packID, prefID: prefID)
        if AppDelegate.isHostingTests {
            _ = lock.withLock { testSecrets.removeValue(forKey: account) }
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Permission-Gated `$DORAX_CONTEXT` JSON Builder

struct DoraxContextPayload: Codable, Equatable {
    struct FrontmostInfo: Codable, Equatable {
        var appName: String
        var bundleId: String
        var windowTitle: String?
        var url: String?
        var domain: String?
    }

    struct ClipboardInfo: Codable, Equatable {
        var text: String?
        var type: String
    }

    struct SelectionInfo: Codable, Equatable {
        var text: String?
        var filePaths: [String]
    }

    var packId: String
    var commandId: String?
    var query: String
    var filter: String?
    var formValues: [String: String]?
    var frontmost: FrontmostInfo?
    var clipboard: ClipboardInfo?
    var selection: SelectionInfo?
    var preferences: [String: String]
    var timestamp: String
}

@MainActor
enum DoraxContextBridge {

    /// Resolves the active browser URL across Safari (`SafariBrowserBridge`) and Chromium/Firefox
    /// browsers (`AXContextReader.liveCurrentURL`), guarded by `SensitivePageGuard`.
    static func activeBrowserURL(for app: NSRunningApplication?) -> String? {
        guard let app,
              let bid = app.bundleIdentifier,
              AXWebReader.shared.isBrowser(bundleId: bid)
        else { return nil }

        var rawURL: String? = nil
        if bid == "com.apple.Safari",
           let safari = SafariBrowserBridge.shared.currentContext(),
           !safari.url.isEmpty
        {
            rawURL = safari.url
        }
        if rawURL == nil {
            rawURL = AXContextReader.shared.liveCurrentURL(pid: app.processIdentifier, bundleId: bid)
        }
        guard let url = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty,
              SensitivePageGuard.allows(url)
        else { return nil }
        return url
    }

    /// Builds a permission-gated `$DORAX_CONTEXT` JSON payload for `stdin`.
    /// Sensitive fields (`clipboard`, `selection`, `url`) are ONLY populated when the pack
    /// explicitly declares the corresponding permission in `pack.json`.
    static func buildContext(
        pack: DoraxPackMetadata,
        commandID: String? = nil,
        query: String = "",
        filter: String? = nil,
        formValues: [String: String]? = nil,
        includeSecrets: Bool = true,
        frontmostOverride: DoraxContextPayload.FrontmostInfo? = nil,
        clipboardOverride: DoraxContextPayload.ClipboardInfo? = nil,
        selectionOverride: DoraxContextPayload.SelectionInfo? = nil
    ) -> DoraxContextPayload {
        let perms = Set((pack.permissions ?? []).map { $0.lowercased() })
        let allowsFrontmost = perms.isEmpty || perms.contains("context:frontmost") || perms.contains("context:*")
        let allowsURL = perms.contains("context:url") || perms.contains("browser:tabs") || perms.contains("context:*")
        let allowsClipboard = perms.contains("context:clipboard") || perms.contains("clipboard:read") || perms.contains("context:*")
        let allowsSelection = perms.contains("context:selection") || perms.contains("selection:read") || perms.contains("context:*")

        var frontmost: DoraxContextPayload.FrontmostInfo? = nil
        if allowsFrontmost {
            if let override = frontmostOverride {
                frontmost = DoraxContextPayload.FrontmostInfo(
                    appName: override.appName,
                    bundleId: override.bundleId,
                    windowTitle: override.windowTitle,
                    url: allowsURL ? override.url : nil,
                    domain: allowsURL ? override.domain : nil)
            } else if let app = AppDelegate.shared?.previousFrontmostApp
                ?? NSWorkspace.shared.frontmostApplication
            {
                let bid = app.bundleIdentifier ?? ""
                let name = app.localizedName ?? bid
                var urlStr: String? = nil
                var domainStr: String? = nil
                if allowsURL, let resolvedURL = activeBrowserURL(for: app) {
                    urlStr = resolvedURL
                    domainStr = DoraxPackScope.normalizedHost(from: resolvedURL)
                }
                frontmost = DoraxContextPayload.FrontmostInfo(
                    appName: name, bundleId: bid, windowTitle: nil,
                    url: urlStr, domain: domainStr)
            }
        }

        var clipboard: DoraxContextPayload.ClipboardInfo? = nil
        if allowsClipboard {
            if let override = clipboardOverride {
                clipboard = override
            } else if let top = ClipboardHistoryEngine.shared.history.first {
                let text = String(top.text.prefix(4_000))
                let kind = Self.classifyClipboardText(text)
                clipboard = DoraxContextPayload.ClipboardInfo(text: text, type: kind)
            } else if let pbText = NSPasteboard.general.string(forType: .string) {
                let text = String(pbText.prefix(4_000))
                clipboard = DoraxContextPayload.ClipboardInfo(text: text, type: Self.classifyClipboardText(text))
            }
        }

        var selection: DoraxContextPayload.SelectionInfo? = nil
        if allowsSelection {
            if let override = selectionOverride {
                selection = override
            } else {
                let snap = CornerDockController.shared.selection.snapshot
                if !snap.text.isEmpty || !snap.filePaths.isEmpty {
                    selection = DoraxContextPayload.SelectionInfo(
                        text: snap.text.isEmpty ? nil : snap.text,
                        filePaths: snap.filePaths)
                }
            }
        }

        let prefs: [String: String]
        if includeSecrets {
            prefs = DoraxPackPreferenceStore.allValues(for: pack)
        } else {
            var nonSecrets: [String: String] = [:]
            for pref in pack.preferences ?? [] where pref.type != .secret {
                if let val = DoraxPackPreferenceStore.value(for: pref, packID: pack.id) {
                    nonSecrets[pref.id] = val
                }
            }
            prefs = nonSecrets
        }

        let formatter = ISO8601DateFormatter()
        return DoraxContextPayload(
            packId: pack.id,
            commandId: commandID,
            query: query,
            filter: filter,
            formValues: formValues,
            frontmost: frontmost,
            clipboard: clipboard,
            selection: selection,
            preferences: prefs,
            timestamp: formatter.string(from: Date())
        )
    }

    static func encodeJSON(_ payload: DoraxContextPayload) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    static func classifyClipboardText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return "url"
        }
        if DoraxPackV3Validator.isValidHexColor(trimmed) {
            return "color"
        }
        if trimmed.hasPrefix("/") && FileManager.default.fileExists(atPath: trimmed) {
            return "file"
        }
        return "text"
    }

    // MARK: - Native `dorax.*` Built-In Data Sources (Zero Scripts)

    static let supportedNativeSources: Set<String> = [
        "dorax.clipboard",
        "dorax.windows",
        "dorax.frontmost.menus",
        "dorax.nowPlaying",
        "dorax.browser.tabs",
        "dorax.files",
        "dorax.calendar",
        "dorax.notifications",
    ]

    static func resolveNativeSource(
        _ source: String,
        query: String = "",
        limit: Int = 30
    ) -> DoraxCommandOutput {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch source {
        case "dorax.clipboard":
            let entries = ClipboardHistoryEngine.shared.history.prefix(limit)
            let tf = DateFormatter()
            tf.dateStyle = .none
            tf.timeStyle = .short
            let items: [DoraxCommandItem] = entries.compactMap { entry -> DoraxCommandItem? in
                let preview = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !preview.isEmpty else { return nil }
                if !q.isEmpty && !preview.lowercased().contains(q) { return nil }
                let firstLine = preview.split(separator: "\n").first.map(String.init) ?? preview
                let kind = classifyClipboardText(preview)
                let swatch = kind == "color" ? preview : nil
                let timeLabel = tf.string(from: entry.timestamp)
                return DoraxCommandItem(
                    id: entry.id.uuidString,
                    title: String(firstLine.prefix(80)),
                    subtitle: "Copied at \(timeLabel)",
                    icon: kind == "url" ? "link" : "doc.on.clipboard",
                    swatchHex: swatch,
                    category: kind.capitalized,
                    accessories: [
                        DoraxAccessory(kind: "tag", text: kind, colorHex: kind == "color" ? swatch : "#38BDF8")
                    ],
                    detail: DoraxItemDetail(
                        markdown: preview,
                        metadata: [
                            DoraxMetadataEntry(label: "Captured", value: timeLabel),
                            DoraxMetadataEntry(label: "Characters", value: "\(preview.count)"),
                        ]),
                    actions: [
                        DoraxItemAction(id: "copy", title: "Copy to Clipboard", icon: "doc.on.doc", shortcut: "↵", kind: "copy", value: preview),
                        DoraxItemAction(id: "paste", title: "Paste into Frontmost App", icon: "doc.on.clipboard", shortcut: "⌘↵", kind: "paste", value: preview),
                    ])
            }
            return DoraxCommandOutput(
                items: items,
                filterOptions: ["All", "Text", "Url", "Color"],
                emptyMessage: "No clipboard items captured yet.")

        case "dorax.windows":
            let cmds = WindowManagementService.shared.matchingCommands(query: q)
            let items = cmds.prefix(limit).map { cmd in
                DoraxCommandItem(
                    id: cmd.id,
                    title: cmd.title,
                    subtitle: "Window Layout",
                    icon: cmd.icon,
                    category: "Window",
                    accessories: [DoraxAccessory(kind: "tag", text: "Layout", colorHex: "#60A5FA")],
                    actions: [
                        DoraxItemAction(id: "apply", title: "Apply Layout", icon: cmd.icon, shortcut: "↵", kind: "window", value: cmd.id)
                    ])
            }
            return DoraxCommandOutput(items: items, emptyMessage: "No matching window layouts.")

        case "dorax.frontmost.menus":
            guard let frontApp = AppDelegate.shared?.previousFrontmostApp
                ?? NSWorkspace.shared.frontmostApplication
            else {
                return DoraxCommandOutput(emptyMessage: "No active frontmost app detected.")
            }
            let menus = AppMenuCapabilityCache.shared.menuItems(for: frontApp, maxResults: 120)
            let filtered = menus.filter { item in
                guard item.children.isEmpty, !item.title.isEmpty, item.title != "-" else { return false }
                if q.isEmpty { return true }
                return item.title.lowercased().contains(q)
                    || item.path.joined(separator: " ").lowercased().contains(q)
            }
            let items = filtered.prefix(limit).map { item in
                let pathText = item.path.joined(separator: " ▸ ")
                return DoraxCommandItem(
                    id: pathText,
                    title: item.title,
                    subtitle: item.path.dropLast().joined(separator: " ▸ "),
                    icon: "command",
                    category: item.path.first ?? "Menu",
                    accessories: item.shortcutDisplay.map { [DoraxAccessory(kind: "tag", text: $0, colorHex: "#94A3B8")] } ?? [],
                    actions: [
                        DoraxItemAction(id: "copy-path", title: "Copy Menu Path", icon: "doc.on.doc", shortcut: "↵", kind: "copy", value: pathText)
                    ])
            }
            return DoraxCommandOutput(items: items, emptyMessage: "No cached menus for \(frontApp.localizedName ?? "frontmost app").")

        case "dorax.nowPlaying":
            let media = MediaPlayerObserver.shared
            if media.title.isEmpty {
                return DoraxCommandOutput(
                    detail: DoraxItemDetail(
                        markdown: "### Nothing Playing\nStart playback in Apple Music, Spotify, Safari, or IINA to see live track details here.",
                        metadata: [DoraxMetadataEntry(label: "Status", value: "Idle")]),
                    emptyMessage: "Nothing currently playing.")
            }
            let status = media.isPlaying ? "Playing" : "Paused"
            let progress = media.duration > 0 ? min(1, max(0, media.elapsed / media.duration)) : 0
            return DoraxCommandOutput(
                items: [
                    DoraxCommandItem(
                        id: "now-playing",
                        title: media.title,
                        subtitle: media.artist.isEmpty ? media.appName : "\(media.artist) · \(media.appName)",
                        icon: media.isPlaying ? "play.circle.fill" : "pause.circle.fill",
                        accessories: [
                            DoraxAccessory(kind: "tag", text: status, colorHex: media.isPlaying ? "#34D399" : "#FBBF24"),
                            DoraxAccessory(kind: "progress", progress: progress),
                        ],
                        detail: DoraxItemDetail(
                            markdown: "### \(media.title)\n**Artist:** \(media.artist.isEmpty ? "Unknown" : media.artist)\n**Player:** \(media.appName)",
                            metadata: [
                                DoraxMetadataEntry(label: "State", value: status, colorHex: media.isPlaying ? "#34D399" : "#FBBF24"),
                                DoraxMetadataEntry(label: "App", value: media.appName),
                            ]),
                        actions: [
                            DoraxItemAction(id: "copy-track", title: "Copy Track Info", icon: "doc.on.doc", shortcut: "↵", kind: "copy", value: "\(media.title) — \(media.artist)")
                        ])
                ],
                detail: DoraxItemDetail(
                    markdown: "### \(media.title)\n\(media.artist)\n\nPlaying in **\(media.appName)**.",
                    metadata: [
                        DoraxMetadataEntry(label: "State", value: status),
                        DoraxMetadataEntry(label: "Player", value: media.appName),
                    ]),
                notch: DoraxNotchPayload(
                    wingText: media.isPlaying ? "♫" : "❚❚",
                    wingIcon: "music.note",
                    wingColorHex: "#34D399",
                    title: media.title,
                    subtitle: media.artist,
                    progress: progress))

        case "dorax.browser.tabs":
            var items: [DoraxCommandItem] = []
            if let safari = SafariBrowserBridge.shared.currentContext(), !safari.url.isEmpty {
                let host = DoraxPackScope.normalizedHost(from: safari.url)
                if q.isEmpty || safari.title.lowercased().contains(q) || safari.url.lowercased().contains(q) {
                    items.append(DoraxCommandItem(
                        id: safari.url,
                        title: safari.title.isEmpty ? host : safari.title,
                        subtitle: safari.url,
                        icon: "safari.fill",
                        category: host,
                        accessories: [DoraxAccessory(kind: "tag", text: host, colorHex: "#38BDF8")],
                        detail: DoraxItemDetail(
                            markdown: String(safari.pageText.prefix(2_000)),
                            metadata: [
                                DoraxMetadataEntry(label: "Domain", value: host),
                                DoraxMetadataEntry(label: "Browser", value: "Safari"),
                            ]),
                        actions: [
                            DoraxItemAction(id: "open", title: "Open URL", icon: "safari", shortcut: "↵", kind: "open", value: safari.url),
                            DoraxItemAction(id: "copy-url", title: "Copy URL", icon: "doc.on.doc", shortcut: "⌘C", kind: "copy", value: safari.url),
                        ]))
                }
            }
            return DoraxCommandOutput(items: items, emptyMessage: "No active browser tab detected.")

        case "dorax.files":
            let files: [IndexedFile]
            if !q.isEmpty {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                files = FileIndexManager.shared.indexedFiles.filter {
                    !FileSearchService.isNoisyPath($0.path)
                        && $0.name.lowercased().contains(q)
                        && $0.path.hasPrefix(home)
                }
            } else {
                files = FileIndexManager.shared.indexedFiles.filter { !FileSearchService.isNoisyPath($0.path) }
            }
            let items = files.prefix(limit).map { file in
                DoraxCommandItem(
                    id: file.path,
                    title: file.name,
                    subtitle: file.parentPath,
                    icon: file.isDirectory ? "folder.fill" : "doc.fill",
                    category: file.fileExtension.isEmpty ? "Folder" : file.fileExtension.uppercased(),
                    accessories: [
                        DoraxAccessory(kind: "tag", text: file.fileExtension.isEmpty ? "dir" : file.fileExtension, colorHex: "#94A3B8")
                    ],
                    actions: [
                        DoraxItemAction(id: "open", title: "Open", icon: "arrow.up.right.square", shortcut: "↵", kind: "open", value: URL(fileURLWithPath: file.path).absoluteString),
                        DoraxItemAction(id: "reveal", title: "Reveal in Finder", icon: "folder", shortcut: "⌘R", kind: "reveal", value: file.path),
                        DoraxItemAction(id: "copy-path", title: "Copy Path", icon: "doc.on.doc", shortcut: "⌘C", kind: "copy", value: file.path),
                    ])
            }
            return DoraxCommandOutput(items: items, emptyMessage: "No indexed files matched.")

        case "dorax.calendar":
            // Only read EventKit if already authorized — never trigger an unexpected permission sheet.
            let status = EKEventStore.authorizationStatus(for: .event)
            guard status == .fullAccess || status == .authorized else {
                return DoraxCommandOutput(emptyMessage: "Grant Calendar access in System Settings to view upcoming events.")
            }
            let store = EKEventStore()
            let now = Date()
            let end = Calendar.current.date(byAdding: .day, value: 3, to: now) ?? now.addingTimeInterval(86_400 * 3)
            let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
            let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
            let tf = DateFormatter()
            tf.dateStyle = .short
            tf.timeStyle = .short
            let items = events.prefix(limit).compactMap { ev -> DoraxCommandItem? in
                let title = ev.title ?? "Untitled Event"
                if !q.isEmpty && !title.lowercased().contains(q) { return nil }
                return DoraxCommandItem(
                    id: ev.eventIdentifier ?? UUID().uuidString,
                    title: title,
                    subtitle: ev.location ?? ev.calendar?.title,
                    icon: "calendar",
                    accessories: [DoraxAccessory(kind: "date", text: tf.string(from: ev.startDate), colorHex: "#F472B6")],
                    actions: [
                        DoraxItemAction(id: "copy", title: "Copy Event Title", icon: "doc.on.doc", shortcut: "↵", kind: "copy", value: "\(title) — \(tf.string(from: ev.startDate))")
                    ])
            }
            return DoraxCommandOutput(items: items, emptyMessage: "No upcoming calendar events in the next 3 days.")

        case "dorax.notifications":
            let notes = ILauncherNotificationManager.shared.notifications.prefix(limit)
            let items = notes.compactMap { n -> DoraxCommandItem? in
                if !q.isEmpty && !n.title.lowercased().contains(q) && !n.body.lowercased().contains(q) { return nil }
                return DoraxCommandItem(
                    id: n.id.uuidString,
                    title: n.title,
                    subtitle: n.body,
                    icon: n.icon,
                    accessories: [DoraxAccessory(kind: "tag", text: n.isRead ? "Read" : "Unread", colorHex: n.isRead ? "#64748B" : "#38BDF8")],
                    actions: [
                        DoraxItemAction(id: "copy", title: "Copy Notification", icon: "doc.on.doc", shortcut: "↵", kind: "copy", value: "\(n.title): \(n.body)")
                    ])
            }
            return DoraxCommandOutput(items: items, emptyMessage: "No recent notifications.")

        default:
            return DoraxCommandOutput(emptyMessage: "Unsupported native source: \(source)")
        }
    }
}
