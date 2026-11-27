// Context-Dock/Services/Plugins/DoraxPackV3.swift
// Context-Dock
//
// Unified .doraxpack v3 schema, command/tool/hook models, rich UI output payload,
// and static diagnostic validator.
//
// Design:
// - One canonical folder/archive format across Global, App, and Web-App packs.
// - Backward compatible with .doraxpack v2: `format_version` may be 2 or 3;
//   v3 features activate whenever `schema_version == 3`, `format_version == 3`,
//   or any v3 field (`scope`, `commands`, `hooks`, `tools`, `appearance`, `preferences`) is declared.

import Foundation

// MARK: - Scope & Appearance

struct DoraxPackScope: Codable, Equatable {
    /// Surfaces where the pack participates: `"global"`, `"appPet"`, `"selection"`, `"notch"`.
    var surfaces: [String]
    /// Bundle IDs of target macOS applications (e.g. `["com.apple.Notes"]`).
    var apps: [String]
    /// Web-App domains matched via `WebContextEngine` (e.g. `["youtube.com", "youtu.be"]`).
    var domains: [String]

    init(
        surfaces: [String] = ["global"],
        apps: [String] = [],
        domains: [String] = []
    ) {
        self.surfaces = surfaces
        self.apps = apps
        self.domains = domains
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surfaces = try c.decodeIfPresent([String].self, forKey: .surfaces) ?? ["global"]
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
    }

    var includesGlobal: Bool {
        surfaces.contains { $0.lowercased() == "global" }
    }

    var includesAppPet: Bool {
        surfaces.contains { $0.lowercased() == "apppet" }
    }

    var includesSelection: Bool {
        surfaces.contains { $0.lowercased() == "selection" }
    }

    var includesNotch: Bool {
        surfaces.contains { $0.lowercased() == "notch" }
    }

    /// True when `host` equals or is a subdomain of any declared web domain.
    func matchesDomain(_ rawHostOrURL: String) -> Bool {
        guard !domains.isEmpty else { return false }
        let host = Self.normalizedHost(from: rawHostOrURL)
        guard !host.isEmpty else { return false }
        return domains.contains { declared in
            let d = Self.normalizedHost(from: declared)
            guard !d.isEmpty else { return false }
            return host == d || host.hasSuffix("." + d)
        }
    }

    func matchesBundleID(_ bundleID: String) -> Bool {
        let needle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return apps.contains { $0.lowercased() == needle }
    }

    static func normalizedHost(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if let url = URL(string: "https://" + trimmed), let host = url.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return trimmed
    }
}

enum DoraxGlowStyle: String, Codable, Equatable, CaseIterable {
    case none
    case soft
    case pulse
    case breathe
    case orbit
    // Aliases from earlier specs
    case off
    case ambient
    case burst

    var normalized: DoraxGlowStyle {
        switch self {
        case .off: return .none
        case .ambient: return .soft
        case .burst: return .pulse
        default: return self
        }
    }
}

struct DoraxPackAppearance: Codable, Equatable {
    /// Accent color in `#RRGGBB` hex format (e.g. `"#38BDF8"`).
    var tint: String?
    /// Dock & Result Sheet rim glow style (`none | soft | pulse | breathe | orbit`).
    var glow: DoraxGlowStyle

    init(tint: String? = nil, glow: DoraxGlowStyle = .none) {
        self.tint = tint
        self.glow = glow
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tint = try c.decodeIfPresent(String.self, forKey: .tint)
        glow = (try c.decodeIfPresent(DoraxGlowStyle.self, forKey: .glow) ?? .none).normalized
    }
}

// MARK: - Preferences (Secrets → Keychain)

enum DoraxPreferenceType: String, Codable, Equatable {
    case string
    case secret
    case boolean
    case select
    case directory
    case file
}

struct DoraxPackPreference: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var type: DoraxPreferenceType
    var required: Bool
    var defaultValue: String?
    var placeholder: String?
    var options: [String]?

    init(
        id: String,
        title: String,
        type: DoraxPreferenceType = .string,
        required: Bool = false,
        defaultValue: String? = nil,
        placeholder: String? = nil,
        options: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case id, title, type, required
        case defaultValue = "default"
        case placeholder, options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        type = try c.decodeIfPresent(DoraxPreferenceType.self, forKey: .type) ?? .string
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        options = try c.decodeIfPresent([String].self, forKey: .options)
    }
}

