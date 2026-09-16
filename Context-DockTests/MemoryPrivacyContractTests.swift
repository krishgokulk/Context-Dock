import Foundation
import Testing
@testable import Context_Dock

@Suite(.serialized)
struct MemoryPrivacyContractTests {
    @Test
    func conversationDistillationIsOptIn() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ConversationDistiller.automaticDistillationKey)
        #expect(ConversationDistiller.isAutomaticDistillationEnabled == false)

        defaults.set(true, forKey: ConversationDistiller.automaticDistillationKey)
        #expect(ConversationDistiller.isAutomaticDistillationEnabled == true)
        defaults.removeObject(forKey: ConversationDistiller.automaticDistillationKey)
    }

    @Test
    func explicitMemoryCarriesReadableProvenance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryPrivacyContract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownMemoryStore(rootOverride: root)
        let capturedAt = try #require(
            ISO8601DateFormatter().date(from: "2026-08-23T09:30:00Z"))

        let result = store.remember(
            "Remember that Context Dock live context is ephemeral by default.",
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            capturedAt: capturedAt
        )

        #expect(result?.contains("Remembered") == true)
        let appMemory = root.appendingPathComponent("apps/com.apple.Safari.md")
        let markdown = try String(contentsOf: appMemory, encoding: .utf8)
        #expect(markdown.contains("- Context Dock live context is ephemeral by default"))
        #expect(markdown.contains("source: explicit-user-request"))
        #expect(markdown.contains("confidence: explicit"))
        #expect(markdown.contains("captured-at: 2026-08-23T09:30:00Z"))
        #expect(markdown.contains("source-app: Safari"))
        #expect(markdown.contains("source-bundle-id: com.apple.Safari"))
    }

    @Test
    func ordinaryTextDoesNotBecomeDurableMemory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryPrivacyContract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MarkdownMemoryStore(rootOverride: root)
        let before = store.fileSummaries().map { "\($0.relativePath):\($0.factCount)" }

        let result = store.remember("Safari is currently showing a private account page.")

        #expect(result == nil)
        let after = store.fileSummaries().map { "\($0.relativePath):\($0.factCount)" }
        #expect(after == before)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("observed.md").path
        ) == false)
    }
}
