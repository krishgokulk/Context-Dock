import Foundation

// First-party Apple Music capabilities. Wraps AppleAppsAPI (AppleScript) reads.
//   music.nowPlaying → current track (read-only → .low)
//   music.volume     → current output volume (read-only → .low)

@MainActor
enum AppleMusicMCPCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerNowPlaying(registry)
        registerVolume(registry)
    }

    private static func registerNowPlaying(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "music.nowPlaying",
                title: "Get Now Playing",
                appBundleID: "com.apple.Music",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                guard AppSettings.shared.musicMCPEnabled else {
                    throw AICapabilityError.blocked("Music access is disabled in Settings.")
                }
                let info = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getMusicInfo())
                    }
                }
                let title = (info["title"] as? String) ?? ""
                guard !title.isEmpty else {
                    return .init(success: true, output: "Nothing is playing in Music right now.")
                }
                let artist = (info["artist"] as? String) ?? ""
                let album = (info["album"] as? String) ?? ""
                let state = (info["playerState"] as? String) ?? (info["isPlaying"] as? Bool == true ? "playing" : "")
                var out = "Now playing: \(title)"
                if !artist.isEmpty { out += " — \(artist)" }
                if !album.isEmpty { out += " (\(album))" }
                if !state.isEmpty { out += " · \(state)" }
                return .init(success: true, output: out)
            }
        )
    }

    private static func registerVolume(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "music.volume",
                title: "Get Music Volume",
                appBundleID: "com.apple.Music",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                guard AppSettings.shared.musicMCPEnabled else {
                    throw AICapabilityError.blocked("Music access is disabled in Settings.")
                }
                let volume = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getMusicVolume())
                    }
                }
                guard let volume else {
                    return .init(success: true, output: "Music isn't running.")
                }
                return .init(success: true, output: "Music volume: \(volume)%")
            }
        )
    }
}
