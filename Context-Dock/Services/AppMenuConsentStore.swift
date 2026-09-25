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
    ///
    /// Matched as whole words. This was a substring check, so "Closed" read as "Close":
    /// `History ▸ Reopen Last Closed Window` prompted like closing one, and every page under
    /// `History ▸ Recently Closed` was dropped from results as destructive.
    private static let destructiveWords: Set<String> = [
        "close", "quit", "delete", "remove", "trash", "erase", "reset", "clear",
        "discard", "revert", "empty", "uninstall", "logout", "signout",
    ]

    /// Two-word destructive commands, matched as consecutive words.
    private static let destructivePhrases: [(String, String)] = [
        ("sign", "out"), ("log", "out"),
    ]

    /// The only endings that turn a destructive word into a description of something
    /// ("Closed", "Deleted", "Cleared"), not a command. Any other ending ("Closing",
    /// "Resets") is a form the list cannot call safe, so it stays gated.
    private static let descriptiveEndings: Set<String> = ["ed"]

    /// Top-level menus where "Forward" moves through pages rather than sending a message:
    /// the browsers' History menu and Finder's Go menu.
    private static let navigationMenus: Set<String> = ["history", "go"]

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
        let words = Self.words(path.joined(separator: " "))
        if words.contains(where: Self.isDestructiveWord) { return true }
        if zip(words, words.dropFirst()).contains(where: { pair in
            Self.destructivePhrases.contains { $0 == pair }
        }) { return true }
        guard words.contains(where: { Self.outboundNeedles.contains($0) }) else { return false }
        return !Self.isPageNavigation(path)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// A destructive word itself, or any form of one that is not plainly descriptive.
    ///
    /// Forms are read off the root with a final "e" dropped, so "Closing" is caught the same
    /// way "Resetting" is, and "Closed" and "Cleared" both end in "ed".
    private static func isDestructiveWord(_ word: String) -> Bool {
        if destructiveWords.contains(word) { return true }
        return destructiveWords.contains { stem in
            let root = stem.hasSuffix("e") ? String(stem.dropLast()) : stem
            guard word.hasPrefix(root) else { return false }
            return !descriptiveEndings.contains(String(word.dropFirst(root.count)))
        }
    }

    /// `History ▸ Forward` or `Go ▸ Forward`, and nothing else. A bare "Forward" with no menu
    /// to say which kind it is stays outbound.
    private static func isPageNavigation(_ path: [String]) -> Bool {
        guard path.count == 2 else { return false }
        return navigationMenus.contains(words(path[0]).joined(separator: " "))
            && words(path[1]) == ["forward"]
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
