import Foundation
import Testing

@testable import Context_Dock

@Suite("App Pets Stage 2 — Participant Consent, Promotion & General Chat Isolation", .serialized)
struct AppPetStage2PromotionTests {

    private let testInventory: [GeneralChatScopeResolver.Candidate] = [
        .init(
            bundleId: "com.apple.mail",
            name: "Mail",
            vocabulary: ["mail", "email", "inbox", "invoice", "unread"]),
        .init(
            bundleId: "com.apple.finder",
            name: "Finder",
            vocabulary: ["finder", "file", "folder", "selection"]),
        .init(
            bundleId: "com.apple.MobileSMS",
            name: "Messages",
            vocabulary: ["messages", "imessage", "sms", "text"]),
        .init(
            bundleId: "com.apple.Notes",
            name: "Notes",
            vocabulary: ["notes", "note"]),
        .init(
            bundleId: "md.obsidian",
            name: "Obsidian",
            vocabulary: ["obsidian", "vault", "note"]),
    ]

    @Test("ConversationHeaderIdentity never produces a hybrid '<App> General Chat' title")
    func forbidsHybridMailGeneralChatIdentity() {
        let mailParticipant = ConversationParticipant(
            petID: .app(bundleID: "com.apple.mail"), displayName: "Mail")
        let finderParticipant = ConversationParticipant(
            petID: .app(bundleID: "com.apple.finder"), displayName: "Finder")
        let messagesParticipant = ConversationParticipant(
            petID: .app(bundleID: "com.apple.MobileSMS"), displayName: "Messages")

        let generalHeader = ConversationHeaderIdentity.make(
            kind: .general,
            participants: .empty,
            fallbackAppName: "Mail",
            providerShortName: "Claude")
        #expect(generalHeader.primaryTitle == "Claude")
        #expect(generalHeader.subtitle == "General Chat")
        #expect(!generalHeader.combinedHeaderText.contains("Mail General Chat"))
        #expect(generalHeader.participantNames.isEmpty)

        let mailPetHeader = ConversationHeaderIdentity.make(
            kind: .appPet(.app(bundleID: "com.apple.mail")),
            participants: ParticipantSet([mailParticipant]),
            fallbackAppName: "Mail",
            providerShortName: "Claude",
            previewChips: ["+ Messages"])
        #expect(mailPetHeader.primaryTitle == "Mail")
        #expect(!mailPetHeader.combinedHeaderText.contains("General Chat"))
        #expect(mailPetHeader.participantNames == ["Mail"])
        #expect(mailPetHeader.previewChips == ["+ Messages"])

        let combinedHeader = ConversationHeaderIdentity.make(
            kind: .combined,
            participants: ParticipantSet([finderParticipant, messagesParticipant]),
            fallbackAppName: "Finder",
            providerShortName: "Claude")
        #expect(combinedHeader.primaryTitle == "Finder + Messages")
        #expect(!combinedHeader.combinedHeaderText.contains("General Chat"))
        #expect(combinedHeader.participantNames == ["Finder", "Messages"])
    }

    @Test("One Mail turn in General Chat uses TurnScope, never loads Mail Pet memory, and keeps later turns Mac-wide")
    @MainActor
    func generalChatBorrowsMailForOneTurnWithoutConvertingOrLoadingPetMemory() {
        let model = GeneralChatWindowModel()
        model.openGeneralSession()
        model.clearActiveThread()

        #expect(model.conversationKind == .general)
        #expect(model.participantSet.isEmpty)
        #expect(model.conversationHeaderTitle == "General Chat")

        // Turn 1: User asks a Mail question in General Chat ("Check my unread emails").
        let mailQuery = "Check my unread emails from Sarah"
        let mailTurnScope = model.resolveTurnScope(for: mailQuery, inventory: testInventory)
        #expect(mailTurnScope.bundleIDs == ["com.apple.mail"])
        #expect(mailTurnScope.displayNames == ["Mail"])

        // Even if the user taps "Use Mail for this turn" on an EnableAppRequest in General Chat,
        // the conversation stays General Chat, ParticipantSet stays empty, and Mail Pet memory is not loaded.
        let mailRequest = EnableAppRequest(
            name: "Mail", bundleId: "com.apple.mail", query: mailQuery)
        #expect(mailRequest.actionButtonTitle(for: .general) == "Use Mail for this turn")

        model.enableApp(mailRequest, sendImmediately: false)
        #expect(model.conversationKind == .general)
        #expect(model.participantSet.isEmpty)
        #expect(model.attachedAppNames.isEmpty)
        #expect(model.activeTurnScope.bundleIDs == ["com.apple.mail"])
        #expect(model.headerIdentity().title == "General Chat")
        #expect(
            AppScopedChatService.memoryBundleID(
                for: model.activeScope,
                participants: model.participantSet,
                turnScope: model.activeTurnScope) == nil)

