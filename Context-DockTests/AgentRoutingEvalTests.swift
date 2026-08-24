import Foundation
import Testing

@testable import Context_Dock

// Evals for the deterministic layers of a chat turn.
//
// Everything in this file runs without a network, an API key, or a provider. That is the
// point: the parts of an agent turn that decide *what may be reached* and *what gets asked*
// are ordinary functions, and they are where the damaging regressions happen — a scope that
// stops filtering, a question read as a command, a conversation trimmed to nothing.
//
// The behaviours asserted here were each a real bug. A prompt or a ranking rule is tuned by
// feel, and a change made on feel is exactly what quietly undoes an earlier fix; these say
// out loud what the earlier fixes promised.

// MARK: - Capability scoping

@MainActor
struct CapabilityScopeEvalTests {

    @Test func builtInCapabilitySentAsMCPUsesCapabilityExecutor() {
        // Reported by General Chat as run_mcp_tool(browser.currentPage). `builtin` is a
        // capability namespace, not an MCP server, so the call must retain local page data.
        let capabilityID = AgentToolRegistry.bridgedBuiltInCapabilityID(
            toolName: "run_mcp_tool",
            arguments: [
                "app": "builtin",
                "server": "builtin",
                "tool": "browser.currentPage",
                "arguments": [String: Any](),
            ],
            registeredCapabilityIDs: ["browser.currentPage"])
        #expect(capabilityID == "browser.currentPage")
    }

    @Test func realMCPToolsAreNotRewrittenAsCapabilities() {
        let capabilityID = AgentToolRegistry.bridgedBuiltInCapabilityID(
            toolName: "run_mcp_tool",
            arguments: ["server": "linear", "tool": "browser.currentPage"],
            registeredCapabilityIDs: ["browser.currentPage"])
        #expect(capabilityID == nil)
    }

    private func capability(id: String, owner: String?) -> AICapability {
        AICapability(
            id: id,
            title: id,
            appBundleID: owner,
            inputSchema: .init(fields: []),
            riskLevel: .low,
            executor: { _ in .init(success: true, output: "") }
        )
    }

    @Test func aScopedChatKeepsOnlyItsOwnAppsCapabilities() {
        // Reported from a Code conversation that was offered mail.recent, messages.recent and
        // photos.recent, and spent its tool rounds on them.
        let catalogue = [
            capability(id: "code.build", owner: "com.microsoft.VSCode"),
            capability(id: "mail.recent", owner: "com.apple.mail"),
            capability(id: "messages.recent", owner: "com.apple.MobileSMS"),
            capability(id: "photos.recent", owner: "com.apple.Photos"),
        ]
        let kept = AgentToolRegistry.capabilitiesInScope(
            catalogue, scopedBundleID: "com.microsoft.VSCode"
        ).map(\.id)
        #expect(kept == ["code.build"])
    }

    @Test func capabilitiesBelongingToNoAppSurviveScoping() {
        // git, files, finder and the clipboard are the machine, not another app. A question
        // about a repository in a Code thread is answered with git.log, and scoping that out
        // would break the very case the scoping was introduced for.
        let catalogue = [
            capability(id: "git.log", owner: nil),
            capability(id: "files.search", owner: ""),
            capability(id: "finder.recentByKind", owner: nil),
            capability(id: "notes.search", owner: "com.apple.Notes"),
        ]
        let kept = AgentToolRegistry.capabilitiesInScope(
            catalogue, scopedBundleID: "com.microsoft.VSCode"
        ).map(\.id)
        #expect(kept == ["git.log", "files.search", "finder.recentByKind"])
    }

