//
//  MenuBarItemManager.swift
//  ILauncher
//
//  Reads macOS status-bar (menu-bar) items via the Accessibility API and lets
//  the user click any of them from the context dock.
//  Also supports manually-pinned menu-bar apps that the user adds themselves.
//

import AppKit
import ApplicationServices
import Combine

// MARK: - MenuBarStatusItem

struct MenuBarStatusItem: Identifiable {
    let id: UUID = UUID()
    let title: String           // Display label (may be empty for icon-only items)
    let bundleId: String?       // Owning app bundle ID if we could resolve it
    let appName: String         // Resolved app name (or raw title)
    let icon: NSImage?          // App icon if resolved
    let element: AXUIElement    // AX element to press

    var displayName: String { appName.isEmpty ? title : appName }
}

// MARK: - ManualMenuBarApp  (persisted in UserDefaults as JSON)

struct ManualMenuBarApp: Codable, Identifiable {
    var id: String { bundleId }
    var name: String
    var bundleId: String
    var sfSymbol: String        // SF Symbol icon name
}

// MARK: - MenuBarItemManager

final class MenuBarItemManager: ObservableObject {
    static let shared = MenuBarItemManager()

    @Published var statusItems: [MenuBarStatusItem] = []
    @Published var manualApps: [ManualMenuBarApp] = []

    private let manualKey = "manualMenuBarApps"

    private init() {
        loadManual()
    }

    // MARK: - Auto-discover from SystemUIServer

    /// Reads all third-party status-bar items from SystemUIServer.
    /// Call from a background thread; updates `statusItems` on main.
    func refresh() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = Self.readStatusItems()
            await MainActor.run { self?.statusItems = items }
        }
    }

    private static func readStatusItems() -> [MenuBarStatusItem] {
        // SystemUIServer hosts third-party NSStatusItems
        let hostBundles = ["com.apple.systemuiserver", "com.apple.controlcenter"]
        var result: [MenuBarStatusItem] = []
        let running = NSWorkspace.shared.runningApplications

        for bundleId in hostBundles {
            guard let app = running.first(where: { $0.bundleIdentifier == bundleId }) else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var barRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &barRef) == .success,
                  let barCF = barRef else { continue }
            let bar = unsafeBitCast(barCF, to: AXUIElement.self)

            var childRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childRef) == .success,
                  let children = childRef as? [AXUIElement] else { continue }

            for child in children {
                var titleRef: CFTypeRef?
                let rawTitle = AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success
                    ? (titleRef as? String ?? "") : ""

                // Resolve owning app by matching title to running app names
                let resolved = running.first { app in
                    guard let name = app.localizedName else { return false }
                    return name.lowercased() == rawTitle.lowercased()
                        || app.bundleIdentifier?.lowercased().contains(rawTitle.lowercased()) == true
                }

                let item = MenuBarStatusItem(
                    title: rawTitle,
                    bundleId: resolved?.bundleIdentifier,
                    appName: resolved?.localizedName ?? rawTitle,
                    icon: resolved?.icon,
                    element: child
                )
                if !item.displayName.isEmpty {
                    result.append(item)
                }
            }
        }
        return result
    }

    // MARK: - Click

    func click(_ item: MenuBarStatusItem) {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString)
    }

    func activateManualApp(_ app: ManualMenuBarApp) {
        // First try to click the status bar item if we can find it by bundle ID
        if let statusItem = statusItems.first(where: { $0.bundleId == app.bundleId }) {
            click(statusItem)
            return
        }
        // Fallback: activate the app so it shows its popover
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == app.bundleId }?
            .activate(options: .activateIgnoringOtherApps)
    }

    // MARK: - Manual list persistence

    func loadManual() {
        guard let data = UserDefaults.standard.data(forKey: manualKey),
              let decoded = try? JSONDecoder().decode([ManualMenuBarApp].self, from: data) else { return }
        manualApps = decoded
    }

    func saveManual() {
        guard let data = try? JSONEncoder().encode(manualApps) else { return }
        UserDefaults.standard.set(data, forKey: manualKey)
    }

    func addManual(_ app: ManualMenuBarApp) {
        guard !manualApps.contains(where: { $0.bundleId == app.bundleId }) else { return }
        manualApps.append(app)
        saveManual()
    }

    func removeManual(id: String) {
        manualApps.removeAll { $0.bundleId == id }
        saveManual()
    }

    func isPinned(_ bundleId: String?) -> Bool {
        guard let bid = bundleId else { return false }
        return manualApps.contains(where: { $0.bundleId == bid })
    }

    func togglePin(_ item: MenuBarStatusItem) {
        guard let bid = item.bundleId else { return }
        if isPinned(bid) {
            removeManual(id: bid)
        } else {
            addManual(ManualMenuBarApp(name: item.appName, bundleId: bid, sfSymbol: "menubar.rectangle"))
        }
    }
}
