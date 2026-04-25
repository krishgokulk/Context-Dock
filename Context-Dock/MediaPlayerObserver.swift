import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - Media Player Observer
//
// Architecture:
//  • Transport commands  → MediaRemote SendCommand (confirmed reliable)
//  • State / info        → layered, best-source-wins:
//      1. MR notifications  → debounced async fetch (sequential, no DispatchGroup hang)
//      2. Music / Spotify   → DistributedNotification userInfo (inline, zero extra calls)
//      3. Browser fallback  → AppleScript JS (only when MR returns empty)
//      4. Safety poll       → every 5 s, catches apps that post no notifications
//  • Smooth elapsed      → anchor-based interpolation at 4 fps, no server calls
//  • Stability buffer    → 4 consecutive empty responses before clearing UI
//                          (prevents flicker when MR has a momentary gap)

@MainActor
class MediaPlayerObserver: ObservableObject {
    static let shared = MediaPlayerObserver()

    // MARK: - Published state

    @Published var isPlaying: Bool = false
    @Published var title: String    = ""
    @Published var artist: String   = ""
    @Published var artworkImage: NSImage? = nil
    @Published var appName: String  = ""
    @Published var appIcon: NSImage? = nil
    @Published var elapsed: Double  = 0
    @Published var duration: Double = 0
    @Published var isDismissed: Bool = false

    // MARK: - Private state

    // Playback anchor — avoids server calls for smooth seekbar
    private var anchorDate:    Date   = Date()
    private var anchorElapsed: Double = 0
    private var playbackRate:  Double = 0

    // Stability buffer — prevent flickering on transient empty responses
    private var consecutiveEmpty: Int = 0
    private let clearThreshold:   Int = 4   // ~20 s at 5-s poll before clearing

    // Source tracking
    private var lastBundleID:    String? = nil
    private var lastTitle:       String  = ""
    private var lastArtworkData: Data?   = nil

    // Timers / tasks
    private var displayTimer:    Timer?
    private var safetyPollTimer: Timer?
    private var pendingFetch:    Task<Void, Never>? = nil

    // MARK: - Init

    private init() {
        let bridge = MediaRemoteBridge.shared
        guard bridge.isAvailable else { return }

        // Register so MediaRemote daemon streams change notifications to us.
        bridge.registerForNotifications(on: .main)

        let dnc = DistributedNotificationCenter.default()
        let nc  = NotificationCenter.default

        // ── MediaRemote change notifications ─────────────────────────────────
        // Subscribe to both centers; one of them fires on any given macOS build.
        for name in [MediaRemoteBridge.notifInfoChanged, MediaRemoteBridge.notifAppChanged] {
            dnc.addObserver(self, selector: #selector(onMRChange(_:)),
                            name: name, object: nil,
                            suspensionBehavior: .deliverImmediately)
            nc.addObserver(self, selector: #selector(onMRChange(_:)), name: name, object: nil)
        }
        dnc.addObserver(self, selector: #selector(onMRIsPlayingChange(_:)),
                        name: MediaRemoteBridge.notifIsPlayingChanged, object: nil,
                        suspensionBehavior: .deliverImmediately)
        nc.addObserver(self, selector: #selector(onMRIsPlayingChange(_:)),
                       name: MediaRemoteBridge.notifIsPlayingChanged, object: nil)

        // ── Music.app / iTunes direct notifications ───────────────────────────
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
            dnc.addObserver(self, selector: #selector(onMusicNotif(_:)),
                            name: NSNotification.Name(name), object: nil,
                            suspensionBehavior: .deliverImmediately)
        }

        // ── Spotify direct notification ───────────────────────────────────────
        dnc.addObserver(self, selector: #selector(onSpotifyNotif(_:)),
                        name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
                        object: nil, suspensionBehavior: .deliverImmediately)

        // Initial fetch — one runloop cycle after registration settles.
        DispatchQueue.main.async { [weak self] in self?.scheduleFetch(delay: 0) }

        // Safety poll — catches apps that post no notifications (browsers, IINA, VLC…).
        safetyPollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.scheduleFetch(delay: 0)
        }
        safetyPollTimer?.tolerance = 1.0

