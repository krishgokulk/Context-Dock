import AppKit
import Foundation
import Testing
@testable import Context_Dock

/// Pins on the corner's dock strip: what can be pinned, and that the store keeps them in
/// the order the user put them.
@MainActor
struct DockPinStoreTests {
    private func temporaryStore() -> (DockPinStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-pins-\(UUID().uuidString).json")
        return (DockPinStore(fileURL: url), url)
    }

    private func document(
        action: GlobalSearchService.ActionSpec, id: String = "doc", filePath: String? = nil
    ) -> GlobalSearchService.SearchDocument {
        GlobalSearchService.SearchDocument(
            id: id, title: "T", subtitle: "", bundleId: "", filePath: filePath,
            normalizedTitle: "t", titleWords: ["t"], acronym: "t", aliases: [], aliasWords: [],
            sourceKind: .installed, rankingBoost: 0, icon: nil, usageTrackingKey: id,
            action: action)
    }

    @Test func pinsPersistInOrderAndDedupeOnKind() {
        let (store, url) = temporaryStore()
        store.pin(.app(bundleID: "com.apple.Safari"), title: "Safari")
        store.pin(.folder(path: "/Users/x/Documents"), title: "Documents")
        #expect(store.pin(.app(bundleID: "com.apple.Safari"), title: "Safari") == nil)
        #expect(store.pins.count == 2)
        #expect(store.pins.map(\.order) == [0, 1])
        ContextDockStore.shared.flushNow()
        let reloaded = DockPinStore(fileURL: url)
        #expect(reloaded.pins.map(\.kind) == store.pins.map(\.kind))
    }

    @Test func moveRenumbersOrder() {
        let (store, _) = temporaryStore()
        store.pin(.app(bundleID: "a"), title: "A")
        store.pin(.app(bundleID: "b"), title: "B")
        store.pin(.app(bundleID: "c"), title: "C")
        store.move(from: 2, to: 0)
        #expect(store.pins.map(\.title) == ["C", "A", "B"])
        #expect(store.pins.map(\.order) == [0, 1, 2])
    }

    @Test func unpinOfAMissingIDIsANoOp() {
        let (store, _) = temporaryStore()
        store.pin(.app(bundleID: "a"), title: "A")
        store.unpin(UUID())
        #expect(store.pins.count == 1)
    }

    @Test func documentsMapToKinds() {
        #expect(
            DockPinKind(document: document(action: .launchBundleId("com.x", path: "/Applications/X.app")))
                == .app(bundleID: "com.x"))
        #expect(
            DockPinKind(document: document(action: .activatePID(1, bundleId: "com.y", path: nil)))
                == .app(bundleID: "com.y"))
        #expect(
            DockPinKind(document: document(action: .cliScope(command: "gh", displayName: "GitHub CLI")))
                == .cliTool(name: "gh"))
        #expect(
            DockPinKind(document: document(action: .systemCommandScope(commandKey: "lock")))
                == .globalCommand(id: "system:lock"))
        let ext = UUID()
        #expect(
            DockPinKind(document: document(action: .userExtension(id: ext)))
                == .globalCommand(id: "user:\(ext.uuidString)"))
        #expect(
            DockPinKind(document: document(action: .adapterAction(bundleId: "com.x", appName: "X", actionId: "a1")))
                == .globalCommand(id: "adapter:com.x:a1"))
        let menu = GlobalSearchService.ActionSpec.cachedMenu(
            bundleId: "com.x", appName: "X", path: ["File", "New"], shortcutChar: nil,
            shortcutModifiers: 0)
        #expect(DockPinKind(document: document(action: menu)) == nil)
        let tab = GlobalSearchService.ActionSpec.browserURL(
            url: URL(string: "https://a.b")!, browserBundleId: "com.apple.Safari",
            browserName: "Safari", kind: "tab", domain: "a.b")
        #expect(DockPinKind(document: document(action: tab)) == nil)
    }

    @Test func fileURLsSplitOnDirectory() {
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("pin-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(DockPinKind(fileURL: dir) == .folder(path: dir.path))
        #expect(DockPinKind(fileURL: file) == .file(path: file.path))
        #expect(DockPinKind(fileURL: file.appendingPathComponent("missing")) == nil)
    }

    @Test func rowsMapThroughTheSameRule() {
        let dir = FileManager.default.temporaryDirectory
        #expect(DockPinKind(row: .file(dir)) == .folder(path: dir.path))
        var pill = DockPill(id: "app", name: "X", icon: "app", badge: nil, execute: {})
        pill.rankingKind = "appLaunch"
        pill.sourceBundleId = "com.x"
        #expect(DockPinKind(row: .dock(pill)) == .app(bundleID: "com.x"))
        #expect(DockPinKind(row: .cliSuggestion("status")) == nil)
    }
}
