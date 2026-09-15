// MinimizedPanelRegistry.swift
// Context-Dock
//
// Where a minimised panel goes.
//
// A Global Command or extension opened into its own window is a real window: minimise puts
// it in macOS's Dock, out of reach of the corner it was opened from. But the corner is where
// the user chose it, and the corner already has a row of pills for "things you can get back
// to" — the running apps. A minimised panel is exactly that kind of thing, so it joins them
// rather than needing the user to go hunting in a different dock for a window our app opened.
//
// The registry watches the window rather than being told: `miniaturize(nil)` can come from
// the panel's own button, a double-click on its title area, or macOS itself, and only the
// notification sees all three.

import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// The set of minimised panels changed — the pill row should ask again.
    static let minimizedPanelsChanged = Notification.Name("minimizedPanelsChanged")
}

@MainActor
final class MinimizedPanelRegistry: ObservableObject {
    static let shared = MinimizedPanelRegistry()

    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        /// SF Symbol, because a panel has no app icon of its own to borrow.
        let symbol: String
        let window: NSWindow

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.symbol == rhs.symbol
        }
    }

    @Published private(set) var entries: [Entry] = []

    private var observers: [String: [NSObjectProtocol]] = [:]

    private init() {}

    /// Follow a panel window for the rest of its life.
    ///
    /// The title is resolved when the window is minimised, not when it is registered: a
    /// window that shows whichever extension is active would otherwise carry the name of
    /// whatever happened to be open the first time it appeared.
    func watch(
        _ window: NSWindow, id: String, symbol: String, title: @escaping () -> String
    ) {
        guard observers[id] == nil else { return }
        let center = NotificationCenter.default

        let minimised = center.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.add(Entry(id: id, title: title(), symbol: symbol, window: window))
            }
        }

        let restored = center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.remove(id) }
        }

        // A minimised window that is closed underneath us would leave a pill that restores
        // nothing.
        let closed = center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(id) }
        }

        observers[id] = [minimised, restored, closed]
    }

    /// Bring one back, which is the only thing a pill for it can mean.
    func restore(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.window.deminiaturize(nil)
        entry.window.orderFrontRegardless()
        remove(id)
    }

    func entry(for id: String) -> Entry? { entries.first { $0.id == id } }

    private func add(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        announce()
    }

    private func remove(_ id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        announce()
    }

    private func forget(_ id: String) {
        if let tokens = observers.removeValue(forKey: id) {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
        }
        remove(id)
    }

    private func announce() {
        NotificationCenter.default.post(name: .minimizedPanelsChanged, object: nil)
    }
}
