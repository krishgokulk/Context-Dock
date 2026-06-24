import AppKit
import Combine
import Foundation

@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case downloading(UpdateManifest)
        case downloaded(UpdateManifest, URL)
        case failed(String)
    }

    struct UpdateManifest: Codable, Equatable {
        let version: String
        let build: Int
        let channel: String
        let minimumSystemVersion: String?
        let dmgURL: URL
        let releaseNotesURL: URL?
        let publishedAt: String?
        let notes: [String]
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date? = nil
    @Published private(set) var downloadProgress: Double = 0

    private let manifestURL = URL(
        string: "https://raw.githubusercontent.com/krishgokulk/Context-Dock/main/update-manifest.json"
    )!

    private init() {}

    func checkForUpdates(auto: Bool = false) {
        guard status != .checking else { return }
        Task { await check(auto: auto) }
    }

    func runLaunchAutoCheckIfNeeded() {
        guard AppSettings.shared.automaticUpdatesEnabled else { return }
        let interval: TimeInterval = 60 * 60 * 6
        let last = UserDefaults.standard.object(forKey: "updates.lastAutoCheckDate") as? Date
        guard last == nil || Date().timeIntervalSince(last ?? .distantPast) > interval else { return }
        UserDefaults.standard.set(Date(), forKey: "updates.lastAutoCheckDate")
        checkForUpdates(auto: true)
    }

    func downloadAndOpen(_ manifest: UpdateManifest) {
        Task { await download(manifest, openWhenDone: true) }
    }

    func openDownloadedUpdate() {
        if case let .downloaded(_, url) = status {
            NSWorkspace.shared.open(url)
        }
    }

    private func check(auto: Bool) async {
        status = .checking
        downloadProgress = 0
        do {
            let (data, response) = try await URLSession.shared.data(from: manifestURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            lastChecked = Date()

            if isNewer(manifest: manifest) {
                status = .available(manifest)
                if auto, AppSettings.shared.automaticUpdatesEnabled {
                    await download(manifest, openWhenDone: AppSettings.shared.openDownloadedUpdatesAutomatically)
                }
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func download(_ manifest: UpdateManifest, openWhenDone: Bool) async {
        status = .downloading(manifest)
        downloadProgress = 0
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: manifest.dmgURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            let updatesDirectory = try updatesFolder()
            let destination = updatesDirectory.appendingPathComponent(manifest.dmgURL.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)

            downloadProgress = 1
            status = .downloaded(manifest, destination)
            if openWhenDone {
                NSWorkspace.shared.open(destination)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func updatesFolder() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base.appendingPathComponent("Context-Dock/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func isNewer(manifest: UpdateManifest) -> Bool {
        let currentBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
        if manifest.build != currentBuild { return manifest.build > currentBuild }
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return compareVersions(manifest.version, currentVersion) == .orderedDescending
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l > r { return .orderedDescending }
            if l < r { return .orderedAscending }
        }
        return .orderedSame
    }
}
