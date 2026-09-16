import Combine
import Foundation

/// Both presentations consume the dock's scoped providers, including their execution
/// closures. Nil means an unscoped query; an empty array means a scope with no matches.
@MainActor
final class GlobalContextResultSource {
    static let shared = GlobalContextResultSource()
    var pureGlobalResults: ((String) -> [DockPill])?
    var scopedResults: ((String, String?, String?) -> [DockPill]?)?
    let updates = PassthroughSubject<Void, Never>()
    func refresh() { updates.send() }
}
