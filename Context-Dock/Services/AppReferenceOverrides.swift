// AppReferenceOverrides.swift
// Context-Dock
//
// The link the user gives us for an app, which outranks anything we worked out ourselves.
//
// Reference discovery is deliberately incapable of guessing: it reads the adapter's own
// actions, the app's Sparkle feed, Homebrew's records and the App Store's listing, and if none
// of those know the app, it finds nothing rather than inventing a plausible URL. That is the
// right default and it leaves a long tail — a small indie app, sideloaded, with its homepage
// sitting in its own Help menu as a title DoraX can read and a URL it cannot.
//
// For that tail the user is the authority. One pasted link and the app is documented.

import Foundation

enum AppReferenceOverrides {

    private static let key = "dorax.appReference.overrides.v1"

    /// Every write is a read-modify-write of one dictionary, and UserDefaults guarantees
    /// nothing about the gap between the two halves. Two windows recording a link for
    /// different apps at the same moment both read the old dictionary and both wrote their
    /// own version of it, so whichever finished second silently erased the other's link.
    /// Found by the tests, which run in parallel and did exactly that to each other.
    private static let lock = NSLock()

    /// Links the user recorded for an app, in the order they added them.
    static func urls(forBundleId bundleId: String) -> [String] {
        guard !bundleId.isEmpty else { return [] }
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return all[bundleId.lowercased()] ?? []
    }

    /// Records a link. Returns false when it is not a usable http(s) address — the caller
    /// shows that rather than storing something that will fail quietly at fetch time.
    @discardableResult
    static func add(_ raw: String, forBundleId bundleId: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty, !trimmed.isEmpty else { return false }
        // A pasted address usually arrives without a scheme. Assuming https is not a guess
        // about *which* site — the user named it — only about how to reach it.
        // Whitespace first, before anything is prefixed. macOS 26's URL parser follows the
        // WHATWG rules and percent-encodes its way through almost anything, so
        // "https://see the help menu" parses successfully with the host "see" — a sentence
        // stored as a documentation link, failing silently at fetch time weeks later.
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return false }
        let candidate = trimmed.lowercased().hasPrefix("http") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return false }

        lock.lock()
        defer { lock.unlock() }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        var existing = all[bundleId.lowercased()] ?? []
        guard !existing.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame })
        else { return true }
        existing.append(candidate)
        all[bundleId.lowercased()] = existing
        UserDefaults.standard.set(all, forKey: key)
        return true
    }

    static func remove(_ url: String, forBundleId bundleId: String) {
        lock.lock()
        defer { lock.unlock() }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        all[bundleId.lowercased()] = (all[bundleId.lowercased()] ?? [])
            .filter { $0.caseInsensitiveCompare(url) != .orderedSame }
        UserDefaults.standard.set(all, forKey: key)
    }
}
