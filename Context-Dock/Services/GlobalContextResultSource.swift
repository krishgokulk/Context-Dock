import Combine
import Foundation

/// Both presentations consume the dock's scoped providers, including their execution
/// closures. Nil means an unscoped query; an empty array means a scope with no matches.
@MainActor
final class GlobalContextResultSource {
    static let shared = GlobalContextResultSource()
    var pureGlobalResults: ((String) -> [DockPill])?
    var scopedResults: ((String, String?, String?) -> [DockPill]?)?
    /// The Dock's window-layout rows for an app — Quarters, Left & Right… each with the app
    /// sitting in its place — for (query, bundle id, app name). The Corner's app field shows
    /// the same rows the Dock's does.
    var windowLayoutResults: ((String, String, String) -> [DockPill])?
    let updates = PassthroughSubject<Void, Never>()
    func refresh() { updates.send() }
}