        // Smooth seekbar: recompute elapsed from anchor at 4 fps.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickElapsed() }
        }
        displayTimer?.tolerance = 0.05
    }

    // MARK: - Notification handlers

    @objc private func onMRChange(_ n: Notification) {
        // If the notification carries an info dict directly, use it without an extra fetch.
        if let raw = n.userInfo as? [String: Any] {
            let parsed = MediaRemoteBridge.parse(raw)
            if !parsed.title.isEmpty {
                applyParsed(parsed, bundleID: nil, displayName: nil, appIcon: nil)
                // Still fetch client to get bundleID / app icon.
                Task { [weak self] in
                    let c = await MediaRemoteBridge.shared.clientAsync()
                    await MainActor.run { self?.updateSourceApp(bundleID: c.bundleID, displayName: c.displayName) }
                }
                return
            }
        }
        scheduleFetch(delay: 0.05)   // tiny debounce for burst notifications
    }

    @objc private func onMRIsPlayingChange(_ n: Notification) {
        Task { [weak self] in
            let playing = await MediaRemoteBridge.shared.isPlayingAsync()
            await MainActor.run { [weak self] in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                if !playing { self.playbackRate = 0 }
            }
        }
    }

    /// Music.app — full track data is inline in the notification userInfo.
    @objc private func onMusicNotif(_ n: Notification) {
        let u = n.userInfo
        let t = u?["Name"]            as? String ?? ""
        let a = u?["Artist"]          as? String ?? ""
        let s = u?["Player State"]    as? String ?? ""
        let p = u?["Player Position"] as? Double ?? 0
        let d = u?["Total Time"]      as? Double ?? 0
        applyRaw(title: t, artist: a, isPlaying: s == "Playing",
                 elapsed: p, duration: d, rate: s == "Playing" ? 1 : 0,
                 bundleID: "com.apple.Music")
    }

    /// Spotify — full track data is inline in the notification userInfo.
    @objc private func onSpotifyNotif(_ n: Notification) {
        let u = n.userInfo
        let t = u?["Name"]              as? String ?? ""
        let a = u?["Artist"]            as? String ?? ""
        let s = u?["Player State"]      as? String ?? ""
        let p = u?["Playback Position"] as? Double ?? 0
        let d = u?["Track Duration"]    as? Double ?? 0
        applyRaw(title: t, artist: a, isPlaying: s == "Playing",
                 elapsed: p, duration: d, rate: s == "Playing" ? 1 : 0,
                 bundleID: "com.spotify.client")
    }

    // MARK: - Debounced fetch scheduler

    /// Schedule a fetch, cancelling any pending one (debounce).
    /// Delay 0 = immediate (next main-queue slot). Delay > 0 = coalesce bursts.
    private func scheduleFetch(delay: TimeInterval) {
        pendingFetch?.cancel()
        pendingFetch = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.performFetch()
        }
    }

    // MARK: - Core async fetch

    private func performFetch() async {
        let bridge = MediaRemoteBridge.shared

        // 1. Fetch info from MR (sequential — no DispatchGroup hang risk).
        let info    = await bridge.infoAsync()
        let parsed  = MediaRemoteBridge.parse(info)

        if !parsed.title.isEmpty {
            // Good data from MR — also fetch client for bundleID / app icon.
            let client = await bridge.clientAsync()
            applyParsed(parsed, bundleID: client.bundleID,
                        displayName: client.displayName,
                        appIcon: client.bundleID.flatMap { bid in
                            NSWorkspace.shared.runningApplications
                                .first(where: { $0.bundleIdentifier == bid })?.icon
                        })
            consecutiveEmpty = 0
        } else {
            // MR returned nothing — try browser AppleScript immediately.
            let browserResult = await fetchFromBrowsers()
            if let r = browserResult {
                applyRaw(title: r.title, artist: r.artist,
                         isPlaying: r.isPlaying, elapsed: r.elapsed,
                         duration: r.duration, rate: r.isPlaying ? 1 : 0,
                         bundleID: r.bundleID)
                consecutiveEmpty = 0
            } else {
                consecutiveEmpty += 1
                // Only clear UI after sustained silence — prevents flicker.
                if consecutiveEmpty >= clearThreshold {
                    clearPlayback()
                }
            }
        }
    }

    // MARK: - Apply helpers

    private func applyParsed(_ p: MediaRemoteBridge.ParsedInfo,
                              bundleID: String?,
                              displayName: String?,
                              appIcon: NSImage?) {
        applyRaw(title: p.title, artist: p.artist,
                 isPlaying: p.isPlaying, elapsed: p.elapsed,
                 duration: p.duration, rate: p.rate,
                 bundleID: bundleID, displayName: displayName,
                 artwork: p.artwork, appIcon: appIcon)
    }

    private func applyRaw(title newTitle: String,
                          artist newArtist: String,
                          isPlaying newPlaying: Bool,
                          elapsed newElapsed: Double,
                          duration newDuration: Double,
                          rate newRate: Double,
                          bundleID: String?,
                          displayName: String? = nil,
                          artwork: NSImage? = nil,
                          appIcon: NSImage? = nil) {
        // Track change — reset dismissed so dock becomes visible again.
        if !newTitle.isEmpty, newTitle != lastTitle {
            lastTitle = newTitle
            isDismissed = false
        }

        if title    != newTitle    { title    = newTitle    }
        if artist   != newArtist   { artist   = newArtist   }
        if duration != newDuration { duration = newDuration }

        // Update playback anchor for smooth elapsed interpolation.
        if isPlaying != newPlaying || abs(anchorElapsed - newElapsed) > 2 || playbackRate != newRate {
            anchorDate    = Date()
            anchorElapsed = newElapsed
            playbackRate  = newRate
        }
        if isPlaying != newPlaying { isPlaying = newPlaying }

        // Source app — update only when source changes.
        if bundleID != lastBundleID {
            lastBundleID = bundleID
            if let bid = bundleID,
               let app = NSWorkspace.shared.runningApplications
                   .first(where: { $0.bundleIdentifier == bid }) {
                self.appName = displayName ?? app.localizedName ?? ""
                self.appIcon = appIcon ?? app.icon
            } else if let displayName {
                self.appName = displayName
                self.appIcon = appIcon
            }
            artworkImage  = nil   // clear stale artwork when source changes
            lastArtworkData = nil
        }

        // Artwork — decode only when data actually changes.
        if let art = artwork { artworkImage = art }
    }

    private func updateSourceApp(bundleID: String?, displayName: String?) {
        guard bundleID != lastBundleID else { return }
        lastBundleID = bundleID
        if let bid = bundleID,
           let app = NSWorkspace.shared.runningApplications
               .first(where: { $0.bundleIdentifier == bid }) {
            appName = displayName ?? app.localizedName ?? ""
            appIcon = app.icon
        } else {
            appName = displayName ?? ""
        }
    }

    private func clearPlayback() {
        if isPlaying  { isPlaying  = false }
        playbackRate  = 0
    }

    // MARK: - Smooth elapsed (anchor-based, runs at 4 fps via displayTimer)

    private func tickElapsed() {
        guard isPlaying, playbackRate > 0, duration > 0 else { return }
        let computed = anchorElapsed + Date().timeIntervalSince(anchorDate) * playbackRate
        let clamped  = min(computed, duration)
        if abs(elapsed - clamped) > 0.15 { elapsed = clamped }
    }

    // MARK: - Browser AppleScript fallback

    private func fetchFromBrowsers() async
        -> (title: String, artist: String, isPlaying: Bool, elapsed: Double, duration: Double, bundleID: String)? {
        let candidates: [(id: String, asName: String, safari: Bool)] = [
            ("com.apple.Safari",      "Safari",         true ),
            ("com.google.Chrome",     "Google Chrome",  false),
            ("com.brave.Browser",     "Brave Browser",  false),
            ("org.chromium.Chromium", "Chromium",       false),
            ("com.microsoft.edgemac", "Microsoft Edge", false),
        ]
        let running = NSWorkspace.shared.runningApplications
        for c in candidates {
            guard running.contains(where: { $0.bundleIdentifier == c.id }) else { continue }
            let r = c.safari ? await pollSafari() : await pollChromium(c.asName)
            if let r { return (r.title, r.artist, r.isPlaying, r.elapsed, r.duration, c.id) }
        }
        return nil
    }

    private let jsQuery = """
    (function(){
      var m = Array.from(document.querySelectorAll('video,audio'))
               .find(function(e){ return !e.paused && !e.ended && e.currentTime > 0; });
      if (!m) return '';
      var ms = navigator.mediaSession && navigator.mediaSession.metadata;
      var ti = ms ? ms.title  || '' : '';
      var ar = ms ? ms.artist || ms.album || '' : '';
      if (!ti) ti = document.title || '';
      if (!ar) { var og = document.querySelector('meta[property=og:site_name]');
                 if (og) ar = og.getAttribute('content') || ''; }
      return JSON.stringify({title:ti, artist:ar,
             elapsed:Math.floor(m.currentTime||0), duration:Math.floor(m.duration)||0});
    })()
    """

    private func pollSafari() async -> (title: String, artist: String, isPlaying: Bool, elapsed: Double, duration: Double)? {
        let s = "tell application \"Safari\"\nif (count of windows)=0 then return \"\"\ntry\nset r to do JavaScript \"\(jsQuery)\" in current tab of front window\nreturn r\nend try\nend tell\nreturn \"\""
        return parseJSON(await runAS(s))
    }

    private func pollChromium(_ app: String) async -> (title: String, artist: String, isPlaying: Bool, elapsed: Double, duration: Double)? {
        let s = "tell application \"\(app)\"\nif (count of windows)=0 then return \"\"\ntry\nset r to execute active tab of front window javascript \"\(jsQuery)\"\nreturn r\nend try\nend tell\nreturn \"\""
        return parseJSON(await runAS(s))
    }

    private func parseJSON(_ json: String?) -> (title: String, artist: String, isPlaying: Bool, elapsed: Double, duration: Double)? {
        guard let j = json, !j.isEmpty,
              let d = j.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["title"] as? String, !t.isEmpty else { return nil }
        return (t, o["artist"] as? String ?? "", true,
                o["elapsed"] as? Double ?? 0, o["duration"] as? Double ?? 0)
    }

    // MARK: - Transport controls

    func togglePlayPause() {
        let shouldPlay = !isPlaying

        // Optimistic: flip immediately so button reflects the tap.
        isPlaying = shouldPlay
        if shouldPlay {
            anchorDate = Date()
            playbackRate = max(playbackRate, 1)
        } else {
            playbackRate = 0
        }

        let commandSent = MediaRemoteBridge.shared.sendCommand(shouldPlay ? .play : .pause)

        if let bid = lastBundleID, isBrowser(bid) {
            Task { await browserSetPlaying(bundleID: bid, shouldPlay: shouldPlay) }
        } else if !commandSent {
            _ = MediaInfoProvider.shared.handleMediaCommand([shouldPlay ? "play" : "pause"])
        }

        // Confirm real state after action settles.
        scheduleFetch(delay: 0.18)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            await self?.refreshNowPlaying()
        }
    }

    func skipBack(seconds: Double = 15) {
        let t = max(0, elapsed - seconds)
        elapsed = t; anchorDate = Date(); anchorElapsed = t
        MediaRemoteBridge.shared.setElapsedTime(t)
        if let bid = lastBundleID, isBrowser(bid) {
            Task.detached { await self.browserSeek(bundleID: bid, to: t) }
        }
    }

    func skipForward(seconds: Double = 15) {
        let t = duration > 0 ? min(elapsed + seconds, duration) : elapsed + seconds
        elapsed = t; anchorDate = Date(); anchorElapsed = t
        MediaRemoteBridge.shared.setElapsedTime(t)
        if let bid = lastBundleID, isBrowser(bid) {
            Task.detached { await self.browserSeek(bundleID: bid, to: t) }
        }
    }

    func dismiss() { isDismissed = true }

    func refreshNowPlaying() async { scheduleFetch(delay: 0) }

    // MARK: - Browser helpers

    private func isBrowser(_ bid: String) -> Bool {
        ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser",
         "org.chromium.Chromium", "com.microsoft.edgemac",
         "com.operasoftware.Opera", "com.vivaldi.Vivaldi"].contains(bid)
    }

    private func browserSetPlaying(bundleID: String, shouldPlay: Bool) async {
        let js = shouldPlay
            ? "var v=document.querySelector('video,audio');if(v&&v.paused){v.play()}"
            : "var v=document.querySelector('video,audio');if(v&&!v.paused){v.pause()}"
        if bundleID == "com.apple.Safari" {
            await runAS("tell application \"Safari\"\ntell current tab of front window\ndo JavaScript \"\(js)\"\nend tell\nend tell")
        } else if let n = appName.isEmpty ? nil : appName {
            await runAS("tell application \"\(n)\"\nexecute active tab of front window javascript \"\(js)\"\nend tell")
        }
    }

    private func browserSeek(bundleID: String, to pos: Double) async {
        let js = "var v=document.querySelector('video,audio');if(v)v.currentTime=\(pos);"
        if bundleID == "com.apple.Safari" {
            await runAS("tell application \"Safari\"\ntell current tab of front window\ndo JavaScript \"\(js)\"\nend tell\nend tell")
        } else if let n = appName.isEmpty ? nil : appName {
            await runAS("tell application \"\(n)\"\nexecute active tab of front window javascript \"\(js)\"\nend tell")
        }
    }

    @discardableResult
    private func runAS(_ src: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var e: NSDictionary?
                guard let s = NSAppleScript(source: src) else { cont.resume(returning: nil); return }
                cont.resume(returning: s.executeAndReturnError(&e).stringValue)
            }
        }
    }
}

