import Combine
import Foundation

struct FinderFolderSnapshotItem {
    let url: URL
    let path: String
    let displayName: String
    let isDirectory: Bool
    let modifiedDate: Date?
}

@MainActor
final class FinderContextViewModel: ObservableObject {
    @Published var attachedFolderSearchPath = ""
    @Published var approvedFolderSearchPaths: Set<String> = []
    @Published var cachedCurrentDirectoryPath = ""
    @Published var snapshotPath = ""
    @Published var snapshotItems: [FinderFolderSnapshotItem] = []
    @Published var snapshotDate: Date = .distantPast
    @Published var followUpFolderPath = ""
    @Published var folderQueryModeActive = false
    @Published var semanticQuery = ""
    @Published var semanticResults: [SearchResult] = []
    @Published var semanticPills: [DockPill] = []
    @Published var isSemanticLoading = false
    @Published var goToPills: [DockPill] = []

    var snapshotTask: Task<Void, Never>?
    var snapshotWatcher: FinderFolderSnapshotWatcher?
    var snapshotWatcherTask: Task<Void, Never>?
    var semanticTask: Task<Void, Never>?

    func clearAttachedFolderSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotPath = ""
        snapshotItems = []
        snapshotDate = .distantPast
    }

    func stopSnapshotWatcher() {
        snapshotWatcherTask?.cancel()
        snapshotWatcherTask = nil
        snapshotWatcher?.stop()
        snapshotWatcher = nil
    }
}
