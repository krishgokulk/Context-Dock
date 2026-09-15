import Foundation

/// Evidence returned by an app reader, with enough identity to keep it distinct from model
/// memory or a ranking hint.
struct GroundedContextEvidence: Codable, Equatable, Identifiable {
    enum Completeness: String, Codable { case complete, partial }

    var id: String { "\(scopeBundleID):\(readerID):\(capturedAt.timeIntervalSince1970)" }
    let readerID: String
    let source: String
    let scopeBundleID: String
    let capturedAt: Date
    let text: String
    let completeness: Completeness

    var isUsable: Bool {
        !readerID.isEmpty && !scopeBundleID.isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