// MARK: - Now Playing Pulse Icon (kept for any remaining references)

struct NowPlayingPulseIcon: View {
    var isPlaying: Bool
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(pulse ? 0 : 0.4), lineWidth: 1.5)
                .frame(width: 36, height: 36).scaleEffect(pulse ? 1.7 : 1.0)
                .animation(isPlaying ? .easeOut(duration: 1.3).repeatForever(autoreverses: false) : .default, value: pulse)
            Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.accentColor)
        }
        .frame(width: 36, height: 36)
        .onAppear { if isPlaying { pulse = true } }
        .onChange(of: isPlaying) { v in pulse = v }
    }
}

// MARK: - L3 Media Dock View

struct NowPlayingL3View: View {
    @ObservedObject var observer: MediaPlayerObserver

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Artwork / app icon
                Group {
                    if let art = observer.artworkImage {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else if let icon = observer.appIcon {
                        Image(nsImage: icon).resizable()
                    } else {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.primary.opacity(0.10))
                            .overlay(Image(systemName: "music.note")
                                .font(.system(size: 13)).foregroundStyle(.secondary))
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7))

                // Title + subtitle
                VStack(alignment: .leading, spacing: 1) {
                    Text(observer.title.isEmpty
                         ? (observer.appName.isEmpty ? "Now Playing" : observer.appName)
                         : observer.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).foregroundStyle(.primary)
                    Text(observer.artist.isEmpty ? observer.appName : observer.artist)
                        .font(.system(size: 10))
                        .lineLimit(1).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Controls
                HStack(spacing: 4) {
                    L3Btn(systemName: "gobackward.15", size: 12) { observer.skipBack() }
                    L3Btn(systemName: observer.isPlaying ? "pause.fill" : "play.fill",
                          size: 13, filled: true) { observer.togglePlayPause() }
                    L3Btn(systemName: "goforward.15", size: 12) { observer.skipForward() }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            // Thin progress strip
            if observer.duration > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.08))
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(width: max(0, geo.size.width *
                                   CGFloat(observer.elapsed / max(observer.duration, 1))))
                    }
                }
                .frame(height: 3)
                .animation(.linear(duration: 0.25), value: observer.elapsed)
            }
        }
    }
}

private struct L3Btn: View {
    let systemName: String
    var size: CGFloat = 13
    var filled: Bool = false
    var tint: Color = .primary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(filled ? .white : tint)
                .frame(width: filled ? 30 : 26, height: filled ? 30 : 26)
                .background(filled ? Color.accentColor : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: filled ? 8 : 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stubs for compilation

struct MediaControllerRow: View {
    @ObservedObject var observer: MediaPlayerObserver
    var onDismiss: () -> Void
    var body: some View { EmptyView() }
}

struct MediaHoverCard: View {
    @ObservedObject var observer: MediaPlayerObserver
    var onClose: () -> Void
    var body: some View { EmptyView() }
}
