// AppBundleLinks.swift
// Context-Dock
//
// The vendor's own links, read out of the app that is already on disk.
//
// An app's Help menu names its homepage — "Tutorini Home Page", "View Repository",
// "Pearcleaner Help" — and DoraX caches those menus, so it knows the door is there. It cannot
// read where the door leads: a menu item is a title and a path, and the URL only exists inside
// the app's own code, handed to NSWorkspace when the item is clicked.
//
// So the URL is looked for where it actually lives. The Info.plist first, then the App Store's
// listing for the bundle id, then the strings compiled into the binary. Nothing here guesses:
// every candidate is a literal URL shipped inside that app or published by Apple about it, and
// the obvious noise — Apple's own schemas, analytics endpoints, font CDNs — is dropped rather
// than offered as documentation.

import AppKit
import Foundation

enum AppBundleLinks {

    /// Hosts that appear in almost every bundle and document nothing about the app.
    private static let noiseHosts = [
        "apple.com", "icloud.com", "w3.org", "schemas.", "xml.org", "openssl.org",
        "sentry.io", "crashlytics", "firebase", "googleapis.com", "google-analytics",
        "doubleclick", "facebook.com", "sparkle-project.org", "creativecommons.org",
        "gnu.org", "opensource.org", "mit-license", "unicode.org", "iana.org",
        "fonts.gstatic.com", "cdn.jsdelivr.net", "unpkg.com", "example.com",
    ]

    /// Links found inside the installed bundle, best first.
    static func fromBundle(bundleId: String, appName: String) -> [String] {
        guard let bundleURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleId)
        else { return [] }

        var candidates: [String] = []
        if let info = Bundle(url: bundleURL)?.infoDictionary {
            candidates += urls(inPropertyList: info)
        }
        candidates += urlsInExecutable(bundleURL: bundleURL)
        return rank(candidates, appName: appName, bundleId: bundleId)
    }

    /// The developer's website, as published on the App Store listing for this bundle id.
    ///
    /// Authoritative and cheap: one request, no key, and it covers every Mac App Store app —
    /// exactly the apps that carry neither a Sparkle feed nor a Homebrew cask.
    static func fromAppStore(bundleId: String) async -> [String] {
        guard !bundleId.isEmpty,
            let url = URL(
                string: "https://itunes.apple.com/lookup?bundleId=\(bundleId)&entity=macSoftware")
        else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await AIProviderService.directSession.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = json["results"] as? [[String: Any]], let first = results.first
        else { return [] }

        return [
            first["sellerUrl"] as? String,
            first["trackViewUrl"] as? String,
        ].compactMap { $0 }.filter { $0.hasPrefix("http") }
    }

    // MARK: - Reading

    private static func urls(inPropertyList value: Any) -> [String] {
        switch value {
        case let text as String:
            return text.hasPrefix("http") ? [text] : []
        case let array as [Any]:
            return array.flatMap { urls(inPropertyList: $0) }
        case let dictionary as [String: Any]:
            return dictionary.values.flatMap { urls(inPropertyList: $0) }
        default:
            return []
        }
    }

    /// URL literals compiled into the app's own binary.
    ///
    /// Read as bytes and scanned, rather than shelled out to `strings`: this runs while a chat
    /// is waiting, and spawning a process per app for something this simple is a cost with no
    /// return. Large executables are skipped — an Electron blob is 200 MB of Chromium whose
    /// URLs belong to Chromium, not to the app.
    private static func urlsInExecutable(bundleURL: URL) -> [String] {
        guard let executableName = Bundle(url: bundleURL)?
            .infoDictionary?["CFBundleExecutable"] as? String
        else { return [] }
        let executable = bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: executable.path),
            let size = attributes[.size] as? Int, size < 60_000_000,
            let data = try? Data(contentsOf: executable, options: .mappedIfSafe)
        else { return [] }

        let needle = Array("https://".utf8)
        var found: [String] = []
        var index = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            while index + needle.count < bytes.count, found.count < 200 {
                guard bytes[index] == needle[0],
                    Array(bytes[index..<min(index + needle.count, bytes.count)]) == needle
                else {
                    index += 1
                    continue
                }
                var end = index
                // A URL literal ends at the first byte that cannot be in one — usually the
                // string's own null terminator.
                while end < bytes.count, bytes[end] > 0x20, bytes[end] < 0x7F,
                    bytes[end] != UInt8(ascii: "\""), bytes[end] != UInt8(ascii: "<"),
                    end - index < 300
                {
                    end += 1
                }
                if let text = String(bytes: bytes[index..<end], encoding: .utf8) {
                    found.append(text)
                }
                index = end
            }
        }
        return found
    }

    // MARK: - Ranking

    /// Keeps what could plausibly be this app's own documentation and drops the rest.
    ///
    /// The test is ownership, not shape: a URL earns its place by naming the app, or by being
    /// the repository or docs site of something that does. Everything else in a binary —
    /// licences, standards bodies, the analytics endpoint — is noise that would send a reader
    /// somewhere irrelevant with an authoritative-sounding citation attached.
    private static func rank(
        _ candidates: [String], appName: String, bundleId: String
    ) -> [String] {
        let token = appName.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
            .max(by: { $0.count < $1.count }) ?? appName.lowercased()
        // "app.tutorini.Tutorini" → "tutorini": the vendor's own domain word, without the
        // reversed-DNS scaffolding around it.
        let bundleWords = bundleId.lowercased().split(separator: ".").map(String.init)
            .filter { !["com", "org", "net", "io", "app", "co", "uk", "dev"].contains($0) }

        var seen = Set<String>()
        var kept: [(score: Int, url: String)] = []
        for raw in candidates {
            let url = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"',.;)]}"))
            guard url.count > 12, url.count < 300,
                let parsed = URL(string: url), let host = parsed.host?.lowercased(),
                seen.insert(url.lowercased()).inserted
            else { continue }
            guard !noiseHosts.contains(where: { host.contains($0) }) else { continue }

            let haystack = url.lowercased()
            var score = 0
            if host.contains(token) { score += 3 }
            if bundleWords.contains(where: { host.contains($0) }) { score += 3 }
            if bundleWords.contains(where: { haystack.contains("/\($0)") }) { score += 2 }
            if haystack.contains("github.com") || haystack.contains("gitlab.com") { score += 1 }
            if haystack.contains("/docs") || haystack.contains("docs.")
                || haystack.contains("/help") || haystack.contains("/guide")
            {
                score += 2
            }
            // Nothing tying it to this app: a URL that merely exists inside the binary is not
            // documentation of anything.
            guard score >= 3 else { continue }
            kept.append((score, url))
        }
        return kept.sorted { $0.score > $1.score }.prefix(6).map(\.url)
    }
}
