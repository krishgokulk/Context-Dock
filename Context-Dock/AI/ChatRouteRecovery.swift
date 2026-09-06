import Foundation

/// Who to ask when the model wrote its tool call as text instead of calling it.
///
/// A protocol-only answer is a call that never ran. The surface refuses to show JSON as an
/// answer and recovers by resolving the request deterministically through `ChatRouteResolver`
/// — but a route belongs to an app, so recovery first has to decide which app to ask.
///
/// That decision used to be `case .app`: only a single-app thread could recover. A combined
/// workspace and a General chat with an app attached both had routes available and no way to
/// reach them, so a resolved Messages call came back as "couldn't carry it out on this
/// surface" while Messages sat one route away.
enum ChatRouteRecovery {
    struct Candidate: Equatable {
        let bundleID: String
        let name: String
    }

    /// The apps whose routes may answer this turn, in the order they should be tried.
    ///
    /// The scope's own app leads — it is what the thread is about — followed by whatever was
    /// attached to the conversation. An app whose bundle id cannot be resolved is skipped
    /// rather than ending the search: one unknown name must not cost the user the app next
    /// to it.
    static func candidateApps(
        scope: GeneralChatScope,
        attachedAppNames: [String],
        scopeAppName: String?,
        bundleID: (String) -> String?
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        var seen: Set<String> = []

        func add(bundleID id: String, name: String) {
            guard !id.isEmpty, seen.insert(id).inserted else { return }
            candidates.append(Candidate(bundleID: id, name: name))
        }

        if case .app(let scopeBundleID) = scope {
            add(bundleID: scopeBundleID, name: scopeAppName ?? scopeBundleID)
        }

        for name in attachedAppNames {
            guard let id = bundleID(name) else { continue }
            add(bundleID: id, name: name)
        }

        return candidates
    }
}