// MARK: - Commands (`commands[]`)

enum DoraxCommandMode: String, Codable, Equatable, CaseIterable {
    case list
    case grid
    case detail
    case form
    case instant
    case notch
    case cli
    case ai
}

struct DoraxFormField: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var type: String // "text" | "number" | "toggle" | "select" | "secret"
    var placeholder: String?
    var defaultValue: String?
    var required: Bool
    var options: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, type, placeholder
        case defaultValue = "default"
        case required, options
    }

    init(
        id: String,
        title: String,
        type: String = "text",
        placeholder: String? = nil,
        defaultValue: String? = nil,
        required: Bool = false,
        options: [String]? = nil
    ) {
        self.id = id; self.title = title; self.type = type
        self.placeholder = placeholder; self.defaultValue = defaultValue
        self.required = required; self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "text"
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        options = try c.decodeIfPresent([String].self, forKey: .options)
    }
}

struct DoraxPackCommand: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var icon: String
    var mode: DoraxCommandMode
    var keywords: [String]
    /// Relative script path inside pack folder (e.g. `"commands/list-processes.py"`) or inline script.
    var script: String?
    /// Built-in zero-script source (e.g. `"dorax.clipboard"`, `"dorax.windows"`, `"dorax.browser.tabs"`).
    var source: String?
    /// For `mode: cli`: executable binary name/path and strict argv array (never a shell string).
    var binary: String?
    var args: [String]?
    /// Top-right filter/sort dropdown options inside the `680 × 440` Result Sheet.
    var filterOptions: [String]?
    /// Optional auto-refresh interval in seconds (when sheet or notch is visible).
    var refreshSeconds: Int?
    /// Strict subprocess timeout in seconds (defaults to 8s).
    var timeoutSeconds: Int
    /// Stale-while-revalidate cache TTL in seconds (defaults to 60s).
    var cacheTTLSeconds: Int
    /// Optional `form` mode field declarations.
    var formFields: [DoraxFormField]?
    /// Optional per-command appearance override.
    var appearance: DoraxPackAppearance?
    /// Optional safety classification (`read` | `write` | `destructive`).
    var safety: String

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, icon, mode, keywords, script, source, binary, args
        case filterOptions = "filter_options"
        case refreshSeconds = "refresh_seconds"
        case timeoutSeconds = "timeout_seconds"
        case cacheTTLSeconds = "cache_ttl_seconds"
        case formFields = "form_fields"
        case appearance, safety
    }

    init(
        id: String,
        title: String,
        subtitle: String = "",
        icon: String = "command",
        mode: DoraxCommandMode = .list,
        keywords: [String] = [],
        script: String? = nil,
        source: String? = nil,
        binary: String? = nil,
        args: [String]? = nil,
        filterOptions: [String]? = nil,
        refreshSeconds: Int? = nil,
        timeoutSeconds: Int = 8,
        cacheTTLSeconds: Int = 60,
        formFields: [DoraxFormField]? = nil,
        appearance: DoraxPackAppearance? = nil,
        safety: String = "read"
    ) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.icon = icon; self.mode = mode; self.keywords = keywords
        self.script = script; self.source = source; self.binary = binary
        self.args = args; self.filterOptions = filterOptions
        self.refreshSeconds = refreshSeconds
        self.timeoutSeconds = timeoutSeconds
        self.cacheTTLSeconds = cacheTTLSeconds
        self.formFields = formFields
        self.appearance = appearance
        self.safety = safety
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "command"
        mode = try c.decodeIfPresent(DoraxCommandMode.self, forKey: .mode) ?? .list
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        script = try c.decodeIfPresent(String.self, forKey: .script)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        binary = try c.decodeIfPresent(String.self, forKey: .binary)
        args = try c.decodeIfPresent([String].self, forKey: .args)
        filterOptions = try c.decodeIfPresent([String].self, forKey: .filterOptions)
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds)
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 8
        cacheTTLSeconds = try c.decodeIfPresent(Int.self, forKey: .cacheTTLSeconds) ?? 60
        formFields = try c.decodeIfPresent([DoraxFormField].self, forKey: .formFields)
        appearance = try c.decodeIfPresent(DoraxPackAppearance.self, forKey: .appearance)
        safety = try c.decodeIfPresent(String.self, forKey: .safety) ?? "read"
    }
}

