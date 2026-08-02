import Foundation

/// How much a CLI ↔ app link is trusted, and therefore whether it is worth spending prompt
/// space on.
///
/// Linking used to be one-way and permanent: a single Allow on a guessed suggestion wrote a
/// link that never expired. A Safari scope ended up carrying `mo`, `new-localization` and
/// `merge-all-source-plugins` — each one taxing every Safari turn with a command name and its
/// scanned `--help`, which is what pushed the on-device model past its context window.
///
/// Two states:
/// - **trusted** — seeded with the adapter, matched from the known-tool catalog, or proven by
///   actually running in that scope. Always advertised to the model.
/// - **provisional** — a guess the user allowed. It works immediately, but it is only
///   advertised when the question names it, and it is unlinked automatically if it never
///   proves itself.
final class CLILinkTrustStore {
    static let shared = CLILinkTrustStore()

    /// A guess that has not been used in this long was a wrong guess.
    static let provisionalLifetime: TimeInterval = 7 * 24 * 60 * 60

    private struct Record: Codable {
        var linkedAt: Date
        var usedAt: Date?
    }

    private let defaultsKey = "CLILinkTrust.v1"
    private let queue = DispatchQueue(label: "com.krishgokul.ContextDock.cliLinkTrust")
    private var records: [String: Record]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        {
            records = decoded
        } else {
            records = [:]
        }
    }

    private static func key(command: String, bundleID: String) -> String {
        "\(command.lowercased())|\(bundleID)"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Writes

    /// A link the user allowed from a guessed suggestion.
    func markProvisional(command: String, bundleID: String) {
        queue.sync {
            let key = Self.key(command: command, bundleID: bundleID)
            guard records[key] == nil else { return }
            records[key] = Record(linkedAt: Date(), usedAt: nil)
            persist()
        }
    }

    /// A link that came from the adapter seed or the known-tool catalog — not a guess.
    func markTrusted(command: String, bundleID: String) {
        queue.sync {
            let key = Self.key(command: command, bundleID: bundleID)
            records[key] = Record(linkedAt: Date(), usedAt: Date())
            persist()
        }
    }

    /// The tool actually ran in this scope, which settles the question.
    func markUsed(command: String, bundleID: String) {
        queue.sync {
            let key = Self.key(command: command, bundleID: bundleID)
            var record = records[key] ?? Record(linkedAt: Date(), usedAt: nil)
            record.usedAt = Date()
            records[key] = record
            persist()
        }
    }

    func forget(command: String, bundleID: String) {
        queue.sync {
            records[Self.key(command: command, bundleID: bundleID)] = nil
            persist()
        }
    }

    // MARK: - Reads

    /// True only for a link this store knows to be a guess that never proved itself. Links
    /// predating this store are unknown, not provisional — existing setups keep working.
    func isProvisional(command: String, bundleID: String) -> Bool {
        queue.sync {
            guard let record = records[Self.key(command: command, bundleID: bundleID)] else {
                return false
            }
            return record.usedAt == nil
        }
    }

    /// True when the tool has run in this scope at least once.
    func hasBeenUsed(command: String, bundleID: String) -> Bool {
        queue.sync {
            records[Self.key(command: command, bundleID: bundleID)]?.usedAt != nil
        }
    }

    /// Provisional links past their lifetime, as (command, bundleID) pairs.
    func expiredProvisionalLinks(now: Date = Date()) -> [(command: String, bundleID: String)] {
        queue.sync {
            records.compactMap { key, record in
                guard record.usedAt == nil,
                    now.timeIntervalSince(record.linkedAt) > Self.provisionalLifetime
                else { return nil }
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (command: parts[0], bundleID: parts[1])
            }
        }
    }

    /// Removes links the user allowed on a guess and never used. Called once at launch, so a
    /// wrong Allow costs a week of one extra line rather than forever.
    @MainActor
    func sweepExpiredLinks() {
        let expired = expiredProvisionalLinks()
        guard !expired.isEmpty else { return }
        let manager = TerminalPackageManager.shared
        for entry in expired {
            guard var package = manager.packages.first(where: {
                $0.command.lowercased() == entry.command
            }) else {
                forget(command: entry.command, bundleID: entry.bundleID)
                continue
            }
            guard package.contextAppBundleIds.contains(entry.bundleID) else {
                forget(command: entry.command, bundleID: entry.bundleID)
                continue
            }
            package.contextAppBundleIds.removeAll { $0 == entry.bundleID }
            manager.updatePackage(package)
            forget(command: entry.command, bundleID: entry.bundleID)
            #if DEBUG
            print("🧹 [CLILinkTrust] Unlinked unused \(entry.command) from \(entry.bundleID)")
            #endif
        }
    }
}
