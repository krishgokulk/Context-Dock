import Testing
import Foundation
@testable import Context_Dock

// MARK: - PinnedApp Codable round-trip tests
// These cover a real data-loss risk: if PinnedApp ever fails to encode/decode,
// the user's pinned apps silently disappear on the next launch.

struct PinnedAppCodableTests {

    @Test func roundTripApplicationType() throws {
        let original = PinnedApp(
            name: "Safari",
            path: "/Applications/Safari.app",
            bundleIdentifier: "com.apple.Safari",
            type: .application
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PinnedApp.self, from: data)

        #expect(decoded.name == original.name)
        #expect(decoded.path == original.path)
        #expect(decoded.bundleIdentifier == original.bundleIdentifier)
        #expect(decoded.type == original.type)
        #expect(decoded.id == original.id)
    }

    @Test func roundTripFileType() throws {
        let original = PinnedApp(
            name: "resume.pdf",
            path: "/Users/test/Documents/resume.pdf",
            bundleIdentifier: nil,
            type: .file
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PinnedApp.self, from: data)

        #expect(decoded.name == original.name)
        #expect(decoded.path == original.path)
        #expect(decoded.bundleIdentifier == nil)
        #expect(decoded.type == .file)
    }

    @Test func roundTripFolderType() throws {
        let original = PinnedApp(
            name: "Documents",
            path: "/Users/test/Documents",
            type: .folder
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PinnedApp.self, from: data)
        #expect(decoded.type == .folder)
    }

    @Test func roundTripShortcutType() throws {
        let original = PinnedApp(
            name: "My Shortcut",
            path: "shortcut://run/My%20Shortcut",
            type: .shortcut
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PinnedApp.self, from: data)
        #expect(decoded.type == .shortcut)
    }

    @Test func roundTripArray() throws {
        let apps = [
            PinnedApp(name: "Safari", path: "/Applications/Safari.app", bundleIdentifier: "com.apple.Safari"),
            PinnedApp(name: "Notes", path: "/Applications/Notes.app", bundleIdentifier: "com.apple.Notes"),
        ]
        let data = try JSONEncoder().encode(apps)
        let decoded = try JSONDecoder().decode([PinnedApp].self, from: data)

        #expect(decoded.count == 2)
        #expect(decoded[0].name == "Safari")
        #expect(decoded[1].name == "Notes")
    }

    @Test func encodesAsValidJSON() throws {
        let app = PinnedApp(name: "Test", path: "/test", bundleIdentifier: "com.test")
        let data = try JSONEncoder().encode(app)
        // Should be parseable as a JSON object
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        #expect(json?["name"] as? String == "Test")
    }
}

// MARK: - BrowserItem Codable round-trip tests

struct BrowserItemCodableTests {

    @Test func roundTripBookmark() throws {
        let original = BrowserItem(
            title: "Apple",
            url: "https://apple.com",
            favicon: "safari",
            type: .bookmark
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BrowserItem.self, from: data)

        #expect(decoded.title == original.title)
        #expect(decoded.url == original.url)
        #expect(decoded.favicon == original.favicon)
        #expect(decoded.type == .bookmark)
        #expect(decoded.id == original.id)
    }

    @Test func roundTripPinnedSite() throws {
        let original = BrowserItem(title: "GitHub", url: "https://github.com", type: .pinnedSite)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BrowserItem.self, from: data)
        #expect(decoded.type == .pinnedSite)
        #expect(decoded.favicon == nil)
    }
}

// MARK: - AppToolProfile Codable tests

struct AppToolProfileCodableTests {

    @Test func defaultProfileRoundTrip() throws {
        let profile = AppToolProfile()
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AppToolProfile.self, from: data)

        #expect(decoded.capabilities.isEmpty)
        #expect(decoded.exampleCommands.isEmpty)
        #expect(decoded.fileTypes.isEmpty)
        #expect(decoded.isDestructive == false)
    }

    @Test func populatedProfileRoundTrip() throws {
        let profile = AppToolProfile(
            capabilities: ["list files", "delete files"],
            exampleCommands: ["rm -rf"],
            fileTypes: ["pdf", "txt"],
            isDestructive: true
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AppToolProfile.self, from: data)

        #expect(decoded.capabilities == ["list files", "delete files"])
        #expect(decoded.exampleCommands == ["rm -rf"])
        #expect(decoded.fileTypes == ["pdf", "txt"])
        #expect(decoded.isDestructive == true)
    }

    @Test func synthesizedHintIsNonEmptyWhenPopulated() {
        let profile = AppToolProfile(capabilities: ["list files"], exampleCommands: ["ls"])
        #expect(!profile.synthesizedHint.isEmpty)
    }

    @Test func synthesizedHintIsEmptyWhenProfileIsEmpty() {
        let profile = AppToolProfile()
        #expect(profile.synthesizedHint.isEmpty)
    }
}
