import Foundation

/// Remembers which destructive app-menu commands the user has approved for the AI to run
/// on its own ("allow always"). Safe menu items (Minimize, Zoom, View toggles…) never reach
/// this store — only destructive-sounding paths (Close, Quit, Delete, Move to Trash…) are
/// gated, and once the user approves one it is remembered per app + menu path so the same
/// command runs without a prompt next time.
///
/// Keyed by "<bundleId>|<lowercased path joined by ' > '>". Backed by UserDefaults so it
/// survives relaunch.
final class AppMenuConsentStore {
    static let shared = AppMenuConsentStore()

    private let defaultsKey = "AppMenuConsentStore.allowedPaths"
    private let lock = NSLock()
    private var allowed: Set<String>

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        allowed = Set(saved)
    }

    private func key(bundleId: String, path: [String]) -> String {
        let joined = path.joined(separator: " > ").lowercased()
        return "\(bundleId.lowercased())|\(joined)"
    }

    /// Words that mark a menu command as destructive enough to require the first-time prompt.
    private static let destructiveNeedles: [String] = [
        "close", "quit", "delete", "remove", "trash", "erase", "reset", "clear",
        "discard", "revert", "empty", "uninstall", "sign out", "log out",
    ]

    /// True when this menu path should be gated before the AI runs it unattended.
    func isDestructive(path: [String]) -> Bool {
        let hay = path.joined(separator: " ").lowercased()
        return Self.destructiveNeedles.contains { hay.contains($0) }
    }

    /// True when the user has already granted "allow always" for this exact command.
    func isAllowed(bundleId: String, path: [String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowed.contains(key(bundleId: bundleId, path: path))
    }

    /// Persist an "allow always" grant so this command runs without a prompt next time.
    func allowAlways(bundleId: String, path: [String]) {
        lock.lock()
        allowed.insert(key(bundleId: bundleId, path: path))
        let snapshot = Array(allowed)
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: defaultsKey)
    }

    /// Forget every remembered grant (used by Reset in settings).
    func reset() {
        lock.lock()
        allowed.removeAll()
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