    @Test func anUnscopedConversationSeesEverything() {
        // General Chat's whole job is reaching across apps; narrowing it here would be the
        // same bug pointed the other way.
        let catalogue = [
            capability(id: "mail.recent", owner: "com.apple.mail"),
            capability(id: "git.log", owner: nil),
        ]
        #expect(
            AgentToolRegistry.capabilitiesInScope(catalogue, scopedBundleID: nil).count == 2)
    }

    @Test func scopeIsCaseInsensitiveAcrossBundleIdentifiers() {
        // Bundle ids arrive from the running app, the installed catalogue and stored config,
        // and those three do not always agree on case.
        let catalogue = [capability(id: "code.build", owner: "com.microsoft.VSCode")]
        let kept = AgentToolRegistry.capabilitiesInScope(
            catalogue, scopedBundleID: "com.microsoft.vscode")
        #expect(kept.count == 1)
    }

    @Test func aFolderThreadIsScopedToFinder() {
        // A folder conversation is Finder's work aimed at one directory: the file
        // capabilities are registered against Finder, and nothing else belongs there.
        #expect(
            AgentToolRegistry.scopedBundleID(for: .folder(path: "/tmp"))
                == ChatAppDirectory.finderBundleID)
    }

    @Test func generalAndCLIThreadsAreNotAppScoped() {
        #expect(AgentToolRegistry.scopedBundleID(for: .general) == nil)
        #expect(AgentToolRegistry.scopedBundleID(for: .cli(command: "tailscale")) == nil)
        #expect(AgentToolRegistry.scopedBundleID(for: nil) == nil)
    }
}

// MARK: - Conversation history

struct ChatHistoryBudgetEvalTests {

    private func turns(_ count: Int, characters: Int = 20) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: String(repeating: "x", count: characters) + " #\(index)")
        }
    }

    @Test func aShortConversationIsSentWhole() {
        let history = turns(6)
        let fitted = ChatHistoryBudget.fit(history, provider: .anthropic)
        #expect(fitted.count == history.count)
        #expect(fitted.last?.content == history.last?.content)
    }

    @Test func anOversizedConversationIsTrimmedFromTheOldestEnd() {
        // Ten turns of "yes" costs nothing; ten carrying pasted stack traces is the whole
        // window on a local model.
        let history = turns(40, characters: 500)
        let fitted = ChatHistoryBudget.fit(history, provider: .anthropic)
        #expect(fitted.count < history.count)
        #expect(fitted.last?.content == history.last?.content, "the newest turn must survive")
    }

    @Test func trimmingSaysThatItTrimmed() {
        // A thread that quietly forgets its own beginning invites a confident wrong answer:
        // the model cannot ask about what it was never told is missing.
        let fitted = ChatHistoryBudget.fit(turns(40, characters: 500), provider: .anthropic)
        #expect(fitted.first?.content.contains("earlier message") == true)
    }

    @Test func theNewestTurnSurvivesEvenWhenItAloneExceedsTheBudget() {
        // Dropping the thing the user just said answers a different question.
        let huge = ChatMessage(role: .user, content: String(repeating: "x", count: 500_000))
        let fitted = ChatHistoryBudget.fit([huge], provider: .onDevice)
        #expect(fitted.count == 1)
    }

    @Test func aLocalModelGetsLessHistoryThanACloudModel() {
        let history = turns(40, characters: 400)
        let local = ChatHistoryBudget.fit(history, provider: .onDevice).count
        let cloud = ChatHistoryBudget.fit(history, provider: .anthropic).count
        #expect(local < cloud)
    }

    @Test func systemMessagesAreNotSentAsConversation() {
        let history = [
            ChatMessage(role: .system, content: "internal"),
            ChatMessage(role: .user, content: "hello"),
        ]
        let fitted = ChatHistoryBudget.fit(history, provider: .anthropic)
        #expect(fitted.allSatisfy { $0.role != .system })
        #expect(fitted.count == 1)
    }
}

@MainActor
struct CompletedAgentStepsViewTests {
    @Test func toolCallsAreFoldedIntoOneDeduplicatedStepsList() {
        let lines = AIChatMessageView.completedStepLines(
            trace: ["Reading current Safari page", "run_capability(browser.currentPage)"],
            toolCalls: [
                "run_capability(browser.currentPage)",
                "find_capability(current browser page)",
            ])
        #expect(lines == [
            "Reading current Safari page",
            "run_capability(browser.currentPage)",
            "find_capability(current browser page)",
        ])
    }
}

// MARK: - Question or command

@MainActor
struct ChatRouteResolverEvalTests {

    @Test(arguments: [
        "what page am I on",
        "which branch is this",
        "show me recent files i viewed",
        "list my open tabs",
        "do I have any reminders today?",
        "how do I export this",
    ])
    func questionsAreNotTreatedAsCommands(_ query: String) {
        // "show me recent files i viewed" once ran Preview's "Show Inspector", unattended,
        // answering nothing — a menu item matched on the word "show".
        #expect(!ChatRouteResolver.isActionRequest(query))
    }