// MARK: - Headless AI Tools (`tools/`)

struct DoraxPackTool: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String
    /// Relative script in `tools/` (e.g. `"tools/inspect-port.py"`).
    var script: String?
    /// Or direct CLI binary + argv.
    var binary: String?
    var args: [String]?
    var safety: String

    init(
        id: String,
        name: String,
        description: String = "",
        script: String? = nil,
        binary: String? = nil,
        args: [String]? = nil,
        safety: String = "read"
    ) {
        self.id = id; self.name = name; self.description = description
        self.script = script; self.binary = binary; self.args = args
        self.safety = safety
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        script = try c.decodeIfPresent(String.self, forKey: .script)
        binary = try c.decodeIfPresent(String.self, forKey: .binary)
        args = try c.decodeIfPresent([String].self, forKey: .args)
        safety = try c.decodeIfPresent(String.self, forKey: .safety) ?? "read"
    }
}

// MARK: - Reactive Hooks (`hooks/`) with Mandatory Swift Pre-Filter

enum DoraxHookEventKind: String, Codable, Equatable, CaseIterable {
    case frontmostChange = "frontmost-change"
    case urlChange = "url-change"
    case clipboard = "clipboard"
    case selection = "selection"
    case notification = "notification"
    case schedule = "schedule"

    var requiredPermission: String {
        switch self {
        case .frontmostChange: return "hook:frontmost"
        case .urlChange: return "hook:url"
        case .clipboard: return "hook:clipboard"
        case .selection: return "hook:selection"
        case .notification: return "hook:notification"
        case .schedule: return "hook:schedule"
        }
    }
}

struct DoraxPackHookFilter: Codable, Equatable {
    var apps: [String]?
    var domains: [String]?
    var types: [String]?
    var regex: String?
    var fileExtensions: [String]?
    var senderApps: [String]?
    var contains: String?
    var every: String?
    var cron: String?

    init(
        apps: [String]? = nil,
        domains: [String]? = nil,
        types: [String]? = nil,
        regex: String? = nil,
        fileExtensions: [String]? = nil,
        senderApps: [String]? = nil,
        contains: String? = nil,
        every: String? = nil,
        cron: String? = nil
    ) {
        self.apps = apps; self.domains = domains; self.types = types
        self.regex = regex; self.fileExtensions = fileExtensions
        self.senderApps = senderApps; self.contains = contains
        self.every = every; self.cron = cron
    }

    /// Guardrail 1: every hook MUST declare at least one lightweight Swift pre-filter.
    var hasAnyFilter: Bool {
        let nonEmptyArray = { (arr: [String]?) -> Bool in !(arr?.isEmpty ?? true) }
        let nonEmptyStr = { (s: String?) -> Bool in !(s?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        return nonEmptyArray(apps)
            || nonEmptyArray(domains)
            || nonEmptyArray(types)
            || nonEmptyStr(regex)
            || nonEmptyArray(fileExtensions)
            || nonEmptyArray(senderApps)
            || nonEmptyStr(contains)
            || nonEmptyStr(every)
            || nonEmptyStr(cron)
    }
}

struct DoraxPackHook: Codable, Equatable, Identifiable {
    var id: String
    var on: DoraxHookEventKind
    /// Relative script path inside `hooks/` (e.g. `"hooks/on-url.py"`).
    var script: String
    /// Mandatory lightweight Swift pre-filter evaluated BEFORE any subprocess spawn.
    var filter: DoraxPackHookFilter
    /// Optional debounce/coalescing override in ms (minimum enforced: 250ms).
    var debounceMs: Int?

    enum CodingKeys: String, CodingKey {
        case id, on, script, filter
        case debounceMs = "debounce_ms"
    }

    init(
        id: String,
        on: DoraxHookEventKind,
        script: String,
        filter: DoraxPackHookFilter,
        debounceMs: Int? = nil
    ) {
        self.id = id; self.on = on; self.script = script
        self.filter = filter; self.debounceMs = debounceMs
    }
}

// MARK: - Rich Command Output Contract (`680 × 440` Result Sheet + Notch + Glow)

struct DoraxAccessory: Codable, Equatable, Identifiable {
    var id: String
    /// `"text" | "tag" | "date" | "progress" | "color" | "avatar" | "metric"`
    var kind: String
    var text: String?
    var colorHex: String?
    var progress: Double?
    var tooltip: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, text
        case colorHex = "color"
        case progress, tooltip
    }

    init(
        id: String = UUID().uuidString,
        kind: String = "text",
        text: String? = nil,
        colorHex: String? = nil,
        progress: Double? = nil,
        tooltip: String? = nil
    ) {
        self.id = id; self.kind = kind; self.text = text
        self.colorHex = colorHex; self.progress = progress; self.tooltip = tooltip
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "text"
        text = try c.decodeIfPresent(String.self, forKey: .text)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        tooltip = try c.decodeIfPresent(String.self, forKey: .tooltip)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "\(kind)-\(text ?? colorHex ?? UUID().uuidString)"
    }
}

struct DoraxMetadataEntry: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var value: String
    var colorHex: String?

