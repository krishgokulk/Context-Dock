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
}

struct DockPin: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: DockPinKind
    var title: String
    var order: Int
    /// GlobalSearchService document id for commands and tools, so a click can run the real
    /// document; nil for apps, files, folders.
    var documentID: String?
}

@MainActor
final class DockPinStore: ObservableObject {
    static let shared = DockPinStore(
        fileURL: ContextDockStore.root.appendingPathComponent("dock-pins.json"))

    @Published private(set) var pins: [DockPin] = []
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        pins = (ContextDockStore.shared.read([DockPin].self, from: fileURL) ?? [])
            .sorted { $0.order < $1.order }
    }

    func isPinned(_ kind: DockPinKind) -> Bool { pins.contains { $0.kind == kind } }

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
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins.remove(at: index)
        renumber()
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
        ContextDockStore.shared.write(pins, to: fileURL)
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
        case .plugin(let id):
            // Pinnable like any other global thing you run by name. The prefix keeps it
            // distinct from the command it may have been migrated from, so a pin survives
            // the cut-over instead of pointing at something retired.
            self = .globalCommand(id: "plugin:\(id)")
        case .adapterAction(let bundleID, _, let actionID):
            self = .globalCommand(id: "adapter:\(bundleID):\(actionID)")
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
        }
    }
}
