// Context-Dock
//
// How often a plugin's data script runs, and when it does not run at all. Pure arithmetic over
// the manifest and the host's budget, so the rule can be read and tested without a clock.
// Spec §5.

import Foundation

enum PluginRefreshPolicy {
    /// Below this, a plugin is starting processes faster than a person can read the result.
    static let floor: TimeInterval = 1
    /// Spec §5. The fifth live widget is what turns a dock into a battery complaint.
    static let maxLive = 4

    /// `nil` means "do not refresh on a timer" — the manifest has no data, this host asked for
    /// no refresh, or the host has no budget to spend.
    static func interval(for manifest: PluginManifest, host: PluginPresentation,
                         budget: PluginLiveBudget) -> TimeInterval?
    {
        guard budget != .none, let declared = manifest.data?.refresh[host] else { return nil }
        // 0 is the manifest saying "never". Read as an interval it is a loop that spawns a
        // shell as fast as the machine allows.
        guard declared > 0 else { return nil }
        let seconds = max(TimeInterval(declared), floor)
        // A shrunk strip still shows something, so it slows down rather than freezing —
        // freezing would leave a stale number on screen with no sign that it is stale.
        return budget == .low ? seconds * 4 : seconds
    }

    static func admits(runningLiveCount: Int) -> Bool { runningLiveCount < maxLive }
}
