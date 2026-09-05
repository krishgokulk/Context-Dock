import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct CornerGeneralChatTests {
    @Test func removingTheActiveAppReturnsToUnscopedGeneralChat() {
        let model = GeneralChatWindowModel()
        model.openSession(.app(bundleId: "com.apple.Safari"), title: "Safari")

        model.removeApp("Safari")

        #expect(model.activeScope == .general)
        #expect(model.scopeAppNames.isEmpty)
    }

    /// The two modes are one surface. General resting on a taller row than App made the
    /// switch between them look like the window had changed rather than the scope.
    @Test func emptyChatRestsAtExactlyTheAppComposerHeight() {
        #expect(
            CornerGeneralChatMetrics.height(
                messageCount: 0, isSending: false,
                hasAttachments: false, slashMatchCount: 0)
                == AppChatPromptMetrics.inputHeight)
    }

    @Test func anAttachmentAddsItsRowAndNothingElse() {
        let bare = CornerGeneralChatMetrics.height(
            messageCount: 0, isSending: false,
            hasAttachments: false, slashMatchCount: 0)
        let withFile = CornerGeneralChatMetrics.height(
            messageCount: 0, isSending: false,
            hasAttachments: true, slashMatchCount: 0)

        #expect(withFile - bare == CornerGeneralChatMetrics.attachmentRowHeight)
    }

    /// The starter card is measured from the start screen's own numbers, not pinned to a
    /// constant. It used to be a flat 350 holding 234 points of content, and the slack read
    /// as a card that could not decide what it was for.
    @Test func freshGeneralChatShowsStartersThenTypingCollapsesToComposer() {
        let starters = CornerGeneralChatMetrics.height(
            messageCount: 0, isSending: false,
            hasAttachments: false, slashMatchCount: 0,
            showsStarter: true, starterCount: 3, starterHasConnections: true)
        let typing = CornerGeneralChatMetrics.height(
            messageCount: 0, isSending: false,
            hasAttachments: false, slashMatchCount: 0,
            showsStarter: false)

        #expect(
            starters
                == CornerGeneralChatMetrics.compactHeight
                    + GeneralChatStartView.Metrics.compactHeight(
                        starters: 3, hasConnections: true))
        #expect(starters > typing)
        #expect(typing == CornerGeneralChatMetrics.compactHeight)
    }

    /// Fewer connected apps is a shorter card, not the same card with holes in it.
    @Test func theStarterCardShrinksWithWhatItHasToShow() {
        func starter(_ count: Int) -> CGFloat {
            CornerGeneralChatMetrics.height(
                messageCount: 0, isSending: false,
                hasAttachments: false, slashMatchCount: 0,
                showsStarter: true, starterCount: count, starterHasConnections: count > 0)
        }

        #expect(starter(1) < starter(3))
        #expect(starter(0) < starter(1))
        // Three is the most it ever offers, so a fourth adapter changes nothing.
        #expect(starter(8) == starter(3))
    }

    @Test func resultsExpandAndRemainCapped() {
        let oneResult = CornerGeneralChatMetrics.height(
            messageCount: 1, isSending: false,
            hasAttachments: false, slashMatchCount: 0)
        let longThread = CornerGeneralChatMetrics.height(
            messageCount: 100, isSending: false,
            hasAttachments: false, slashMatchCount: 0)

        #expect(oneResult > CornerGeneralChatMetrics.compactHeight)
        #expect(longThread == 620)
    }

    /// The matches are a list above the composer, so the card carries their exact height.
    /// A flat reservation was wrong in both directions: too tall for one match, and too
    /// short for four, which pushed the list out through the top of the card.
    @Test func slashMatchesReserveOneRowEach() {
        func height(_ matches: Int) -> CGFloat {
            CornerGeneralChatMetrics.height(
                messageCount: 0, isSending: false,
                hasAttachments: false, slashMatchCount: matches)
        }
        let bare = height(0)

        #expect(
            height(1) - bare
                == ChatSlashAppList.rowHeight + ChatSlashAppList.verticalInset * 2
                    + CornerGeneralChatMetrics.dividerHeight)
        #expect(height(3) - height(1) == ChatSlashAppList.rowHeight * 2)
        // No list, no inset: an empty picker must not leave a gap above the field.
        #expect(ChatSlashAppList.height(for: 0) == 0)
    }

    /// Past five it scrolls rather than growing, so the picker can never become the surface.
    @Test func theSlashListStopsGrowingAtItsVisibleLimit() {
        func height(_ matches: Int) -> CGFloat {
            CornerGeneralChatMetrics.height(
                messageCount: 0, isSending: false,
                hasAttachments: false, slashMatchCount: matches)
        }

        #expect(height(ChatSlashAppList.maxVisibleRows) == height(40))
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