    enum CodingKeys: String, CodingKey {
        case id, label, value
        case colorHex = "color"
    }

    init(id: String? = nil, label: String, value: String, colorHex: String? = nil) {
        self.id = id ?? "\(label):\(value)"
        self.label = label; self.value = value; self.colorHex = colorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        value = try c.decode(String.self, forKey: .value)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "\(label):\(value)"
    }
}

struct DoraxItemDetail: Codable, Equatable {
    var markdown: String
    var metadata: [DoraxMetadataEntry]
    var imagePath: String?

    enum CodingKeys: String, CodingKey {
        case markdown, metadata
        case imagePath = "image_path"
    }

    init(markdown: String = "", metadata: [DoraxMetadataEntry] = [], imagePath: String? = nil) {
        self.markdown = markdown
        self.metadata = metadata
        self.imagePath = imagePath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        metadata = try c.decodeIfPresent([DoraxMetadataEntry].self, forKey: .metadata) ?? []
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
    }
}

private enum DoraxJSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: DoraxJSONValue])
    case array([DoraxJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let arr = try? c.decode([DoraxJSONValue].self) { self = .array(arr) }
        else if let obj = try? c.decode([String: DoraxJSONValue].self) { self = .object(obj) }
        else { self = .null }
    }

    var foundationValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues(\.foundationValue)
        case .array(let a): return a.map(\.foundationValue)
        case .null: return NSNull()
        }
    }

    var jsonString: String? {
        let obj = foundationValue
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }
}

