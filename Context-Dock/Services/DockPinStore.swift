import AppKit
import Combine
import Foundation

/// What a pinned icon on the corner's dock strip stands for. Apps, files and folders are
/// self-describing; commands and tools name a `GlobalSearchService` document by id so a
/// click runs the real thing through the same path the list uses.
enum DockPinKind: Codable, Equatable, Hashable {
    case app(bundleID: String)
    case globalCommand(id: String)
    case cliTool(name: String)
    case file(path: String)
    case folder(path: String)
    /// One of an app's own menu commands, pinned in that app's Context Dock. The path is the
    /// menu path as the list showed it; it runs through the same consent gate as any click.
    case menuCommand(path: [String])
    /// One of an app's adapter actions, by id, pinned in that app's Context Dock.
    case appAction(id: String)
    /// A browser tab, pinned in the browser's Context Dock. Pinned tabs stay first and
    /// reopen: a click shows the tab when it is open and loads the page when it is not.
    case tab(url: String)
}

struct DockPin: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: DockPinKind
    var title: String
    var order: Int
    /// GlobalSearchService document id for commands and tools, so a click can run the real
    /// document; nil for apps, files, folders.
    var documentID: String?
    /// A plugin with a bar widget, set by the user to draw as its icon instead — the tile
    /// then shows on hover. Nil (the default, and every pin saved before this existed)
    /// draws the widget.
    var showsAsIcon: Bool? = nil
    /// The app whose Context Dock this pin belongs to. Nil is a Global pin, which is every
    /// pin saved before per-app pins existed. `order` counts within the pin's own group.
    var appBundleID: String? = nil
}

@MainActor
final class DockPinStore: ObservableObject {
    static let shared = DockPinStore(
        fileURL: ContextDockStore.root.appendingPathComponent("dock-pins.json"))

    /// Global's pins — the corner's strip in Global Context.
    @Published private(set) var pins: [DockPin] = []
    /// Every app's Context Dock pins, in one list; `pins(forApp:)` is one app's share.
    ///
    /// Kept apart from `pins` so every reader of Global's pins goes on reading exactly
    /// Global's, and saved to the same file, so there is one pin store and not two.
    @Published private(set) var appPins: [DockPin] = []
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        let saved = (ContextDockStore.shared.read([DockPin].self, from: fileURL) ?? [])
            .sorted { $0.order < $1.order }
        pins = saved.filter { $0.appBundleID == nil }
        appPins = saved.filter { $0.appBundleID != nil }
    }

    func isPinned(_ kind: DockPinKind) -> Bool { pins.contains { $0.kind == kind } }

    /// One app's pins, in the order the user put them.
    func pins(forApp bundleID: String) -> [DockPin] {
        appPins.filter { $0.appBundleID == bundleID }.sorted { $0.order < $1.order }
    }

    func isPinned(_ kind: DockPinKind, app bundleID: String) -> Bool {
        appPins.contains { $0.appBundleID == bundleID && $0.kind == kind }
    }

    /// A pin of either kind, by id — what the strip's hover and cards look up.
    func pin(withID id: UUID) -> DockPin? {
        pins.first { $0.id == id } ?? appPins.first { $0.id == id }
    }

    /// Pins `kind` in one app's Context Dock, after that app's other pins.
    @discardableResult
    func pin(
        _ kind: DockPinKind, title: String, documentID: String? = nil, app bundleID: String
    ) -> DockPin? {
        guard !bundleID.isEmpty, !isPinned(kind, app: bundleID) else { return nil }
        let pin = DockPin(
            id: UUID(), kind: kind, title: title, order: pins(forApp: bundleID).count,
            documentID: documentID, appBundleID: bundleID)
        appPins.append(pin)
        persist()
        return pin
    }

    /// Moves a pin to the end of its own group — Global's or its app's. What a drop back
    /// on the strip does.
    func moveToEnd(_ id: UUID) {
        if let from = pins.firstIndex(where: { $0.id == id }) {
            move(from: from, to: pins.count)
            return
        }
        guard let index = appPins.firstIndex(where: { $0.id == id }),
            let bundleID = appPins[index].appBundleID
        else { return }
        let group = pins(forApp: bundleID)
        for pin in group where pin.order > appPins[index].order {
            if let i = appPins.firstIndex(where: { $0.id == pin.id }) { appPins[i].order -= 1 }
        }
        appPins[index].order = group.count - 1
        persist()
    }

    @discardableResult
    func pin(_ kind: DockPinKind, title: String, documentID: String? = nil) -> DockPin? {
        guard !isPinned(kind) else { return nil }
        let pin = DockPin(
            id: UUID(), kind: kind, title: title, order: pins.count, documentID: documentID)
        pins.append(pin)
        persist()
        return pin
    }

    func unpin(_ id: UUID) {
        if let index = pins.firstIndex(where: { $0.id == id }) {
            pins.remove(at: index)
            renumber()
            persist()
            return
        }
        guard let index = appPins.firstIndex(where: { $0.id == id }) else { return }
        let bundleID = appPins[index].appBundleID
        appPins.remove(at: index)
        for (order, pin) in appPins.filter({ $0.appBundleID == bundleID })
            .sorted(by: { $0.order < $1.order }).enumerated()
        {
            if let i = appPins.firstIndex(where: { $0.id == pin.id }) { appPins[i].order = order }
        }
        persist()
    }

    func setShowsAsIcon(_ id: UUID, _ asIcon: Bool) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[index].showsAsIcon = asIcon ? true : nil
        persist()
    }

    func move(from source: Int, to destination: Int) {
        guard pins.indices.contains(source), (0...pins.count).contains(destination),
            source != destination
        else { return }
        let pin = pins.remove(at: source)
        pins.insert(pin, at: destination > source ? destination - 1 : destination)
        renumber()
        persist()
    }

    private func renumber() {
        for index in pins.indices { pins[index].order = index }
    }

    private func persist() {
        ContextDockStore.shared.write(pins + appPins, to: fileURL)
    }
}

