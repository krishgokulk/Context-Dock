import Foundation
import AppKit

// MARK: - MediaRemote private-framework dynamic bridge
// Loaded via dlopen — never linked directly against a private framework.

enum MRCommand: Int32 {
    case play               = 0
    case pause              = 1
    case togglePlayPause    = 2
    case nextTrack          = 3
    case previousTrack      = 4
    case beginSeekForward   = 5
    case endSeekForward     = 6
    case beginSeekBackward  = 7
    case endSeekBackward    = 8
}

final class MediaRemoteBridge {

    static let shared = MediaRemoteBridge()

    // MARK: - Info-dict string keys (symbol name == string value)
    static let keyTitle       = "kMRMediaRemoteNowPlayingInfoTitle"
    static let keyArtist      = "kMRMediaRemoteNowPlayingInfoArtist"
    static let keyAlbum       = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let keyDuration    = "kMRMediaRemoteNowPlayingInfoDuration"
    static let keyElapsed     = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let keyRate        = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    static let keyArtworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
    static let keyTimestamp   = "kMRMediaRemoteNowPlayingInfoTimestamp"

    // MARK: - Notification names
    static let notifInfoChanged      = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
    static let notifAppChanged       = Notification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")
    static let notifIsPlayingChanged = Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")

    // MARK: - C function-pointer types
    private typealias GetNowPlayingInfoFn   = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias GetNowPlayingClientFn = @convention(c) (DispatchQueue, @escaping (AnyObject?) -> Void) -> Void
    private typealias GetBundleIDFn         = @convention(c) (AnyObject) -> CFString?
    private typealias GetDisplayNameFn      = @convention(c) (AnyObject) -> CFString?
    private typealias GetIsPlayingFn        = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendCommandFn         = @convention(c) (Int32, AnyObject?) -> Bool
    private typealias SetElapsedTimeFn      = @convention(c) (Double) -> Void
    private typealias RegisterForNotifsFn   = @convention(c) (DispatchQueue) -> Void

    private let handle:              UnsafeMutableRawPointer?
    private let _getInfo:            GetNowPlayingInfoFn?
    private let _getClient:          GetNowPlayingClientFn?
    private let _getBundleID:        GetBundleIDFn?
    private let _getDisplayName:     GetDisplayNameFn?
    private let _getIsPlaying:       GetIsPlayingFn?
    private let _sendCommand:        SendCommandFn?
    private let _setElapsed:         SetElapsedTimeFn?
    private let _registerForNotifs:  RegisterForNotifsFn?

    var isAvailable: Bool { handle != nil && _getInfo != nil }

    private init() {
        let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        handle = h
        func sym<T>(_ name: String) -> T? {
            guard let h, let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        _getInfo           = sym("MRMediaRemoteGetNowPlayingInfo")
        _getClient         = sym("MRMediaRemoteGetNowPlayingClient")
        _getBundleID       = sym("MRNowPlayingClientGetBundleIdentifier")
        _getDisplayName    = sym("MRNowPlayingClientGetDisplayName")
        _getIsPlaying      = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying")
        _sendCommand       = sym("MRMediaRemoteSendCommand")
        _setElapsed        = sym("MRMediaRemoteSetElapsedTime")
        _registerForNotifs = sym("MRMediaRemoteRegisterForNowPlayingNotifications")
    }

    // MARK: - Public API

    func registerForNotifications(on queue: DispatchQueue = .main) {
        _registerForNotifs?(queue)
    }

    @discardableResult
    func sendCommand(_ cmd: MRCommand, userInfo: [String: Any]? = nil) -> Bool {
        guard let fn = _sendCommand else { return false }
        return fn(cmd.rawValue, userInfo.map { NSDictionary(dictionary: $0) })
    }

    func setElapsedTime(_ t: Double) { _setElapsed?(t) }

    // MARK: - Async fetch (sequential — no DispatchGroup timing issues)

    /// Fetch now-playing info dict. Guaranteed to call completion (empty dict on failure).
    func fetchInfo(on queue: DispatchQueue = .main,
                   completion: @escaping ([String: Any]) -> Void) {
        guard let fn = _getInfo else { completion([:]); return }
        fn(queue, completion)
    }

    /// Fetch source app bundle ID and display name.
    func fetchClient(on queue: DispatchQueue = .main,
                     completion: @escaping (_ bundleID: String?, _ displayName: String?) -> Void) {
        guard let fn = _getClient, let bid = _getBundleID, let dn = _getDisplayName else {
            completion(nil, nil); return
        }
        fn(queue) { client in
            guard let client else { completion(nil, nil); return }
            completion(bid(client) as String?, dn(client) as String?)
        }
    }

    /// Ask if the now-playing app is currently playing.
    func fetchIsPlaying(on queue: DispatchQueue = .main,
                        completion: @escaping (Bool) -> Void) {
        guard let fn = _getIsPlaying else { completion(false); return }
        fn(queue, completion)
    }

    // MARK: - Async/await wrappers (no DispatchGroup; sequential is safe and avoids hangs)

    func infoAsync() async -> [String: Any] {
        await withCheckedContinuation { cont in
            fetchInfo { cont.resume(returning: $0) }
        }
    }

    func clientAsync() async -> (bundleID: String?, displayName: String?) {
        await withCheckedContinuation { cont in
            fetchClient { cont.resume(returning: ($0, $1)) }
        }
    }

    func isPlayingAsync() async -> Bool {
        await withCheckedContinuation { cont in
            fetchIsPlaying { cont.resume(returning: $0) }
        }
    }

    // MARK: - Convenience: extract from info dict

    static func parse(_ info: [String: Any]) -> ParsedInfo {
        let title    = info[keyTitle]    as? String ?? ""
        let artist   = info[keyArtist]   as? String ?? ""
        let album    = info[keyAlbum]    as? String ?? ""
        let duration = info[keyDuration] as? Double ?? 0
        let rate     = info[keyRate]     as? Double ?? 0
        let stored   = info[keyElapsed]  as? Double ?? 0
        let ts       = (info[keyTimestamp] as? NSDate).map { $0 as Date }
        let liveElapsed: Double
        if let ts, rate > 0 {
            liveElapsed = stored + Date().timeIntervalSince(ts) * rate
        } else {
            liveElapsed = stored
        }
        let artwork: NSImage? = (info[keyArtworkData] as? Data).flatMap { NSImage(data: $0) }
        return ParsedInfo(title: title, artist: artist, album: album,
                          duration: duration, elapsed: liveElapsed,
                          rate: rate, isPlaying: rate > 0, artwork: artwork)
    }

    struct ParsedInfo {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsed: Double
        var rate: Double
        var isPlaying: Bool
        var artwork: NSImage?
    }
}