struct DoraxItemAction: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var icon: String
    var shortcut: String?
    /// `"copy" | "open" | "reveal" | "paste" | "script" | "run" | "cli" | "url" | "notify" | "notch" | "pick_folder" | "pick_files" | "refresh"`
    var kind: String
    var value: String?
    var script: String?
    var binary: String?
    var args: [String]?
    var destructive: Bool
    var confirmMessage: String?
    var payloadJSON: String?

    enum CodingKeys: String, CodingKey {
        case id, title, icon, shortcut, kind, value, script, binary, args, destructive
        case confirmMessage = "confirm_message"
        case payloadJSON = "payload_json"
        // Decoding aliases emitted by Raycast / AI-generated scripts
        case type, path, url, target, confirm, payload
    }

    init(
        id: String,
        title: String,
        icon: String = "bolt",
        shortcut: String? = nil,
        kind: String = "copy",
        value: String? = nil,
        script: String? = nil,
        binary: String? = nil,
        args: [String]? = nil,
        destructive: Bool = false,
        confirmMessage: String? = nil,
        payloadJSON: String? = nil
    ) {
        self.id = id; self.title = title; self.icon = icon
        self.shortcut = shortcut; self.kind = kind; self.value = value
        self.script = script; self.binary = binary; self.args = args
        self.destructive = destructive; self.confirmMessage = confirmMessage
        self.payloadJSON = payloadJSON
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "bolt"
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)

        let rawKind = (try c.decodeIfPresent(String.self, forKey: .kind)
            ?? (try c.decodeIfPresent(String.self, forKey: .type))
            ?? "copy").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch rawKind {
        case "shell": kind = "script"
        case "url": kind = "open"
        default: kind = rawKind.isEmpty ? "copy" : rawKind
        }

        value = try c.decodeIfPresent(String.self, forKey: .value)
            ?? (try c.decodeIfPresent(String.self, forKey: .path))
            ?? (try c.decodeIfPresent(String.self, forKey: .url))
            ?? (try c.decodeIfPresent(String.self, forKey: .target))
        script = try c.decodeIfPresent(String.self, forKey: .script)
        binary = try c.decodeIfPresent(String.self, forKey: .binary)
        args = try c.decodeIfPresent([String].self, forKey: .args)
        confirmMessage = try c.decodeIfPresent(String.self, forKey: .confirmMessage)
            ?? (try c.decodeIfPresent(String.self, forKey: .confirm))
        let explicitDestructive = try c.decodeIfPresent(Bool.self, forKey: .destructive) ?? false
        destructive = explicitDestructive || !(confirmMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if let rawJSON = try c.decodeIfPresent(String.self, forKey: .payloadJSON) {
            payloadJSON = rawJSON
        } else if let decodedPayload = try c.decodeIfPresent(DoraxJSONValue.self, forKey: .payload) {
            payloadJSON = decodedPayload.jsonString
        } else {
            payloadJSON = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(icon, forKey: .icon)
        try c.encodeIfPresent(shortcut, forKey: .shortcut)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(script, forKey: .script)
        try c.encodeIfPresent(binary, forKey: .binary)
        try c.encodeIfPresent(args, forKey: .args)
        try c.encode(destructive, forKey: .destructive)
        try c.encodeIfPresent(confirmMessage, forKey: .confirmMessage)
        try c.encodeIfPresent(payloadJSON, forKey: .payloadJSON)
    }
}

struct DoraxCommandItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var icon: String?
    var iconPath: String?
    var appIconBundleId: String?
    var swatchHex: String?
    var thumbnailPath: String?
    var category: String?
    var keywords: [String]
    var accessories: [DoraxAccessory]
    var detail: DoraxItemDetail?
    var actions: [DoraxItemAction]

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, icon
        case iconPath = "icon_path"
        case appIconBundleId = "app_icon_bundle_id"
        case swatchHex = "swatch"
        case thumbnailPath = "thumbnail_path"
        case category, keywords, accessories, detail, actions
    }

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        iconPath: String? = nil,
        appIconBundleId: String? = nil,
        swatchHex: String? = nil,
        thumbnailPath: String? = nil,
        category: String? = nil,
        keywords: [String] = [],
        accessories: [DoraxAccessory] = [],
        detail: DoraxItemDetail? = nil,
        actions: [DoraxItemAction] = []
    ) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.icon = icon; self.iconPath = iconPath
        self.appIconBundleId = appIconBundleId
        self.swatchHex = swatchHex; self.thumbnailPath = thumbnailPath
        self.category = category
        self.keywords = keywords; self.accessories = accessories
        self.detail = detail; self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath)
        appIconBundleId = try c.decodeIfPresent(String.self, forKey: .appIconBundleId)
        swatchHex = try c.decodeIfPresent(String.self, forKey: .swatchHex)
        thumbnailPath = try c.decodeIfPresent(String.self, forKey: .thumbnailPath)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        accessories = try c.decodeIfPresent([DoraxAccessory].self, forKey: .accessories) ?? []
        detail = try c.decodeIfPresent(DoraxItemDetail.self, forKey: .detail)
        actions = try c.decodeIfPresent([DoraxItemAction].self, forKey: .actions) ?? []
    }
}

struct DoraxNotchPayload: Codable, Equatable {
    var wingText: String
    var wingIcon: String?
    var wingColorHex: String?
    var title: String?
    var subtitle: String?
    var progress: Double?
    var timerSeconds: Int?
    var isRecording: Bool
    var actions: [DoraxItemAction]

    enum CodingKeys: String, CodingKey {
        case wingText = "wing_text"
        case wingIcon = "wing_icon"
        case wingColorHex = "wing_color"
        case title, subtitle, progress
        case timerSeconds = "timer_seconds"
        case isRecording = "is_recording"
        case actions
    }

