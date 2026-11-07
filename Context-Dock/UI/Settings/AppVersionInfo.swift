import Foundation

/// One source of truth for the app's version strings, read from the bundle (owner 2026-11-07).
/// General, Updates and About each used to compute these inline with different hardcoded
/// fallbacks ("1.1 beta", "1.1", "Unknown"), which drifted apart as the build moved on.
enum AppVersionInfo {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// e.g. "Version 1.1 (Build 42)".
    static var full: String { "Version \(shortVersion) (Build \(build))" }

    /// The release badge on the General page, e.g. "1.1 beta".
    static var badge: String { "\(shortVersion) beta" }
}
