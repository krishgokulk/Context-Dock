import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct CornerGeneralChatTests {
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