    init(
        wingText: String,
        wingIcon: String? = nil,
        wingColorHex: String? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        progress: Double? = nil,
        timerSeconds: Int? = nil,
        isRecording: Bool = false,
        actions: [DoraxItemAction] = []
    ) {
        self.wingText = wingText; self.wingIcon = wingIcon
        self.wingColorHex = wingColorHex; self.title = title
        self.subtitle = subtitle; self.progress = progress
        self.timerSeconds = timerSeconds; self.isRecording = isRecording
        self.actions = actions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wingText = try c.decodeIfPresent(String.self, forKey: .wingText) ?? ""
        wingIcon = try c.decodeIfPresent(String.self, forKey: .wingIcon)
        wingColorHex = try c.decodeIfPresent(String.self, forKey: .wingColorHex)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        timerSeconds = try c.decodeIfPresent(Int.self, forKey: .timerSeconds)
        isRecording = try c.decodeIfPresent(Bool.self, forKey: .isRecording) ?? false
        actions = try c.decodeIfPresent([DoraxItemAction].self, forKey: .actions) ?? []
    }
}

struct DoraxCommandOutput: Codable, Equatable {
    var items: [DoraxCommandItem]
    var detail: DoraxItemDetail?
    var filterOptions: [String]?
    var notch: DoraxNotchPayload?
    var appearance: DoraxPackAppearance?
    var toast: String?
    var emptyMessage: String?
    /// Optional script-emitted prompt routed straight into the user's selected AI provider.
    var aiPrompt: String?
    var aiSystem: String?

    enum CodingKeys: String, CodingKey {
        case items, detail
        case filterOptions = "filter_options"
        case notch, appearance, toast
        case emptyMessage = "empty_message"
        case aiPrompt = "ai_prompt"
        case aiSystem = "ai_system"
    }

    init(
        items: [DoraxCommandItem] = [],
        detail: DoraxItemDetail? = nil,
        filterOptions: [String]? = nil,
        notch: DoraxNotchPayload? = nil,
        appearance: DoraxPackAppearance? = nil,
        toast: String? = nil,
        emptyMessage: String? = nil,
        aiPrompt: String? = nil,
        aiSystem: String? = nil
    ) {
        self.items = items; self.detail = detail
        self.filterOptions = filterOptions; self.notch = notch
        self.appearance = appearance; self.toast = toast
        self.emptyMessage = emptyMessage
        self.aiPrompt = aiPrompt; self.aiSystem = aiSystem
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([DoraxCommandItem].self, forKey: .items) ?? []
        detail = try c.decodeIfPresent(DoraxItemDetail.self, forKey: .detail)
        filterOptions = try c.decodeIfPresent([String].self, forKey: .filterOptions)
        notch = try c.decodeIfPresent(DoraxNotchPayload.self, forKey: .notch)
        appearance = try c.decodeIfPresent(DoraxPackAppearance.self, forKey: .appearance)
        toast = try c.decodeIfPresent(String.self, forKey: .toast)
        emptyMessage = try c.decodeIfPresent(String.self, forKey: .emptyMessage)
        aiPrompt = try c.decodeIfPresent(String.self, forKey: .aiPrompt)
        aiSystem = try c.decodeIfPresent(String.self, forKey: .aiSystem)
    }

    /// Parses stdout JSON (object, JSON array of items, JSONL rows, or plain text fallback into detail).
    static func parse(stdout: String, commandTitle: String) -> DoraxCommandOutput {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return DoraxCommandOutput(emptyMessage: "No output from \(commandTitle)")
        }
        let decoder = JSONDecoder()
        if let data = trimmed.data(using: .utf8) {
            if let decoded = try? decoder.decode(DoraxCommandOutput.self, from: data),
               (!decoded.items.isEmpty || decoded.detail != nil || decoded.notch != nil || decoded.toast != nil || decoded.emptyMessage != nil || decoded.aiPrompt != nil)
            {
                return decoded
            }
            if let items = try? decoder.decode([DoraxCommandItem].self, from: data) {
                return DoraxCommandOutput(items: items)
            }
        }
        // JSONL rows fallback
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
        var jsonlItems: [DoraxCommandItem] = []
        for line in lines {
            if let lineData = String(line).data(using: .utf8),
               let item = try? decoder.decode(DoraxCommandItem.self, from: lineData)
            {
                jsonlItems.append(item)
            }
        }
        if !jsonlItems.isEmpty {
            return DoraxCommandOutput(items: jsonlItems)
        }
        // Plain text / CLI output fallback
        return DoraxCommandOutput(
            detail: DoraxItemDetail(markdown: "```\n\(trimmed)\n```", metadata: [])
        )
    }
}