// MARK: - Mapping

extension DockPinKind {
    /// One rule for the context menu and the drop handler, so they agree on what can be
    /// pinned. Menus and browser tabs cannot: a menu item lives in one app's state, a tab
    /// is a moment.
    init?(document: GlobalSearchService.SearchDocument) {
        switch document.action {
        case .launchBundleId(let bundleID, _):
            self = .app(bundleID: bundleID)
        case .activatePID(_, let bundleID, _):
            self = .app(bundleID: bundleID)
        case .launchPath(let path):
            if path.hasSuffix(".app"), let bundleID = Bundle(path: path)?.bundleIdentifier {
                self = .app(bundleID: bundleID)
            } else if let kind = DockPinKind(fileURL: URL(fileURLWithPath: path)) {
                self = kind
            } else {
                return nil
            }
        case .cliScope(let command, _):
            self = .cliTool(name: command)
        case .systemCommandScope(let key):
            self = .globalCommand(id: "system:\(key)")
        case .userExtension(let id):
            self = .globalCommand(id: "user:\(id.uuidString)")
        case .adapterAction(let bundleID, _, let actionID):
            self = .globalCommand(id: "adapter:\(bundleID):\(actionID)")
        case .plugin(let id):
            // Pinnable like any other global thing you run by name. The prefix keeps it
            // distinct from the command it may have been migrated from, so a pin survives
            // the cut-over instead of pointing at something retired.
            self = .globalCommand(id: "plugin:\(id)")
        case .cachedMenu, .browserURL:
            return nil
        }
    }

    init?(fileURL: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        else { return nil }
        self = isDirectory.boolValue ? .folder(path: fileURL.path) : .file(path: fileURL.path)
    }

    init?(row: AppChatRow) {
        switch row {
        case .global(let doc):
            self.init(document: doc)
        case .file(let url):
            self.init(fileURL: url)
        case .dock(let pill) where pill.rankingKind == "appLaunch" && !pill.sourceBundleId.isEmpty:
            self = .app(bundleID: pill.sourceBundleId)
        case .dock, .command, .action, .cliSuggestion:
            return nil
        }
    }

    /// What a row in one app's Context Dock pins as, for that app. Wider than `init(row:)`:
    /// there a menu command lives in one app's state and cannot be a Global pin, but in the
    /// app's own dock that app's state is exactly the point.
    init?(appRow row: AppChatRow) {
        switch row {
        case .command(let item):
            let path = item.path.filter { !$0.isEmpty }
            guard !path.isEmpty else { return nil }
            self = .menuCommand(path: path)
        case .action(let action):
            self = .appAction(id: action.id)
        case .global(let doc):
            self.init(document: doc)
        case .file(let url):
            self.init(fileURL: url)
        case .dock, .cliSuggestion:
            return nil
        }
    }

    /// The icon at draw time — never persisted, because apps update theirs.
    var icon: NSImage? {
        switch self {
        case .app(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .file(let path), .folder(let path):
            return FileManager.default.fileExists(atPath: path)
                ? NSWorkspace.shared.icon(forFile: path) : nil
        case .globalCommand, .cliTool:
            return nil  // the strip asks the document for its icon
        case .menuCommand, .appAction, .tab:
            return nil  // drawn from the app's own menu, action or favicon by the strip
        }
    }

    /// The plugin this pin stands for, when it is one: `globalCommand(id: "plugin:<id>")`.
    /// A pinned plugin with a bar widget draws as that widget in the strip.
    var pluginID: String? {
        guard case .globalCommand(let id) = self, id.hasPrefix("plugin:") else { return nil }
        let pluginID = String(id.dropFirst("plugin:".count))
        return pluginID.isEmpty ? nil : pluginID
    }

    /// What the strip draws when the real icon is missing. Never an empty square: the user
    /// pinned something, and the shape of what they pinned is the least the row can say.
    var fallbackSymbol: String {
        switch self {
        case .app: return "app.dashed"
        case .globalCommand: return "command"
        case .cliTool: return "terminal"
        case .file: return "doc"
        case .folder: return "folder"
        case .menuCommand: return "filemenu.and.selection"
        case .appAction: return "bolt"
        case .tab: return "globe"
        }
    }

    /// One of an app's own things — a menu command, an action, a tab — run in that app by
    /// its Context Dock rather than opened by the strip.
    var runsInApp: Bool {
        switch self {
        case .menuCommand, .appAction, .tab: return true
        case .app, .globalCommand, .cliTool, .file, .folder: return false
        }
    }

    /// Whether what this stands for is still there.
    var isAvailable: Bool {
        switch self {
        case .app(let bundleID):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        case .file(let path), .folder(let path):
            return FileManager.default.fileExists(atPath: path)
        case .globalCommand, .cliTool:
            return true  // the strip checks the document instead
        case .menuCommand, .appAction, .tab:
            return true  // the app's own; greyed menu items still show, as in the list
        }
    }
}