    @Test(arguments: [
        "open the downloads folder",
        "delete that file",
        "quit safari",
        "create a new folder here",
        "minimize this window",
    ])
    func commandsAreTreatedAsCommands(_ query: String) {
        #expect(ChatRouteResolver.isActionRequest(query))
    }
}

// MARK: - Effort

struct TaskComplexityEvalTests {

    @Test func aPlainQuestionDoesNotBuyNineToolRounds() {
        // Asserted as "less than the extended budget" rather than a fixed number: the floor
        // was deliberately raised from two to four so a question has room to read something
        // before answering, and pinning the exact figure made that improvement look like a
        // regression. What matters is that a plain question does not get an agent's budget.
        let route = TaskComplexityRouter.route("what is a monad")
        #expect(route == .direct)
        #expect(route.maxToolIterations < TaskComplexityRoute.extended.maxToolIterations)
    }

    @Test func aChainedRequestGetsRoomToFinish() {
        // Cut off at five rounds, a chained request reports half a job as a finished one.
        let route = TaskComplexityRouter.route(
            "find the newest export then open it and tell me the size")
        #expect(route == .extended)
        #expect(route.maxToolIterations > TaskComplexityRoute.bounded.maxToolIterations)
    }

    @Test func askingForCurrentStateEarnsTools() {
        #expect(TaskComplexityRouter.route("what is the current branch") == .bounded)
    }

    @Test func askingAboutTheOpenBrowserPageHasRoomToReadAndAnswer() {
        let route = TaskComplexityRouter.route(
            "What page is open? Give me its exact title, domain, and a short summary.")
        #expect(route == .bounded)
        #expect(route.maxToolIterations >= 6)
    }
}

struct AgentSourceAuthorityEvalTests {
    @Test @MainActor
    func anActionDoesNotTreatUnrelatedMemoryAsAuthority() {
        let decision = AgentSourceAuthority.decide(
            query: "Create a reminder named DoraX Agent Eval for tomorrow")
        #expect(decision.primary == .action)
        #expect(!decision.allowsMemoryEvidence)
    }

    @Test @MainActor
    func anOpenPageQuestionRequiresLiveBrowserEvidence() {
        let decision = AgentSourceAuthority.decide(
            query: "What page is open? Give me its exact title and domain.")
        #expect(decision.primary == .liveState)
        #expect(decision.requiresFreshRead)
        #expect(!decision.allowsMemoryEvidence)
    }
}

// MARK: - Provider budgets

struct ProviderBudgetEvalTests {

    @Test func everyProviderGetsABudgetLargeEnoughForAToolCall() {
        // A tool_use block cut in half is not a malformed call the loop can report — it is a
        // turn that ends having done nothing while claiming to be finished.
        for provider in AIProvider.allCases {
            #expect(AIContextBudget.characterBudget(for: provider) >= 1_000)
            #expect(ChatHistoryBudget.characterBudget(for: provider) >= 1_000)
        }
    }

    @Test func theLocalModelIsGivenTheSmallestContext() {
        let onDevice = AIContextBudget.characterBudget(for: .onDevice)
        for provider in AIProvider.allCases where provider != .onDevice {
            #expect(onDevice <= AIContextBudget.characterBudget(for: provider))
        }
    }
}

// MARK: - Retry

struct ProviderRetryEvalTests {

    @Test func aBusyProviderIsAskedAgain() {
        #expect(AIProviderRetry.delay(forStatus: 429, headers: [:], attempt: 1) != nil)
        #expect(AIProviderRetry.delay(forStatus: 503, headers: [:], attempt: 1) != nil)
    }

    @Test func aRefusalIsFinal() {
        // 4xx other than 429 means the request is wrong and will be wrong again; retrying
        // only spends the user's quota twice.
        #expect(AIProviderRetry.delay(forStatus: 400, headers: [:], attempt: 1) == nil)
        #expect(AIProviderRetry.delay(forStatus: 404, headers: [:], attempt: 1) == nil)
    }