// MARK: - Pack v3 Static Validator (`PluginDiagnostic`)

enum DoraxPackV3Validator {

    static func validate(_ pack: DoraxPackV2) -> [PluginDiagnostic] {
        var diagnostics: [PluginDiagnostic] = []
        let m = pack.metadata

        if m.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(PluginDiagnostic(severity: .error, path: "id", message: "Pack id must not be empty"))
        }
        if m.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(PluginDiagnostic(severity: .error, path: "name", message: "Pack name must not be empty"))
        }

        // Validate commands[]
        var seenCommandIDs: Set<String> = []
        for cmd in m.commands ?? [] {
            if !seenCommandIDs.insert(cmd.id).inserted {
                diagnostics.append(PluginDiagnostic(
                    severity: .error, path: "commands.\(cmd.id)",
                    message: "Duplicate command id \"\(cmd.id)\""))
            }
            if cmd.mode == .cli && (cmd.binary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                diagnostics.append(PluginDiagnostic(
                    severity: .error, path: "commands.\(cmd.id).binary",
                    message: "CLI command \"\(cmd.id)\" must declare an explicit binary (argv-only, no shell string)"))
            }
            if cmd.mode != .cli && cmd.mode != .ai && cmd.mode != .form,
               (cmd.script?.isEmpty ?? true) && (cmd.source?.isEmpty ?? true)
            {
                diagnostics.append(PluginDiagnostic(
                    severity: .warning, path: "commands.\(cmd.id)",
                    message: "Command \"\(cmd.id)\" declares neither script nor dorax.* source"))
            }
            if let source = cmd.source, !source.isEmpty, !source.hasPrefix("dorax.") {
                diagnostics.append(PluginDiagnostic(
                    severity: .error, path: "commands.\(cmd.id).source",
                    message: "Unknown data source \"\(source)\"; expected dorax.*"))
            }
            if let script = cmd.script, script.contains(".."), !script.contains("\n") {
                diagnostics.append(PluginDiagnostic(
                    severity: .error, path: "commands.\(cmd.id).script",
                    message: "Relative parent traversal '..' is not allowed in command script path"))
            }
        }

        // Validate hooks[] (Guardrail 1: mandatory Swift pre-filter!)
        for hook in m.hooks ?? [] {
            if !hook.filter.hasAnyFilter {
                diagnostics.append(PluginDiagnostic(
                    severity: .error, path: "hooks.\(hook.id).filter",
                    message: "Hook \"\(hook.id)\" must declare a lightweight Swift pre-filter (apps, domains, types, regex, fileExtensions, senderApps, contains, every, or cron)"))
            }
            if let pattern = hook.filter.regex, !pattern.isEmpty {
                if (try? NSRegularExpression(pattern: pattern)) == nil {
                    diagnostics.append(PluginDiagnostic(
                        severity: .error, path: "hooks.\(hook.id).filter.regex",
                        message: "Hook \"\(hook.id)\" has invalid regex: \(pattern)"))
                }
            }
            if let perms = m.permissions, !perms.contains(hook.on.requiredPermission) {
                diagnostics.append(PluginDiagnostic(
                    severity: .warning, path: "permissions",
                    message: "Hook \"\(hook.id)\" uses \"\(hook.on.rawValue)\" without declaring \"\(hook.on.requiredPermission)\" in permissions[]"))
            }
        }

        // Validate appearance hex tint if provided
        if let tint = m.appearance?.tint, !tint.isEmpty, !Self.isValidHexColor(tint) {
            diagnostics.append(PluginDiagnostic(
                severity: .warning, path: "appearance.tint",
                message: "Tint \"\(tint)\" is not a valid #RRGGBB hex color"))
        }

        return diagnostics
    }

    static func isValidHexColor(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("#") else { return false }
        let hex = s.dropFirst()
        guard hex.count == 6 || hex.count == 8 else { return false }
        return hex.allSatisfy { $0.isHexDigit }
    }
}
