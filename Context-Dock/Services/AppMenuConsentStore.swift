import Foundation

/// Remembers which app-menu commands the user has approved for the AI to run on its own
/// ("allow always"). Safe menu items (Minimize, Zoom, View toggles…) never reach this store —
/// only paths that destroy local state (Close, Quit, Delete, Move to Trash…) or put something
/// in front of another person (Send, Reply, Forward, Share) are gated, and once the user
/// approves one it is remembered per app + menu path so the same command runs without a
/// prompt next time.
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

    /// Words that mark a menu command as destroying something local.
    private static let destructiveNeedles: [String] = [
        "close", "quit", "delete", "remove", "trash", "erase", "reset", "clear",
        "discard", "revert", "empty", "uninstall", "sign out", "log out",
    ]

    /// Words that mark a menu command as putting something in front of another person.
    ///
    /// The list above was written from the vocabulary of deleting things, so every word in it
    /// is about local state and none is about reaching somebody else. Mail registers no send
    /// capability, so the registry gate that covers reminders.delete never runs for it: until
    /// these words were here, `Message ▸ Send` was as ungated as `Window ▸ Minimize`, on the
    /// reasoning that a menu command is public and observable. Observable is not reversible.
    ///
    /// Matched as whole words, not substrings, because "Shared Links" is a view and "Send" is
    /// not — and a prompt in front of a harmless item trains people to approve without
    /// reading, which is exactly what would make the prompt in front of Send worthless.
    private static let outboundNeedles: Set<String> = [
        "send", "reply", "forward", "share", "publish", "post", "submit",
    ]

    /// True when this menu path should be gated before the AI runs it unattended.
    func isDestructive(path: [String]) -> Bool {
        let hay = path.joined(separator: " ").lowercased()
        if Self.destructiveNeedles.contains(where: { hay.contains($0) }) { return true }
        let words = hay.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { Self.outboundNeedles.contains($0) }
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