        // When Turn 1 finishes, activeTurnScope resets and Turn 2 ("Now quit other apps except Claude and ChatGPT")
        // is completely unscoped Mac-wide General Chat — never trapped inside Mail.
        let resetModel = GeneralChatWindowModel()
        resetModel.openGeneralSession()
        let macWideFollowUp = "Now quit other apps except Claude and ChatGPT"
        let followUpTurnScope = resetModel.resolveTurnScope(
            for: macWideFollowUp, inventory: testInventory)
        #expect(resetModel.conversationKind == .general)
        #expect(resetModel.participantSet.isEmpty)
        #expect(followUpTurnScope.isEmpty)
        #expect(
            AppScopedChatService.appNeedingAccess(
                query: macWideFollowUp,
                scope: .general,
                attachedAppNames: resetModel.attachedAppNames) == nil)
    }

    @Test("GeneralChatScopeResolver resolves multi-step TurnScope in order, respects explicit focus, and asks a closed question on ambiguity")
    func scopeResolverTurnScopeAndAmbiguity() {
        // 1. Unnamed multi-step request resolves to minimum required apps in order (Mail -> Finder).
        let multiStep = GeneralChatScopeResolver.resolveTurnScope(
            request: "Find the invoice in my inbox and move the file to my folder",
            conversationKind: .general,
            inventory: testInventory)
        #expect(!multiStep.isAmbiguous)
        #expect(multiStep.bundleIDs == ["com.apple.mail", "com.apple.finder"])
        #expect(multiStep.displayNames == ["Mail", "Finder"])

        // 2. Explicit focus wins over inferred resolution.
        let explicitMail = ConversationParticipant(
            petID: .app(bundleID: "com.apple.mail"), displayName: "Mail")
        let focused = GeneralChatScopeResolver.resolveTurnScope(
            request: "Find the note and move the file",
            conversationKind: .general,
            explicitTurnParticipants: [explicitMail],
            inventory: testInventory)
        #expect(focused.bundleIDs == ["com.apple.mail"])
        #expect(!focused.isAmbiguous)

        // 3. Ambiguous word ("note" matches both Notes and Obsidian) produces a closed clarification question.
        let ambiguous = GeneralChatScopeResolver.resolveTurnScope(
            request: "Find my project note from yesterday",
            conversationKind: .general,
            inventory: testInventory)
        #expect(ambiguous.isAmbiguous)
        #expect(ambiguous.ambiguousAppNames == ["Notes", "Obsidian"])
        #expect(
            ambiguous.clarificationQuestion
                == "That could use Notes or Obsidian. Which app should I use for this turn?")
    }

    @Test("Participant consent previews '+ Messages', declining leaves Finder Pet unchanged, and accepting promotes the same conversation without duplicating the transcript")
    @MainActor
    func participantConsentDeclineAndAtomicPromotion() {
        let finderBundle = "com.apple.finder"
        let messagesBundle = "com.apple.MobileSMS"
        let finderScope = GeneralChatScope.app(bundleId: finderBundle)
        let combinedScope = ParticipantSet([
            ConversationParticipant(petID: .app(bundleID: finderBundle), displayName: "Finder"),
            ConversationParticipant(petID: .app(bundleID: messagesBundle), displayName: "Messages"),
        ]).combinedScope

        // Clean any prior test state for Finder and Finder + Messages, and restore any
        // developer Finder panel messages afterwards.
        let existingFinderPanel = AppPanelChatStore.shared.load(for: "dock_app_\(finderBundle)")
        GeneralChatSessionStore.purge(scope: finderScope)
        GeneralChatSessionStore.purge(scope: combinedScope)
        defer {
            GeneralChatSessionStore.purge(scope: finderScope)
            GeneralChatSessionStore.purge(scope: combinedScope)
            if !existingFinderPanel.isEmpty {
                AppPanelChatStore.shared.save(existingFinderPanel, for: "dock_app_\(finderBundle)")
            }
        }

        let model = GeneralChatWindowModel()
        let initialSeed = [
            AIChatMessage(role: .user, content: "Summarize Q3-Report.pdf in Finder"),
            AIChatMessage(role: .assistant, content: "Q3 revenue grew 18% with 3 key highlights."),
        ]
        model.openInAppPet(bundleID: finderBundle, name: "Finder", seed: initialSeed)

        let attachedFile = URL(fileURLWithPath: "/tmp/Q3-Report.pdf")
        model.attachments = [attachedFile]

        #expect(model.conversationKind == .appPet(.app(bundleID: finderBundle)))
        #expect(model.participantSet.displayNames == ["Finder"])
        #expect(model.conversationHeaderTitle == "Finder")
        #expect(
            AppScopedChatService.memoryBundleID(
                for: model.activeScope, participants: model.participantSet) == finderBundle)

        // Minimum additional Pet required to send the summary in Messages:
        let crossAppQuery = "Send this summary to Alex in Messages"
        let minimumPets = GeneralChatScopeResolver.minimumAdditionalPets(
            request: crossAppQuery,
            currentParticipants: model.participantSet,
            inventory: testInventory)
        #expect(minimumPets.map(\.displayName) == ["Messages"])

        let consentRequest = EnableAppRequest(
            name: "Messages", bundleId: messagesBundle, query: crossAppQuery)
        #expect(consentRequest.previewChips == ["+ Messages"])
        #expect(consentRequest.previewBadgeText == "+ Messages")
        #expect(
            consentRequest.actionButtonTitle(for: model.conversationKind)
                == "Connect Messages to this chat")

        // Stage 1 of test: Decline participant connection.
        model.declineParticipantConnection(consentRequest)
        #expect(model.activeScope == finderScope)
        #expect(model.conversationKind == .appPet(.app(bundleID: finderBundle)))
        #expect(model.participantSet.displayNames == ["Finder"])
        #expect(model.attachments == [attachedFile])
        #expect(model.messages.last?.content.contains("Messages was not connected") == true)

        let countBeforePromotion = model.messages.count
        let firstMessageID = model.messages[0].id
        let secondMessageID = model.messages[1].id

        // Stage 2 of test: Accept participant connection -> promotes SAME conversation in-place.
        model.enableApp(consentRequest, sendImmediately: false)

        #expect(model.activeScope == combinedScope)
        #expect(model.conversationKind == .combined)
        #expect(model.participantSet.displayNames == ["Finder", "Messages"])
        #expect(model.conversationHeaderTitle == "Finder + Messages")
        #expect(model.headerIdentity().title == "Finder + Messages")

        // Same transcript messages (by UUID) and same attachments are preserved in the promoted thread:
        #expect(model.messages.count == countBeforePromotion + 1)
        #expect(model.messages[0].id == firstMessageID)
        #expect(model.messages[1].id == secondMessageID)
        #expect(model.attachments == [attachedFile])

        // No duplicate transcript copy remains in the old single-Pet Finder scope:
        #expect(GeneralChatSessionStore.load(scope: finderScope).isEmpty)
        #expect(
            !GeneralChatSessionStore.index().contains(where: { $0.scope == finderScope }))
        #expect(
            GeneralChatSessionStore.index().contains(where: {
                $0.scope == combinedScope && $0.title == "Finder + Messages"
            }))
    }

    @Test("Finder-read then Messages-send has one plan, one receipt stream, and two distinct consent points (connect Messages, then approve Send)")
    @MainActor
    func finderReadThenMessagesSendPlanAndConsentBoundaries() async {
        let finderBundle = "com.apple.finder"
        let messagesBundle = "com.apple.MobileSMS"
        let query = "Read the selected file in Finder, summarize it, and send it to Alex via iMessage"

        // 1. Consent point #1: Participant connection preview in Finder Pet.
        let accessRequest = AppScopedChatService.appNeedingAccess(
            query: query,
            scope: .app(bundleId: finderBundle),
            attachedAppNames: [])
        #expect(accessRequest != nil)
        #expect(accessRequest?.name == "Messages")
        #expect(accessRequest?.previewChips == ["+ Messages"])

        // Build the two-step cross-app plan (Step 1: Finder headless read; Step 2: Messages outbound send).
        let finderReadRoute = ChatRoute(
            id: "capability:finder.read_selected",
            kind: .adapterAction,
            title: "Read Selected File",
            payload: "finder.read_selected",
            appName: "Finder",
            bundleId: finderBundle,
            isReadOnly: true)
        let messagesSendRoute = ChatRoute(
            id: "mcp:messages:send_message",
            kind: .mcpTool,
            title: "Send Message to Alex",
            payload: "messages:send_message",
            appName: "Messages",
            bundleId: messagesBundle,
            isReadOnly: false)

        let plan = ChatPlan(
            steps: [
                ChatPlanStep(
                    route: finderReadRoute,
                    purpose: "Read and summarize the selected file in Finder",
                    dependsOn: []),
                ChatPlanStep(
                    route: messagesSendRoute,
                    purpose: "Send the summary to Alex in Messages",
                    dependsOn: [0]),
            ],
            summary: "Read selected file in Finder, then send summary via Messages")

        // Before connecting Messages, running the plan with only Finder authorized refuses step 2:
        let unauthorizedResults = await ChatPlanRunner.run(
            plan,
            query: query,
            authorizedBundleIds: [finderBundle],
            routeRunner: { route, _ in
                (true, "Ran \(route.title)", false)
            })
        #expect(unauthorizedResults.count == 2)
        #expect(unauthorizedResults[0].success == true)
        #expect(unauthorizedResults[1].success == false)
        #expect(unauthorizedResults[1].output.contains("Messages is not part of this conversation"))

        // 2. Consent point #2: Even after connecting Messages to the ParticipantSet,
        // consequential write/send/delete approval remains separate from participant connection.
        let promotedParticipants = ParticipantSet([
            ConversationParticipant(petID: .app(bundleID: finderBundle), displayName: "Finder"),
            ConversationParticipant(petID: .app(bundleID: messagesBundle), displayName: "Messages"),
        ])
        let combinedScope = promotedParticipants.combinedScope
        ChatConsoleLog.shared.clear(scope: combinedScope)

        #expect(ChatRouteResolver.executionApproval(for: finderReadRoute) == .granted(.accessPolicy))
        #expect(ChatRouteResolver.requiresActionApproval(for: finderReadRoute) == false)
        #expect(plan.steps[0].requiresActionApproval == false)

        #expect(ChatRouteResolver.executionApproval(for: messagesSendRoute) == .ask)
        #expect(ChatRouteResolver.requiresActionApproval(for: messagesSendRoute) == true)
        #expect(plan.steps[1].requiresActionApproval == true)

        // 3. Execute the connected + approved plan: one plan, dependency order, one receipt stream.
        var executedStepQueries: [(bundleId: String, query: String)] = []
        let authorizedSet = Set(promotedParticipants.bundleIDs.map { $0.lowercased() })
        let results = await ChatPlanRunner.run(
            plan,
            query: query,
            authorizedBundleIds: authorizedSet,
            conversationScope: combinedScope,
            routeRunner: { route, stepQuery in
                executedStepQueries.append((route.bundleId, stepQuery))
                if route.bundleId == finderBundle {
                    return (true, "Summary: Q3 revenue up 18%.", false)
                }
                return (true, "Sent iMessage to Alex: Summary: Q3 revenue up 18%.", false)
            })

        #expect(results.count == 2)
        #expect(results[0].success == true)
        #expect(results[1].success == true)
        #expect(executedStepQueries.map { $0.bundleId } == [finderBundle, messagesBundle])
        // Step 2 receives Step 1's output in its carried dependency closure:
        #expect(executedStepQueries[1].query.contains("Summary: Q3 revenue up 18%."))

        // Single receipt stream (human receipt + structured DoraXActionReceipt stream + single console scope):
        let textReceipt = ChatPlanRunner.receipt(plan, results: results)
        #expect(textReceipt.contains("1. Read and summarize the selected file in Finder"))
        #expect(textReceipt.contains("2. Send the summary to Alex in Messages"))

        let actionReceipts = ChatPlanRunner.actionReceipts(from: results)
        #expect(actionReceipts.count >= 2)
        #expect(actionReceipts[0].command.contains("Finder: Read Selected File"))
        #expect(actionReceipts[0].output == "Summary: Q3 revenue up 18%.")
        #expect(actionReceipts.contains(where: {
            $0.command.contains("Messages: Send Message to Alex") && $0.success
        }))

        let consoleEntries = ChatConsoleLog.shared.entries(for: combinedScope)
        #expect(consoleEntries.count == 2)
    }

    @Test("Corner App Chat intercepts cross-app action, previews '+ Messages', and promotes in-place to Combined Chat with granted apps")
    @MainActor
    func cornerAppChatCrossAppAccessGatingAndPromotion() {
        let finderBundle = "com.apple.finder"
        let messagesBundle = "com.apple.MobileSMS"
        let finderScope = GeneralChatScope.app(bundleId: finderBundle)

        // Set up clean AppChatConversation state
        let conversation = AppChatConversation.shared
        conversation.messages = []
        conversation.participantSet = .empty
        conversation.syncScope(bundleId: finderBundle, appName: "Finder")
        #expect(conversation.conversationKind == .appPet(.app(bundleID: finderBundle)))
        #expect(conversation.extraConnectedAppNames.isEmpty)

        // User asks in Finder App Chat to send a PDF via iMessage
        let crossAppQuery = "send this via i message to gokulakannan J"
        let request = AppScopedChatService.appNeedingAccess(
            query: crossAppQuery,
            scope: finderScope,
            attachedAppNames: conversation.extraConnectedAppNames)

        #expect(request != nil)
        #expect(request?.name == "Messages")
        #expect(request?.bundleId == messagesBundle)
        #expect(request?.previewChips == ["+ Messages"])
        #expect(request?.actionButtonTitle(for: conversation.conversationKind) == "Connect Messages to this chat")

        // In Corner App Chat, header identity reflects the pending preview chip:
        conversation.pendingParticipantRequest = request
        let previewHeader = conversation.headerIdentity(fallbackAppName: "Finder")
        #expect(previewHeader.primaryTitle == "Finder")
        #expect(previewHeader.previewChips == ["+ Messages"])

        // When user accepts and connects Messages, promotion occurs in-place:
        let promoted = GeneralChatSessionStore.promoteToCombinedChat(
            from: finderScope,
            connecting: request!.participants,
            currentParticipants: conversation.participantSet,
            messages: conversation.messages)
        conversation.participantSet = promoted.participants
        conversation.pendingParticipantRequest = nil

        #expect(conversation.conversationKind == .combined)
        #expect(conversation.extraConnectedAppNames == ["Messages"])
        #expect(conversation.grantedAppsMap["messages"] == messagesBundle)
        #expect(conversation.grantedAppsMap["finder"] == finderBundle)

        let combinedHeader = conversation.headerIdentity(fallbackAppName: "Finder")
        #expect(combinedHeader.kind == .combined)
        #expect(combinedHeader.primaryTitle == "Finder + Messages")
        #expect(combinedHeader.previewChips.isEmpty)

        // Follow-up query in Combined Chat does not trigger another access gate:
        let followUpRequest = AppScopedChatService.appNeedingAccess(
            query: crossAppQuery,
            scope: finderScope,
            attachedAppNames: conversation.extraConnectedAppNames)
        #expect(followUpRequest == nil)

        // Cleanup
        GeneralChatSessionStore.purge(scope: finderScope)
        GeneralChatSessionStore.purge(scope: promoted.scope)
    }
}
