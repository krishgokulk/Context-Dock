// CandidateDiscoveryPolicy.swift
// Context-Dock
//
// What DoraX is allowed to do to the Mac while it is still only *working out* what to
// offer.
//
// Asked "find my passport pdfs …" in a Finder chat, DoraX put up a consent card — "Allow
// Find My for this chat and run it?" — and the Find My application was already on screen
// before the owner had answered. Whatever route did it, the shape of the bug is one rule
// missing: discovery ranks, approval acts. Reading a cache, scoring a menu, comparing two
// routes are all invisible to the user; opening an application is not, and an app opened
// to answer a question the user has not agreed to is a side effect they never asked for.
//
// The rule is deliberately absolute and lives in one place so it can be tested without a
// Mac, a window server, or an app to open.

import Foundation

enum CandidateDiscoveryPolicy {

    /// Discovery never launches an app. Not to read its menus, not to warm a cache, not to
    /// check whether a route would work — launching is what approval is for.
    ///
    /// Stated as a constant rather than left implicit so that a caller which wants to open
    /// something has to say out loud that it is not discovery.
    static let mayLaunchApps = false

    /// Of the apps a turn would like menus for, the ones discovery may actually read:
    /// already running, and not already warm.
    ///
    /// An app that is closed is simply skipped. The turn then answers from what it has,
    /// which is the honest answer — the alternative was opening the app behind the user's
    /// back and calling the result context.
    ///
    /// - Parameters:
    ///   - bundleIDs: the apps the turn is interested in, in the caller's own order.
    ///   - isRunning: whether that app has a live process. Injected so tests never touch
    ///     `NSWorkspace`.
    ///   - isCacheWarm: whether menus for that app are already cached.
    static func menusToRead(
        bundleIDs: [String],
        isRunning: (String) -> Bool,
        isCacheWarm: (String) -> Bool
    ) -> [String] {
        var seen = Set<String>()
        return bundleIDs.filter { bundleID in
            guard !bundleID.isEmpty, !bundleID.hasPrefix("scope://") else { return false }
            guard seen.insert(bundleID.lowercased()).inserted else { return false }
            guard !isCacheWarm(bundleID) else { return false }
            return isRunning(bundleID)
        }
    }
}
