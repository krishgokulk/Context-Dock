//
//  MediaInfoProvider.swift
//  ILauncher
//
//  Provides media information via command-line interface for bash extensions
//

import Foundation
import AppKit
import MediaPlayer

class MediaInfoProvider {
    static let shared = MediaInfoProvider()

    private init() {}

    // MARK: - Main Entry Point

    /// Handle command-line requests from extensions
    /// Usage: ilauncher-api media [command]
    func handleMediaCommand(_ args: [String]) -> String {
        guard !args.isEmpty else {
            return getMediaInfoJSON()
        }

        let command = args[0]

        switch command {
        case "info", "now-playing":
            return getMediaInfoJSON()
        case "title":
            return getCurrentTitle()
        case "artist":
            return getCurrentArtist()
        case "album":
            return getCurrentAlbum()
        case "state":
            return getPlaybackState()
        case "duration":
            return getDuration()
        case "position":
            return getPosition()
        case "artwork":
            return getArtworkPath()
        case "play":
            sendMediaCommand(.play)
            return "playing"
        case "pause":
            sendMediaCommand(.pause)
            return "paused"
        case "toggle":
            sendMediaCommand(.togglePlayPause)
            return "toggled"
        case "next":
            sendMediaCommand(.nextTrack)
            return "next"
        case "previous", "prev":
            sendMediaCommand(.previousTrack)
            return "previous"
        default:
            return "{\"error\": \"Unknown command: \(command)\"}"
        }
    }

    // MARK: - Media Information

    private func getMediaInfoJSON() -> String {
        let info = getNowPlayingInfo()

        let json: [String: Any] = [
            "title": info.title ?? "",
            "artist": info.artist ?? "",
            "album": info.album ?? "",
            "state": info.state,
            "duration": info.duration,
            "position": info.position,
            "playbackRate": info.playbackRate,
            "hasArtwork": info.hasArtwork,
            "isPlaying": info.state == "playing"
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return "{}"
    }

    private func getCurrentTitle() -> String {
        return getNowPlayingInfo().title ?? ""
    }

    private func getCurrentArtist() -> String {
        return getNowPlayingInfo().artist ?? ""
    }

    private func getCurrentAlbum() -> String {
        return getNowPlayingInfo().album ?? ""
    }

    private func getPlaybackState() -> String {
        return getNowPlayingInfo().state
    }

    private func getDuration() -> String {
        return String(getNowPlayingInfo().duration)
    }

    private func getPosition() -> String {
        return String(getNowPlayingInfo().position)
    }

    private func getArtworkPath() -> String {
        // TODO: Save artwork to temp file and return path
        return ""
    }

    // MARK: - Get Now Playing Info

    func getNowPlayingInfo() -> (title: String?, artist: String?, album: String?, state: String, duration: Double, position: Double, playbackRate: Double, hasArtwork: Bool) {

        // Try MPNowPlayingInfoCenter first (works with most apps)
        if #available(macOS 10.12.2, *) {
            let infoCenter = MPNowPlayingInfoCenter.default()
            if let info = infoCenter.nowPlayingInfo {
                let title = info[MPMediaItemPropertyTitle] as? String
                let artist = info[MPMediaItemPropertyArtist] as? String
                let album = info[MPMediaItemPropertyAlbumTitle] as? String
                let duration = info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0
                let position = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
                let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
                let artwork = info[MPMediaItemPropertyArtwork] != nil

                let state = rate > 0 ? "playing" : "paused"

                if title != nil {
                    return (title, artist, album, state, duration, position, rate, artwork)
                }
            }
        }

        // Fallback to checking specific apps via AppleScript
        if let musicInfo = checkMusicApp() {
            return musicInfo
        }

        if let spotifyInfo = checkSpotifyApp() {
            return spotifyInfo
        }

        return (nil, nil, nil, "stopped", 0, 0, 0, false)
    }

    // MARK: - App-Specific Checks

    private func checkMusicApp() -> (title: String?, artist: String?, album: String?, state: String, duration: Double, position: Double, playbackRate: Double, hasArtwork: Bool)? {
        let script = """
        tell application "Music"
            if player state is not stopped then
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                set playerState to player state as text

                return trackName & "|" & artistName & "|" & albumName & "|" & playerState & "|" & trackDuration & "|" & trackPosition
            end if
        end tell
        return ""
        """

        if let result = runAppleScript(script), !result.isEmpty {
            let parts = result.components(separatedBy: "|")
            if parts.count >= 6 {
                let state = parts[3] == "playing" ? "playing" : "paused"
                let duration = Double(parts[4]) ?? 0
                let position = Double(parts[5]) ?? 0
                let rate = state == "playing" ? 1.0 : 0.0

                return (parts[0], parts[1], parts[2], state, duration, position, rate, false)
            }
        }

        return nil
    }

    private func checkSpotifyApp() -> (title: String?, artist: String?, album: String?, state: String, duration: Double, position: Double, playbackRate: Double, hasArtwork: Bool)? {
        let script = """
        tell application "System Events"
            if exists (process "Spotify") then
                tell application "Spotify"
                    if player state is not stopped then
                        set trackName to name of current track
                        set artistName to artist of current track
                        set albumName to album of current track
                        set trackDuration to duration of current track
                        set trackPosition to player position
                        set playerState to player state as text

                        return trackName & "|" & artistName & "|" & albumName & "|" & playerState & "|" & trackDuration & "|" & trackPosition
                    end if
                end tell
            end if
        end tell
        return ""
        """

        if let result = runAppleScript(script), !result.isEmpty {
            let parts = result.components(separatedBy: "|")
            if parts.count >= 6 {
                let state = parts[3] == "playing" ? "playing" : "paused"
                let duration = Double(parts[4]) ?? 0
                let position = Double(parts[5]) ?? 0
                let rate = state == "playing" ? 1.0 : 0.0

                return (parts[0], parts[1], parts[2], state, duration, position, rate, false)
            }
        }

        return nil
    }

    // MARK: - Media Commands

    private func sendMediaCommand(_ command: MediaCommand) {
        let keyCode: Int

        switch command {
        case .play, .pause, .togglePlayPause:
            keyCode = 16 // Play/Pause
        case .nextTrack:
            keyCode = 17 // Next
        case .previousTrack:
            keyCode = 18 // Previous
        }

        let script = """
        tell application "System Events"
            key code \(keyCode)
        end tell
        """

        _ = runAppleScript(script)
    }

    enum MediaCommand {
        case play
        case pause
        case togglePlayPause
        case nextTrack
        case previousTrack
    }

    // MARK: - Helper

    private func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let output = scriptObject.executeAndReturnError(&error)
            if error == nil, let result = output.stringValue {
                return result
            }
        }
        return nil
    }
}
