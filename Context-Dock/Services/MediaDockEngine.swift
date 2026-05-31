import AppKit
import Combine
import Foundation

@MainActor
final class MediaDockEngine: ObservableObject {
    static let shared = MediaDockEngine()

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlaying = false

    private var refreshTimer: Timer?

    private init() {}

    func startAutoRefresh() {
        refresh()
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                MediaDockEngine.shared.refresh()
            }
        }
        refreshTimer?.tolerance = 0.75
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        let info = MediaInfoProvider.shared.getNowPlayingInfo()
        let miniInfo = MiniPlayerController.shared.playerInfo

        title = info.title ?? miniInfo?.currentSong ?? ""
        artist = info.artist ?? ""
        album = info.album ?? ""
        isPlaying = info.playbackRate > 0 || (miniInfo?.isPlaying ?? false)

        AppState.shared.mediaDock.title = title
        AppState.shared.mediaDock.artist = artist
        AppState.shared.mediaDock.isPlaying = isPlaying
    }

    func previous() {
        MiniPlayerController.shared.previous()
        refresh()
    }

    func togglePlayPause() {
        MiniPlayerController.shared.togglePlayPause()
        refresh()
    }

    func next() {
        MiniPlayerController.shared.next()
        refresh()
    }

    func stop() {
        MiniPlayerController.shared.stop()
        stopAutoRefresh()
        title = ""
        artist = ""
        album = ""
        isPlaying = false
        AppState.shared.mediaDock.title = ""
        AppState.shared.mediaDock.artist = ""
        AppState.shared.mediaDock.isPlaying = false
    }
}