    @Test func retryingStopsAtTheAttemptLimit() {
        #expect(
            AIProviderRetry.delay(
                forStatus: 429, headers: [:], attempt: AIProviderRetry.maxAttempts) == nil)
    }

    @Test func theProvidersOwnRetryAfterIsPreferredOverGuessing() {
        let delay = AIProviderRetry.delay(
            forStatus: 429, headers: ["Retry-After": "7"], attempt: 1)
        #expect(delay == 7)
    }

    @Test func aRetryAfterIsCappedSoAChatDoesNotHang() {
        // Being told to wait ten minutes is not a reason to hold a chat window open for ten
        // minutes.
        let delay = AIProviderRetry.delay(
            forStatus: 429, headers: ["retry-after": "600"], attempt: 1)
        #expect(delay ?? 0 <= 30)
    }

    @Test func aCancelledRequestIsNeverRetried() {
        // Cancellation is the user's decision; repeating the request behind their back is
        // the app overruling them.
        let cancelled = URLError(.cancelled)
        #expect(AIProviderRetry.delay(forTransport: cancelled, attempt: 1) == nil)
    }

    @Test func aDroppedConnectionIsRetried() {
        #expect(AIProviderRetry.delay(forTransport: URLError(.timedOut), attempt: 1) != nil)
        #expect(
            AIProviderRetry.delay(forTransport: URLError(.networkConnectionLost), attempt: 1)
                != nil)
    }
}

// MARK: - Gemini model

struct GeminiModelCatalogEvalTests {

    @Test func aPathQualifiedModelNameIsAccepted() {
        // The models list returns "models/gemini-2.5-pro"; the generate endpoint wants the
        // bare id, and pasting one into the other produced a 404 with no explanation.
        #expect(GeminiModelCatalog.normalized("models/gemini-2.5-pro") == "gemini-2.5-pro")
    }

    @Test func anEmptySelectionFallsBackRatherThanBuildingABrokenURL() {
        #expect(GeminiModelCatalog.normalized("  ") == GeminiModelCatalog.defaultModelID)
    }

    @Test func theEndpointCarriesTheChosenModel() {
        let endpoint = GeminiModelCatalog.generateContentEndpoint(model: "gemini-2.5-flash")
        #expect(endpoint.contains("gemini-2.5-flash:generateContent"))
    }
}

// MARK: - Turn dedupe

@MainActor
struct AgentTurnEvalTests {

    @Test func twoConversationsDoNotShareOneTurnsRecord() {
        // The registry is a singleton and the surfaces are not: the dock starting a turn used
        // to wipe the window's record mid-loop.
        let first = AgentToolRegistry.shared.beginTurn()
        let second = AgentToolRegistry.shared.beginTurn()
        #expect(first != second)
        AgentToolRegistry.shared.endTurn(first)
        AgentToolRegistry.shared.endTurn(second)
    }
}

@MainActor
struct ScreenDrivingPlanEvalTests {
    private let historyRoute = ChatRoute(
        id: "menu:History > Video", kind: .menuCommand,
        title: "History > Video", payload: "History\u{1}Video",
        appName: "Tutorini Player", bundleId: "app.tutorini.Tutorini",
        isReadOnly: false)

    @Test func historyPlaybackRequiresExecutionApproval() {
        #expect(ChatRouteResolver.executionApproval(for: historyRoute) == .ask)
        #expect(historyRoute.asCandidate()?.caveat?.contains("launch or activate") == true)
        #expect(historyRoute.asCandidate()?.caveat?.contains("verify") == true)
    }

    @Test func nowPlayingReadBackVerifiesHistoryPlayback() {
        let before = MenuOutcomeVerifier.Snapshot(
            bundleID: "app.tutorini.Tutorini", isRunning: false, windowTitles: [],
            nowPlayingTitle: nil, playbackState: "stopped", playbackBundleID: nil)
        let after = MenuOutcomeVerifier.Snapshot(
            bundleID: "app.tutorini.Tutorini", isRunning: true,
            windowTitles: ["Tutorini Player"],
            nowPlayingTitle: "How to Build an AI Email Agent", playbackState: "playing",
            playbackBundleID: "app.tutorini.Tutorini")

        let outcome = MenuOutcomeVerifier.compare(
            before: before, after: after, appName: "Tutorini Player",
            path: ["History", "How to Build an AI Email Agent"])
        #expect(outcome?.verified == true)
        #expect(outcome?.message.contains("is playing") == true)
    }
}
