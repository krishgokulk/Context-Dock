import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct CornerGeneralChatTests {
    @Test func emptyChatUsesCompactComposerHeight() {
        #expect(CornerGeneralChatMetrics.height(
            messageCount: 0, isSending: false,
            hasAttachments: false, slashMatchCount: 0) == 72)
    }

    @Test func freshGeneralChatShowsStartersThenTypingCollapsesToComposer() {
        let starters = CornerGeneralChatMetrics.height(
            messageCount: 0, isSending: false,
            hasAttachments: false, slashMatchCount: 0,
            showsStarter: true)
        let typing = CornerGeneralChatMetrics.height(
            messageCount: 0, isSending: false,
            hasAttachments: false, slashMatchCount: 0,
            showsStarter: false)

        #expect(starters == 350)
        #expect(typing == 72)
    }

    @Test func resultsExpandAndRemainCapped() {
        let oneResult = CornerGeneralChatMetrics.height(
            messageCount: 1, isSending: false,
            hasAttachments: false, slashMatchCount: 0)
        let longThread = CornerGeneralChatMetrics.height(
            messageCount: 100, isSending: false,
            hasAttachments: false, slashMatchCount: 0)

        #expect(oneResult > 72)
        #expect(longThread == 620)
    }

    @Test func slashMatchesGrowOnlyEnoughForPicker() {
        #expect(CornerGeneralChatMetrics.height(
            messageCount: 0, isSending: false,
            hasAttachments: false, slashMatchCount: 3) == 118)
    }

    @Test func snapshotUsesTheModelsLiveState() {
        let model = GeneralChatWindowModel()
        model.input = "/terminal"
        model.attachments = [URL(fileURLWithPath: "/tmp/log.txt")]

        let snapshot = CornerGeneralChatSnapshot(model: model)

        #expect(snapshot.draft == "/terminal")
        #expect(snapshot.attachmentNames == ["log.txt"])
        #expect(snapshot.slashApps.first?.name == "Terminal")
    }

    @Test func pickingSlashAppScopesWithoutSendingText() {
        let model = GeneralChatWindowModel()
        model.input = "/message"

        let picked = CornerGeneralChatSnapshot.pickLeadingSlashApp(in: model)

        #expect(picked)
        #expect(model.input.isEmpty)
        #expect(model.scopeAppNames.contains("Messages"))
        #expect(!model.messages.contains { $0.content == "/message" })
    }
}
