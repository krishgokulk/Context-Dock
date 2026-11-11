# 00 — Now: the work order and the owner's decisions

> **Why this file exists:** long chat sessions get compacted and forget. Anything decided or
> queued in a chat is written here the same day, so no session — cloud, Mac, Remote Control, the
> 11:00 daily brief — depends on remembering a conversation.
> **Rules:** one task is *In progress* at a time (finish it before the next — `AGENTS.md`).
> When a task merges, move it to *Done* with its PR number and promote the next one. Decisions are
> append-only: never edit an old one, add a new dated line that replaces it.
> GitHub Issues (milestone `1.0`) remain the long backlog; this file is the next few steps.

## In progress

None. (Awaiting owner selection for next task)

## Queued (next)

- **Agent harness model** (spec `docs/superpowers/specs/2026-11-09-agent-harness-model.md`, reasoning contract `docs/architecture/AGENT_REASONING_CONTRACT.md`, evals `docs/engineering/MAC_AGENT_BENCHMARKS.md`; owner-confirmed 2026-11-09): **#406** H1a learned recipes from AI scripts + recorder safety → **#407** H1b solved skills for menu/connector/MCP calls → **#408** H1c save/undo line + "Made by DoraX" in Settings → **#409** H2 job key, conflicts, staleness → **#410** H3 selection-type scope → **#411** H4 menus tightened (after #204) → **#412** H5 solved skills on-device (after E5) → **#413** H6 tool core trim.
- Issue #204: P10: Remaining pre-model shortcuts in `DockCore+AIChat.swift` (PR #404 Messages rebase, then App Find, one per PR)
- **#152 E5a → #153 E5b** On-device history & token budget (after owner answers E5 escalation question) → **#397** Foundation Models native image input (replace OCR fallback in `OnDeviceToolBridge` with direct multimodal — after #152/#153)
- Labs (E10–E16 model policy, parallel reads, hybrid retrieval, knowledge graph; **#398** App Intents / Siri AI: expose Dock actions `OpenAppPet`, `SwitchScope`, `SummariseContext` — post-1.0, macOS 27.3+)

## Done (most recent first)

**#405: Task H0 — General slot deriver for Agent Harness Model:**
- Completed on branch `claude/issue-405-agent-harness-deriver-961df4` (PR #426, commit `fa28deaf`).
- Implemented §8 rule 3 of `docs/superpowers/specs/2026-11-09-agent-harness-model.md`:
  - Added `SlotDerivationContext` carrying `selectedText`, `selectedFilePaths`, `appName`.
  - Context slots derived first: `{file}` (single-file ref words "this"/"it" + file basename), `{files}` (multi-file "these"/"them"), `{selection}` (text, when no file slot), `{app}` (app name word).
  - Word slots second: `{day}` everywhere; `{sender}` scoped to Mail/Messages only (`com.apple.mail`, `com.apple.MobileSMS`), preventing product names in Finder from being treated as senders ("convert this to Word" ≠ `{sender}`).
  - Leftover-value check: flags path literals, email addresses, and non-leading proper nouns not covered by slots or route words to prevent hardcoding literals.
  - `SolvedSkillMatch.match`: accepts turn context and forwards to `derive`.
- Added 15 unit tests in `SlotDeriverH0Tests` covering all H0 derivation and leftover rules (3,369 total passing tests).
- Squash-merged into `general-chat-agent`.

**#204 (part): Retire the Mailbox Search pre-model shortcut into the ladder — PR #425, merged:**
- Branch `claude/issue-204-retire-mailbox-search-f9190a` (PR #425, commit `99fe36cd`).

**Issue #204: P10: Retire the Messages pre-model shortcut into the ladder:**
- Branch `claude/issue-204-retire-messages` (Issue #204).
- EGM specification: `docs/superpowers/specs/2026-11-09-issue-204-retire-messages-shortcut.md` (Approved, 0 blocking gaps).
- Retired pre-model `messagesScopedSemanticIntent` (`DockShortcut.messages`), `CrossAppNLHandler.parseMessagesScopedIntent`, and `makeMessagesSemanticIntentPill` from `DockCore+AIChat.swift`, `DockCore+ContextualActions.swift`, `CrossAppNLHandler.swift`, and `DockShortcut.swift`.
- Added `DockCore.shouldSkipCrossAppMessagesRouting` so `CrossAppNLHandler` does not hijack in-scope Messages compose/send turns without a cross-app selection payload.
- Extended `AgentSourceAuthority.decide`, `ReadOnlyDataRouter.domain(for:)`, `FrontmostAppTaskPlan`, `ChatRouteResolver.isActionRequest`, `GeneralAIActionResolver`, and `AppAdapterCapabilityCatalog.messagesCandidate` so Messages questions, searches, and gated compose/send requests route through the shared ladder (`ScopedRoutePolicy` + `CapabilityIndex` + `AppleMessagesMCPCapabilities`).
- Added Messages chat phrasebook rows and `MessagesShortcutRetirementTests` in `Context-DockTests/RoutingPhrasebookTests.swift`; updated `DockShortcutTests.swift` and `00-DOCK-PARITY-INVENTORY.md` (row D19).

**#423: Wire bounded proactive Pet behavior into the app (Finder arrival briefing):**
- Completed on branch `claude/app-pets-bounded-proactive-60b69f` (PR #423, commit `1f8d9e6a`).
- Added `AppPetArrivalBriefing`: reads newly added files in `~/Downloads` (last 24 hours) upon Finder arrival.
- Added per-app switch under Settings › Apps › Finder › Agent (off by default).
- Added `Mute for a day` (24h cooldown) and `Dismiss` actions on the prompt strip suggestion row and detached Pet bubble context menu.
- Added daily headless monitoring scan budget (24 scans, 5s limit, backoff after 3 consecutive no-progress scans).
- Added 7 deterministic unit tests in `AppPetArrivalBriefingTests` (3,326 total tests passing).
- Verified live on macOS with visual screenshot in `docs/screenshots/issue-343-bounded-proactive/settings_window.png`.
- Squash-merged into `general-chat-agent`.

**#424: Clean up stale #333 queue entry:**
- Completed on branch `claude/issue-333-ui-ux-queue-61d8f9` (PR #424, commit `4bfb517a`).
- Closed stale queue entry in `00-NOW.md` for Issue #333 (Side Thread), which had landed in PR #376 (`3c29998c`).
- Squash-merged into `general-chat-agent`.

**#422: Provider / context usage chip (meter per turn):**
- Completed on branch `claude/issue-335-context-chip` (PR #422, commit `287bc7a5`).
- Added `ProviderContextUsageStore` tracking per-scope turn context occupancy against `ProviderContextBudget.maxContextTokens`.
- Replaced rather than summed prompt tokens across multi-round tool loops to prevent artificial context inflation. Resets on turn start and scope changes.
- Added compact, shared-shell `ProviderContextChip` displaying provider icon, compact model name, miniature meter track, and context percentage (`—%` when unknown), with a popup menu to switch the active provider.
- Integrated into `AppChatPromptPill`, `CornerGeneralChatView`, `AppChatListCard`, and `CornerLivePanel`.
- Added 7 offline unit tests in `Context-DockTests/ProviderContextUsageChipTests.swift`.
- Visual verification and screenshots saved in `docs/screenshots/issue-335-context-chip/`.
- Squash-merged into `general-chat-agent`.

**#421: Unify General Chat into Siri-style seamless liquid-glass UI:**
- Completed on branch `fix/general-chat-siri-ui` (PR #421).
- Unified board transcript and composer into one continuous liquid-glass container (`cornerRadius: 26`) with a specular gradient rim border.
- Fixed centred results layout bug: expanded transcript to full width (`maxWidth: .infinity`) when live panel is closed.
- Refactored corner composer to Siri 3-piece layout: frosted circular `+` button on left, recessed capsule input in center, and circular action/send button on right.
- De-cluttered message bubbles: hid repeating per-message toolbars (`[Side thread] [Summary | Normal | Verbose]`) behind hover (`.onHover`).
- Removed middle vertical scrollbar via `.scrollIndicators(.never)` and added `.defaultScrollAnchor(.bottom)` with smooth animated scroll transitions.
- Squash-merged into `general-chat-agent`.

**#420: Fix the red test suite on general-chat-agent (33 failures to 3):**
- Completed on branch `claude/fix-red-test-suite` (PR #420, commit `e5704315`).
- Fixed 33 test failures and test host crashes across CornerSafariTabsTests, CornerAppPinsTests, CornerBoardLayoutTests, AppScopeCardTests, CornerDockPhaseTests, CornerGeneralChatTests, DockKeyRulesTests, and DockShellWidthTests.
- Restored intent + lane rule in `FrontmostAppTaskPlan.swift` for read-only questions.
- Squash-merged into `general-chat-agent`.

**#417: Fit header pin icon and composer in compact app pet chat:**
- Completed on branch `fix/app-pet-header-pin-and-composer-fit` (PR #417, commit `cb6ac5db`).
- Fixed composer input field width and trailing padding inside 18pt rounded corner pill.
- Prevented `appChip` title from collapsing to 0 width with `.layoutPriority(1)` and `.fixedSize(horizontal: true, vertical: false)`.
- Synchronized transcript and live panel widths via dynamic `transcriptColumnWidth` and `shellWidth`.
- Pinned header action buttons strip to 23x23 glyphs and 2pt spacing, keeping the Pin icon fully visible.
- Prevented detail mode picker pills ("Summary", "Normal", "Verbose") from wrapping into multiple lines.
- Squash-merged into `general-chat-agent`.

**#204 (part): Retire the Mailbox Search pre-model shortcut into the ladder — draft PR #425, hand check owed:**
- Branch `claude/issue-204-retire-mailbox-search-f9190a` (draft PR #425, base `general-chat-agent`).
- EGM specification: `docs/superpowers/specs/2026-11-10-issue-204-retire-mailbox-search-shortcut.md`.
- Deleted the `shouldExecuteMailMailboxSearch` block (`DockShortcut.mailboxSearch`) from `handleL2Query`, the `MailboxSearchCommand` parser and `mailSearchDisplayLabel`. "search mail from SBI" now reaches the model as a data-lane Mail read (`mail.search` / `search_mail`).
- Two shared rules: `ScopedRecordRead.lookupVerbs` ("look for" / "look up" / "lookup" are record reads in every record-set app) and `CrossAppNLHandler.searchesScopedApp` (a search of the app the chat is scoped to is not cross-app).
- Follow-up after the hand check: a provider without tools answered "a full Mail search wasn't readable". Mail searches are now prefetched into the prompt (`AppleLiveDataContext.mailSearchIntent`), a bare `query` matches sender or subject, a whole sentence in `query` is parsed, and glue words such as "from" no longer match a route (`ChatRouteResolver.glueWords`). Tests: `MailSearchGroundingTests`.
- Still open under #204: App Find claims the first find/search sentence of a not-yet-active chat (next retirement PR). PR #404 (Messages) touches neighbouring lines; whichever merges second rebases.

**#204 (part): Retire the Mail Question pre-model shortcut into the ladder — PR #403, merged:**
- Branch `claude/issue-204-retire-mail-question` (PR #403, merged into `general-chat-agent` as `3595f89`).
- EGM specification: `docs/superpowers/specs/2026-11-08-issue-204-retire-mail-question-shortcut.md` (Approved, 0 blocking gaps).
- Retired pre-model `answerAttachedMailQuestion` (`DockShortcut.mailQuestion`) and orphaned `MailQuestionRouter.needsAttachedMailContext` / `isMailContextAttached` gate from `DockCore+AIChat.swift` (`handleL2Query`), `DockCore+MailFindActions.swift`, `DockCore+FinderAttachment.swift`, and `DockCore.swift`.
- Replaced `MailQuestionRouter.needsAttachedMailContext` with `MailQuestionRouter.isMailboxQuestion`, wired into `AgentSourceAuthority.decide` for `com.apple.mail` scope alongside `"yesterday"` / `"did i"` freshness signals, and added `AppleLiveDataContext.wantsMailContext`.
- Added Mail chat phrasebook rows and `MailQuestionShortcutRetirementTests` in `Context-DockTests/RoutingPhrasebookTests.swift`; updated `MailQuestionRouterTests.swift`, `DockShortcutTests.swift`, and `00-DOCK-PARITY-INVENTORY.md` (row D18).
- Gate `./scripts/check.sh` and targeted test suites (`RoutingPhrasebookTests`, `MailQuestionShortcutRetirementTests`, `MailQuestionRouterTests`, `DockShortcutTests`, `MailboxSearchCommandTests` — 37/37 pass) green. (`MailboxSearchCommandTests` was later removed with the shortcut, PR #425.)

**#204 (part): Retire the Menu Command pre-model shortcut into the ladder — PR #402, merged:**
- Branch `claude/issue-204-retire-menu-command` (PR #402, merged into `general-chat-agent` as `4b98162`).
- EGM specification: `docs/superpowers/specs/2026-11-08-issue-204-retire-menu-command-shortcut.md` (Approved, 0 blocking gaps).
- Retired pre-model `MenuIntentRouter` (`DockShortcut.menuCommand`) block from `DockCore+AIChat.swift` (`handleL2Query`) and removed `skipMenuRouter: Bool` recursion parameter.
- Deleted dead `AIMenuProposal` / `pendingAIMenuProposal` / `pendingAIProposal` pill-sheet state across `DockModels.swift`, `FeatureViewModels.swift`, `DockCore+StateBridges.swift`, and `DockCore+ContextualActions.swift`.
- Removed `MenuIntentRouter` class from `MenuIntentRouter.swift` while preserving `MenuPick` and `MenuPickRule`.
- Added phrasebook rows and `MenuCommandShortcutRetirementTests` in `Context-DockTests/RoutingPhrasebookTests.swift`; updated `DockShortcutTests.swift` and `00-DOCK-PARITY-INVENTORY.md` (row D17).
- Gate `./scripts/check.sh` and targeted test suites (`RoutingPhrasebookTests`, `MenuCommandShortcutRetirementTests`, `DockShortcutTests`, `MenuPickRuleTests` — 39/39 pass) green.

**#77: Corner tests with no synthetic window or dock dependency:**
- Completed on branch `claude/issue-77-test-host-corner-decoupling` (PR #401, Issue #77).
- EGM specification: `docs/superpowers/specs/2026-11-08-issue-77-test-host-corner-decoupling.md` (6 Goldfish audit iterations, approved).
- Partitioned `ILauncherApp.applicationDidFinishLaunching` into test host vs production environment.
- Installed `TestHostMainActorWatchdog`, `AXMessagingTimeout.installProcessDefault()`, and `TestHostAppleEventBlocker` to fast-fail hangs.
- Added headless execution mode to `CornerDockWindow`: separated Combine model subscriptions from NSPanel/HostView allocation; guarded WindowServer refresh and edge watch.
- Injected `FixedRunningAppsSource.defaultTestFixture` (Finder and Safari stubs) to eliminate live AX calls and workspace dependencies under test hosting.
- Quarantined `MenuWarmCacheService` and `AXObserverManager` during test hosting.
- Added `TestHostQuarantineTests` (5/5) and `CornerHeadlessExecutionTests` (5/5).
- 65 tests across Corner suites run fast and deterministic with 0 stalls. Gate `./scripts/check.sh` clean pass. PR #401 merged.

**#257: Convert hidden Dock into headless DockEngine (Final Closure):**
- Completed on branch `claude/issue-257-headless-dock-engine` (PR #399, Issue #257).
- EGM specification: `docs/superpowers/specs/2026-11-08-issue-257-headless-dock-engine.md` (6 Goldfish audit iterations, approved).
- Eliminated residual window-hunting (`NSApp.windows`) in `DockCore+DockAppActions.swift`.
- Migrated `@FocusState var isSearchFieldFocused` to `@Published` on `DockCoreModel` with `nonmutating set` bridge on `DockCore`.
- Refactored vestigial launcher methods to `resetEngineStateAfterResultExecution(force:)`.
- Removed dead launcher-open warming in `MenuWarmCacheService.swift`.
- Added swift-testing unit test suite `Context-DockTests/DockEngineHeadlessTests.swift` (4/4 pass).
- Check gate `./scripts/check.sh` clean pass.

**UI bug: Live sidepanel toggle clipping (PR #400):**
- Fixed message bubbles being clipped/cut when toggling the live sidepanel in App Pet and General Chat.
- Root cause: `transcript.frame(maxWidth: .infinity)` let content expand when the panel exited layout, while the outer `clipShape` was still animating to `compactChatWidth`, clipping the right edge mid-transition.
- Fix: pin transcript to `compactChatWidth` in `AppChatPromptPill.swift` and to `size.width - panelWidth` in `CornerGeneralChatView.swift`.
- PR #400, squash-merged into `general-chat-agent` (2026-11-08).

**#83: Extract SelectionActionSource out of DockCore:**
- Completed on branch `claude/issue-83-selection-action-source` (PR #396, commit `fda8804f`, Issue #83).
- EGM specification: `docs/superpowers/specs/2026-11-08-issue-83-selection-action-source.md` (5 Goldfish audit iterations, approved).
- Extracted standalone `SelectionActionSource` conforming to `SelectionActionProviding`.
- Decoupled host interactions via `SelectionActionHost` and `DefaultSelectionActionHost`.
- Consolidated paste-back into `SelectionPasteback` helper with process termination validation.
- Delegated `DockCore+SelectionActionProviding.swift` and `DockCore+ContextualActions.swift` directly to `SelectionActionSource.shared`.
- Wired `DockEngine` to use `SelectionActionSource.shared`.
- All 50 tests in `Context-DockTests/CornerSelectionActionsTests.swift` pass 100% green. Gate `./scripts/check.sh` clean pass. Squash-merged into `general-chat-agent`.

**#225: Fix two offline tests depending on live Mac state:**
- Completed on branch `claude/issue-225-tests-no-live-state` (PR #395, commit `17f8754f`, Issue #225).
- Injected `AppChatSelectionReading` seam (`FakeAppChatSelectionReader`) and `RunningAppsSourcing` seam (`FixedRunningAppsSource`) into `AppChatPromptModel`.
- Added `showRunningAppsEnabled` test default preventing live developer preferences from overriding test expectations.
- Tests in `Context-DockTests/AppChatPromptTests.swift` and `Context-DockTests/CornerFrontmostAppPillsTests.swift` pass deterministically. Squash-merged into `general-chat-agent`.

**#157: E7b Approvals survive quitting the app:**
- Completed on branch `claude/stoic-khorana-e2d57d` (PR #391, commit `c12e9ad0`, Issue #157).
- Spec: `docs/master/00-AI-ENGINE-PLAN.md` (§4 E7b) and Issue #157.
- Persisted pending approvals across app restarts in `AI/PendingApprovalJournal.swift`:
  - `PendingApprovalRecord` Codable snapshot written to `Application Support/Context-Dock/pending-approvals.json` before approval cards appear.
  - `ApprovalExecutionReceipt`: Idempotency guard written before commands run, keyed by request ID.
  - Restores pending approvals on app restart with `clock.arrow.circlepath` badge; auto-cancels stale records (>10 min).
- Unit tests in `Context-DockTests/PendingApprovalJournalTests.swift` (8 tests passing in isolated test store). Squash-merged into `general-chat-agent`.

**#160: E8c Replay judge for answer quality:**
- Completed on branch `claude/issue-160-replay-judge` (PR #394, Issue #160).
- Offline answer-quality judge: scores a `ReplayCase` final answer using heuristic signals (poor: empty, short, failure prefix, query echo, injection markers; good: no failure, addresses query, complete sentence, appropriate length).
- Added `Services/ReplayCaseJudge.swift` and `Context-DockTests/ReplayCaseJudgeTests.swift` with 20 hand-graded cases (≥90% agreement achieved, 100% on fixture set). Squash-merged into `general-chat-agent`.

**#159: E8b Replay runner: rule checks + retrieval metrics, offline:**
- Completed on branch `claude/issue-159-replay-runner` (PR #393, Issue #159).
- Added `Services/ReplayCaseRule.swift` (9 built-in rules) and `Services/ReplayRunner.swift` (runner, `RunReport`, `RetrievalMetrics` with hit@K and MRR).
- Added `Context-DockTests/ReplayRunnerTests.swift` including 10 prompt-injection benchmark cases. Fixed static member qualifications in `PromptInjectionCaseTests`. Squash-merged into `general-chat-agent`.

**#158: E8a Replay cases: record query, context and tool outputs from real turns:**
- Completed on branch `claude/issue-158-replay-cases` (PR #392, Issue #158).
- Added `Services/ReplayCase.swift` (versioned Codable turn snapshot), `Services/ReplayCaseSanitizer.swift` (stripping personal paths, emails, tokens, keys), `Services/ReplayCaseStore.swift` (disk store under `~/Library/Application Support/Context-Dock/ReplayCases/`).
- Added `Context-DockTests/ReplayCaseTests.swift` (20 offline tests). Squash-merged into `general-chat-agent`.

**#156: E7a Focus: inspect / act / verify / answer each send their own tool set:**
- Completed on branch `claude/issue-156-focus-tool-sets` (PR #390, Issue #156).
- Spec: `docs/master/00-AI-ENGINE-PLAN.md` (§4 E7a) and Issue #156.
- Added `TurnFocus` and `RoundFocusTracker` in `AIToolBudget.swift`: categorized tools into `inspect`, `act`, `verify`, and `answer` sets; dynamically applies tool subsets per round based on previous tool calls.
- Wired focus tracking into generic `runToolLoop` in `AIProviderToolLoops.swift`: dynamic tool subset per round and recorded `dorax.focus`, `dorax.round.focus`, and `dorax.tools.sent` in `TurnRecorder.swift`.
- Added unit tests in `TurnFocusTests.swift` (15/15 pass), verified `ToolLoopAdapterTests` (3/3 pass) and `ToolLoopProgressStopTests` (9/9 pass). Gate `./scripts/check.sh` clean pass. Live hand checked and squash-merged into `general-chat-agent`.

**#155: E6b Tool loop: three loops become one:**
- Completed on branch `claude/issue-155-one-tool-loop` (PR #389, Issue #155).
- Spec: `docs/master/00-AI-ENGINE-PLAN.md` (§4 E6b) and Issue #155.
- Unified three nearly identical async tool loops (`sendOpenAIWithTools`, `sendAnthropicWithTools`, `sendGeminiWithTools`) into a single generic `runToolLoop<A: ToolLoopAdapter>`.
- Added `ToolLoopAdapter.swift` with `ToolLoopAdapter` protocol, normalized types (`NormalizedToolCall`, `ToolRoundUsage`, `ToolRoundOutput`), and three conforming adapters (`OpenAILoopAdapter`, `AnthropicLoopAdapter`, `GeminiLoopAdapter`).
- Preserved all provider-specific behaviors: Anthropic thinking blocks echoed verbatim, prompt cache markers per-round, OpenAI non-stream buffered requests, and Gemini model resolution.
- Public API preserved: existing callers and signatures remain identical thin wrappers.
- Added unit tests in `ToolLoopAdapterTests` (3/3 pass) and verified regressions in `ToolLoopProgressStopTests` (9/9 pass). Gate `./scripts/check.sh` clean pass. Squash-merged into `general-chat-agent`.

**Task: Unified Dynamic Pet Resolution Between Corner and General Chat Window:**
- Completed on branch `fix/general-chat-window-connected-pet-parity` (PR #388).
- Spec: Unified Dock Surface rule (`AGENTS.md`), `docs/architecture/FRONTMOST_AGENT.md`, and Claude Code / Codex sidepanel parity.
- Unified Dynamic Pet Identity on `GeneralChatWindowModel`:
  - Moved `resolvedConnectedPet` onto `GeneralChatWindowModel` to provide a single, shared source of truth for both compact Corner and full window General Chat.
  - Resolves active Pet identity (Finder, connected app, borrowed turn participant, or frontmost App Pet) with icon and bundle ID.
- Parity in `GeneralChatWindowView`:
  - Bound `CornerLivePanel(density: .full)` on the Scope rail to `model.resolvedConnectedPet`, eliminating the empty "Details" fallback and rendering the full 51 tools, skills, and native connectors.
  - Updated `scopePill` to display the connected Pet icon and name (e.g. `[  Finder ]`).
- Verified visually in the running app via AXUIElement scripting and screen capture (`general_chat_scope_verified.png`). Check gate passed. Squash-merged into `general-chat-agent`.

**Task: Sidepanel Connected Pet Identity, Tools & Skills Parity (Claude Code / Codex):**
- Completed on branch `claude/sidepanel-connected-pet-tools-parity` (PR #387).
- Spec: `docs/superpowers/specs/2026-10-27-app-pets-combined-chat-design.md`, `docs/architecture/FRONTMOST_AGENT.md`, and Claude Code / Codex sidepanel parity.
- Dynamic Pet Identity Resolution in Corner General Chat (`CornerGeneralChatView`):
  - Resolved active Pet info (`activePetInfo`: name, bundleID, icon) from conversation participants (`participantSet`), borrowed turn scope (`activeTurnScope`), grounded filesystem context (`FinderContextGrounder.wantsFileGrounding`), or frontmost App Pet (`promptModel`).
  - Passed resolved Pet identity to `CornerLivePanel` so the panel binds to the actual Pet (e.g. Finder, `com.apple.finder`) rather than generic empty "Details".
- Full Tools, Skills & Connectors in `CornerLivePanel`:
  - Included both `canDoGroups` (native tools, capabilities, menu commands) and `knowsGroups` (skills: e.g. "Finder Assistant Basics", "Non-Destructive File Organization").
  - Rendered full tool and skill rows in `.normal` and `.verbose` detail modes matching Claude Code and Codex sidepanel layout.
  - Fixed progress trace row fallback so completed reasoning steps (e.g. `2 steps`) are visible without getting filtered out.
  - Displayed built-in app adapters, environment, and connected MCP servers in Connectors.
- Tests & check gate `./scripts/check.sh` clean pass. Relaunched via `./scripts/dev-run.sh`.

**Task: Inherent Directory Total Size Grounding & General Chat Live Sidepanel Parity:**
- Completed on branch `claude/grounding-folder-size-and-general-sidepanel` (PR #386).
- Spec: `docs/superpowers/specs/2026-10-27-app-pets-combined-chat-design.md`, `docs/architecture/FRONTMOST_AGENT.md`, and user design alignment.
- Directory Total Size Inherent Grounding:
  - In `FinderContextGrounder`: recursively/fast-enumerates target directory to compute `totalSizeBytes` and `formattedTotalSize` (e.g. 2.52 GB across 13,000 files).
  - Injected total size directly into `FinderGroundingOutcome` and `promptBlock` as inherent baseline directory metadata without fragile keyword heuristics.
  - Allows all models (including subscription/tool-free providers) to answer directory size, capacity, and volume inquiries immediately and factually.
- General Chat Live Sidepanel Parity:
  - Added `sidebar.right` toggle button and `trash` clear button to `CornerGeneralChatView` header beside expand/keyboard/pin.
  - Rendered `CornerLivePanel` split view beside `transcript` during active reasoning (`model.isSending`) or when toggled open (`AppChatPromptModel.shared.livePanelOpen`).
  - Streamed live reasoning trace steps (`model.activeProgress` / `model.activeActivity`), files, and connectors to the sidepanel for full parity with App Pet, Claude Code, and Codex.
- Comprehensive unit tests in `FinderContextResolutionTests` (8/8 pass). Gate `./scripts/check.sh` clean pass. Relaunched via `./scripts/dev-run.sh`.

**Task: Autonomous Context Resolution & Windowless Grounding for Finder Pet and General Chat:**
- Completed on branch `claude/finder-autonomous-context-grounding` (PR #384).
- Spec: `docs/superpowers/specs/2026-10-27-app-pets-combined-chat-design.md` (§8), `docs/architecture/FRONTMOST_AGENT.md` (§2a), and approved plan artifact `finder_flow_architecture.md`.
- Cascading 4-tier context resolution for Finder Pet (`selectedFilePaths` -> `namedFolder` -> `openWindow` -> `defaultRoots`).
- Pre-turn passive grounding: Extract query-matching files (e.g. `sharecode` -> `Details to give your employer – GOV.UK.png`) and inject into `ResolvedContext` so tool-free providers (e.g. `chatGPTSubscription`) answer accurately without disclaimers.
- Single-turn scope borrowing in General Chat: Bounded read of target folder/files when queries ask about Mac folders.
- Comprehensive unit tests covering windowless resolution, named folder extraction, and passive grounding (7/7 pass). Gate `./scripts/check.sh` clean pass. Relaunched via `./scripts/dev-run.sh`.

**#154: E6a Tool loop: no-progress stop and backoff (one max_tokens table):**
- Completed on branch `claude/issue-154-loop-progress-stop` (PR #383, Issue #154).
- Spec: `docs/master/00-AI-ENGINE-PLAN.md` (§4 E6a) and Issue #154.
- Stop tool loops that spin: two rounds whose tool results add nothing new (same outputs as earlier rounds, or only failures) stop the loop and answer with what is known.
- Single provider max output tokens table in `ToolLoopBudget`, used by all three tool loops (OpenAI, Anthropic, Gemini).
- Record loop stops in the turn trace with their reason (`dorax.stop_reason`).
- Sidepanel toggle persistence across app launches in `pinStore` (`UserDefaults.cornerLivePanelOpen`).
- Added unit tests in `ToolLoopProgressStopTests` (9/9 pass) and `CornerLivePanelTests` (9/9 pass). Gate `./scripts/check.sh` clean pass. Relaunched via `./scripts/dev-run.sh`.

**#151: E3 Prompt order: stable sections first, a second cache mark, volatile last:**
- Completed on branch `claude/issue-151-prompt-order` (PR #382, Issue #151).
- Spec: `docs/master/00-AI-ENGINE-PLAN.md` (§4 E3) and Issue #151.
- Reordered `ScopedPromptSection` declaration cases in `Context-Dock/AI/ScopedPromptAssembler.swift`: stable sections first (`sourceRule`, `userProfile`, `identity`, `petMode`, `capabilities`, `liveMenu`, `mcp`, `skills`, `reference`, `cli`), followed by volatile sections closest to the user's question (`workspace`, `resolvedContext`, `selection`, `browserPage`, `folder`, `attachments`, `liveAppData`, `memory`).
- Preserved budget drop order unchanged (`dropOrder` and `isEssential`).
- Added dual-block prompt caching in `Context-Dock/AI/AnthropicPromptCache.swift` with `cacheBoundaryMarker` (`<!-- cache:breakpoint -->`): emits stable prefix block (cached across turns) and volatile suffix block, each with ephemeral cache breakpoints, staying within Anthropic's 4-breakpoint limit (at most 2 in system + 1 in history = 3 <= 4).
- Verified that changing user selection leaves the stable prefix 100% byte-identical.
- Added comprehensive unit tests in `Context-DockTests/PromptOrderCacheTests.swift` (5/5 passing) and verified regressions in `ScopedPromptAssemblyEvalTests` (9/9 passing) and `FrontmostAppAgentPhase1Tests` (6/6 passing). Gate `./scripts/check.sh` clean pass. Relaunched via `./scripts/dev-run.sh`.

**Task: Autonomous App Discovery & CLI Linker (Follow-up to #373):**
- Completed on branch `feat/autonomous-app-discovery-cli-linker` (PR #381).
- Spec: `docs/architecture/APP_KNOWLEDGE_SKILLS.md` (§3) and `docs/superpowers/specs/2026-11-05-streamline-settings-and-extensions.md`.
- 1. Multi-Choice `+ Add Capability` Dropdown: Transformed button in `AppIntegrationCapabilitiesView` into a Menu with `🌟 AI Action / Goal`, `💻 Link Installed CLI Tool…` (with support for choosing or entering custom binaries in `AppCLIToolPickerSheet`), and `⚡️ Connect UTCP API…` (opening `IntegrationAPIConnectSheet`).
- 2. PATH Auto-Discovery for Frontmost Apps: Implemented `AutonomousAppDiscoveryEngine` scanning `/opt/homebrew/bin`, `~/.local/bin`, and `/usr/local/bin` to auto-detect matching CLI tools for apps (`agy` for Antigravity, `code` for VS Code, `git` / `gh` for GitHub Desktop, `ghostty`, etc.) and surfaced discovered local tools directly as recommended one-click accelerators (`Link Accelerator`).
- 3. Offline `[ 🌐 Enrich Knowledge ]` Action: Added one-click action to run 2-stage discovery (PATH scanner, `Info.plist` URL deep links, and official docs/README fetched once per app version), updating `<App> — what this app is` in `SkillStore` and `AGENT.md` in `AppAgentProfileStore` while adhering to the Outbound Privacy Gate.
- 4. Verified with unit test suite in `Context-DockTests/AutonomousAppDiscoveryTests.swift` (5/5 passing) and regression tests (`StreamlineSettingsAndExtensionsTests`, `AppKnowledgeSkillTests`). Gate `./scripts/check.sh` passed. Relaunched via `./scripts/dev-run.sh`.

**Task UI/UX 5/5 (#335): Capabilities & Skills Browser:**
- Completed on branch `claude/task-335-skills-browser` (Issue #335).
- Implemented `CapabilitiesSkillsBoardCard` and `CapabilitiesSkillsBrowser` (`Context-Dock/UI/CapabilitiesSkillsBoardCard.swift`) reading directly from `SystemCommandsRegistry`, `CapabilityRegistry`, `AppAdapterManager`, `SkillStore`, and `SolvedSkillStore`.
- Built split two-column board in Corner Dock shell: left column lists capabilities & skills with search query filtering, filter tabs (`All`, `Capabilities`, `Skills`, `Learned`), kind tags, and `Read` / `Write` / `Guidance` safety classifications; right column provides a deep inspection panel with description, trigger keywords, steering instructions, learned tool-call execution sequences, and technical specifications.
- Added direct activation into App Pet or General Chat (`↵ Ask in Pet` / `Use Skill`) and clipboard copy (`doc.on.doc` / `⌘C`).
- Registered built-in `Capabilities & Skills` system command (`provider:skills`), slash commands `/skills` & `/capabilities`, header sparkles button (`sparkles`), and `chat.capabilitiesSkillsBoard` (`⌥K`) in `DockKeyMap` / `KeysOverlay`.
- Verified with unit tests in `Context-DockTests/CapabilitiesSkillsBrowserTests.swift` (5/5 passing) and regression suites (`ConversationsBoardTests`, `KeysOverlayTests`). Clean gate `./scripts/check.sh` passed. Relaunched via `./scripts/dev-run.sh`.

**Task UI/UX 4/5 (#334): Conversations board (browse past conversations):**
- Completed on branch `claude/task-334-conversations-board` (Issue #334).
- Implemented `ConversationsBoardCard` and `ConversationsBoard` (`Context-Dock/UI/ConversationsBoardCard.swift`) reading directly from `GeneralChatSessionStore` without duplicating transcripts or introducing a second store.
- Built split two-column board layout in the Corner Dock shell: left column lists past conversations across scopes (App Pets, CLI, General Chat, Combined Chat) with relative timestamps and message count badges; right column provides a live preview of the real stored messages for the focused thread.
- Added scope filter tabs (`All`, `App Pets`, `General & Combined`) and live search filter within history by title, app name, bundle ID, or message content.
- Wired reopening of conversations into their proper scope views (App Pet, CLI, General Chat, Combined Chat) with full keyboard navigation (arrows, Return to open, ⌘⌫ to clear history, Esc back).
- Registered pre-seeded `Past Conversations` built-in system command (`provider:conversations`), slash commands `/conversations` and `/history`, header history button (`clock.arrow.circlepath`), and `chat.conversationsBoard` (`⌥H`) shortcut in `DockKeyMap` / `KeysOverlay`.
- Verified with unit tests in `Context-DockTests/ConversationsBoardTests.swift` (5 tests passing). Clean gate `./scripts/check.sh` passed. Relaunched via `./scripts/dev-run.sh`.

**Task UI/UX 3/5 (#333): Side Thread (branch a sub-conversation):**
- Completed on branch `claude/task-333-side-thread` (Issue #333).
- Implemented `SideThreadState` and `SideThreadSummarizer` (`Context-Dock/AI/SideThread.swift`) allowing temporary side tangent conversations branched off an active App Pet, Combined Chat, or General Chat turn without polluting the main conversation transcript or Pet memory.
- Implemented `SideThreadChildView` (`Context-Dock/UI/SideThreadChildView.swift`) as a child view within the existing surface shell (Corner Dock, Corner General Chat, and Standalone General Chat window), preserving active scope and grounding.
- Added explicit Fold Back summary action (synthesizing side findings into a single structured summary turn in the main thread) and Discard action (dismissing without modifying main messages).
- Added `Side thread` action button to `AIChatMessageView` assistant turn footers, `/side [query]` slash command support in `AppChatPromptModel` and `GeneralChatWindowModel`, and registered `chat.sideThread` (`⌥S`) in `DockKeyMap` / `KeysOverlay`.
- Verified with unit tests in `Context-DockTests/SideThreadTests.swift` (5 tests passing). Clean gate `./scripts/check.sh` passed. Relaunched via `./scripts/dev-run.sh`.

**Task UI/UX 2/5 (#332): Keys overlay (shortcuts reference):**
- Completed on branch `claude/task-332-keys-overlay` (Issue #332).
- Implemented `DockKeyMap` (`Context-Dock/UI/KeysOverlay.swift`) as the single canonical source of truth for active keyboard shortcuts across 4 surface groups (`Launch & Global`, `Scope & Navigation`, `Global Context & App Pet`, `Chat & Clipboard`), reading live from `AppSettings`, `DockKey`, `DockKeyRules`, `CornerNavigation`, and `ClipboardBoardKey` (plus dynamic `DockKeyMap.register(_:)`).
- Implemented `KeysOverlayCard` over `CornerDockSurface` (`CornerDockWindow.swift`), triggered by `⌘/`, `⌘?` (`⇧⌘/`), bare `?` when the dock is at rest, or the `keyboard` button in board footers (`BoardFooter.pinAndSettings`, `AppChatListCard.footer`) and chat headers (`AppChatPromptPill.header`, `CornerGeneralChatView.header`).
- Dismissing via `⎋` (Esc), `⌘/`, close `✕`, or clicking outside returns to the exact prior surface state without recreating the window or changing dock size/state.
- Updated `HotkeysSettingsPage.swift` so Settings → Hotkeys and the Keys overlay render from the same `DockKeyMap` source of truth.
- Verified with unit tests in `Context-DockTests/KeysOverlayTests.swift` (5 tests). Gate `./scripts/check.sh` clean.

**Task #373: Streamline Settings & Extensions Architecture (Packs, Apps, Store):**
- Completed and merged via PR #374 (`91e18360`).
- Consolidated fragmented sidebar items (`App Packs`, `Integrations`, `Plugins`, `Plugin Creator`) into unified `Extensions` (`Apps` and `Store / Packs`), simplified per-app detail tabs (`Capabilities & Skills`, `Agent (AGENT.md)`, `Access & Permissions`), automatic app binding by `bundleId`, and AI Pack Creator.

**Task UI/UX 1/5 (#331): Live-panel detail modes (Summary / Normal / Verbose):**
- Completed and merged via PR #373 (`909a4937`).
- Implemented per-answer density control in answer views and live panel:
  1. Summary: Headline + core verdict.
  2. Normal: Current standard view.
  3. Verbose: Expanded user-facing steps, receipts, and verified evidence (never leaks raw model/internal tool output, per #316).
- Toggling density updates existing rendered answers dynamically without re-running turns.
- View-level state only; does not change routing, approvals, or engine execution.
- Verified with unit tests in `Context-DockTests/LivePanelDetailModeTests.swift` (12 tests). Gate `./scripts/check.sh` clean. Relaunched via `./scripts/dev-run.sh`.

**Fix: Activate Target App Before Reading and Operating Menus in Computer Use:**
- Completed and merged via PR #372 (`3e6a525`).
- Solved false "greyed out" refusal in App Pet (e.g., TextEdit `export this as pdf`). macOS Cocoa/AppKit validates document menu items (`validateMenuItem:`) lazily on the responder chain only when the target app is frontmost/active. When DoraX was active, TextEdit was in the background with document commands reporting disabled.
- Fix:
  1. In `ComputerUseRunner.run` (`Context-Dock/AI/ComputerUseTool.swift`), activate the target app (`app.activate(options: [.activateIgnoringOtherApps])`) and sleep 120ms before querying menus.
  2. In `AXMenuReader.swift` (`isMenuItemEnabledReliably` and `isMenuItemEnabledViaSystemEvents`), activate the app and set `frontmost to true` in AppleScript before inspecting `enabled of menu item`.
- Verified 17/17 tests passing in `ComputerUseAcceptance3AppTypesTests.swift`. Gate `./scripts/check.sh` clean. Relaunched via `./scripts/dev-run.sh`.

**Task #368 Part 5: Autonomous Computer Use Acceptance Across 3 App Types (Scriptable, Menu-Only, Canvas):**
- Completed and merged via PR #370.
- Spec: `docs/superpowers/specs/2026-11-03-unified-frontmost-app-agent-and-computer-use.md` (§8 Computer Use Perfection Addendum).
- End-to-end verification of observe → act → verify loop across 3 application tiers:
  1. Scriptable App (sdef inspection + synthesized scripting execution with verified read-back and AGENT.md safety rules enforcement).
  2. Menu-Only App (hierarchical menu resolution with `>`, `▸`, `›`, `/`, `|` delimiters, sheet AX snapshotting, loop guard with stall detection and 25-step budget, outbound destructive command forbidden protection).
  3. Canvas App (Vision/OCR fallback target detection with `t`-prefix IDs, global screen point mapping with top-left origin, per-step approval gating).
- Verified `ComputerUseSkillRecorder` multi-step workflow recording into per-app skills (`SkillScope.app(bundleId)`), stripping user-typed text, OCR coordinates, and dynamic data rows.
- Verified Safety HUD lifecycle (`ComputerUseSession.shared.began`), emergency Stop (Esc key monitor), and 30-second stop cooldown.
- 16/16 tests passing in `Context-DockTests/ComputerUseAcceptance3AppTypesTests.swift`. Clean gate build `./scripts/check.sh` passed.

**Task #369 Part 2: Expand 5-Tool Engine to Apple Mail & Reminders/Calendar (Apps #4 & #5) + Native MCP Server Dogfooding:**
- Completed and merged via PR #369 (`2ca630e`).
- Apple Mail: Headless reads (`mail.unread`, `mail.search` with query support), drafted send (`mail.send`, `send_mail`) with `AICapabilityApprovalCenter` outbound confirmation card, automatic contact resolution (`resolveRecipient`), headless AppleScript dispatch, and verified read-back against Sent mailbox history (`verifySentMail`).
- Apple Reminders & Calendar: EventKit headless access (`reminders.list`, `reminders.create` with verified read-back, `calendar.todayEvents`, `calendar.today`).
- Universal 5-Tool Engine: Registered `read_unread_mail`, `search_mail`, `send_mail`, `list_reminders`, `create_reminder`, and `get_today_events` in `AgentToolRegistry`. Classified tools in `OutboundGate` and added step narrations.
- Native MCP Server Bridge: Verified end-to-end execution of `initialize`, `tools/list`, `read_data` (Calendar events, Reminders list, Mail unread, Mail search), and `look` (menu hierarchy) via `http://127.0.0.1:8213/mcp`. Added `context-dock` to Claude CLI configuration (`✔ Connected`).
- Verified with `MailAndCalendarRemindersEngineTests` (7/7 pass), `NotesAndSafariCapabilityTests` (2/2 pass), and `MessagesSendWorkflowTests` (4/4 pass). Clean gate build `./scripts/check.sh` passed.

**Task #205: App agent plan P11 — Curated capabilities / routes for remaining system scopes:**
- Completed and merged via PR #367 (`8f02fa9`).
- Curated tool catalog, parameter schemas, and route discovery for all 11 core macOS system scopes.

**Task #369: Universal 5-Tool Engine & Messages Gold Standard Pipeline (Milestones 1-5):**
- Completed and landed on `general-chat-agent` (`5b86f59`).
- Spec: `docs/superpowers/specs/2026-11-04-one-app-perfect-flow-messages.md`.
- Principle: The AI Model is the Brain, Context-Dock is the Safe Native Body.
- Milestone 1 (Zero-Withholding Tool Surface): Removed keyword-based tool withholding in `FrontmostAppTaskPlan.swift`; App Pets always receive full sensory and execution tools. Fixed Settings › Integrations display for native apps (shows "Messages" and 4 built-in actions).
- Milestone 2 (Messages Send Pipeline): Implemented `send_message` / `messages.send` with automatic Contact resolution (`CNContactStore`), explicit outbound draft card confirmation (`AICapabilityApprovalCenter`), headless AppleScript execution with UI automation fallback (`imessage://` + `AXUIFocusHelper`), and verified read-back against `chat.db` (`MessagesChatDBReader.verifySentMessage`). Verified by `MessagesSendWorkflowTests` (4/4 pass). All 12 unit tests pass.
- Milestone 3 (Action Creator Simplification): Restructured `AdapterActionEditorSheet` from 10 technical items down to 3 clean choices (🌟 AI Goal [Recommended], ⚡️ Shortcut or Link, 💻 Custom Script). AI Goal directly defaults to `aiPrompt` and lets the model act as the brain.
- Milestone 4 (Notes & Safari Capabilities Expansion): Implemented `notes.recent` and verified read-back for `notes.create` / `notes.append`. Built `AppleSafariMCPCapabilities` (`safari.currentTab`, `safari.pageContent`, `safari.listTabs`, `safari.switchTab`) with verified read-back and tab switching. Verified by `NotesAndSafariCapabilityTests`. Clean `./scripts/check.sh` build passed.
- Milestone 5 (Native MCP Server Bridge): Exposed the 5 universal tools (`look`, `do`, `script`, `read_data`, `ask`) over Context-Dock's native MCP server (`context-dock`). External agents and CLIs (e.g. Claude Code) can invoke Mac capabilities natively over standard JSON-RPC HTTP transport (`127.0.0.1:8213/mcp`). Updated registration command and added one-click copy buttons in Settings › AI Providers. Verified by `DoraXMCPCapabilityToolTests`.

**Task #368: Unified Frontmost App Agent & Autonomous Computer Use Escalation (Phases 1-4):**
- Completed and merged via PR #368 into `general-chat-agent`.
- Spec: `docs/superpowers/specs/2026-11-03-unified-frontmost-app-agent-and-computer-use.md`.
- Phase 1 (Context Assembler Unification): Injects frontmost app's AGENT.md, per-app skills (`SkillScope.app`), and live menu commands snapshot into user-selected AI Provider's turn context. Ambient app discovery for General Chat & App Pet turns; non-blocking fallback to `run_menu_command` and `operate_app`. Verified by `FrontmostAppAgentPhase1Tests` (6/6 pass).
- Phase 2 (Autonomous Scripting Tool): Sandboxed `run_synthesized_script` capability allowing Claude/Codex to execute on-the-fly AppleScript/JXA with `AICapabilityApprovalCenter` approval gating and `AGENT.md` safety verification; `read_app_dictionary` tool to inspect sdef classes, properties, and commands. Verified by `SynthesizedScriptToolTests` (8/8 pass).
- Phase 3 (Seamless Computer Use Cascading): Deprecated blocking "Install CLI" cards in favor of autonomous escalation with optional accelerators; enhanced `ComputerUseTargetResolver` with hierarchy/path segment delimiter parsing (`>`, `▸`, `›`, `/`, `|`) and full-path token matching; added `AXUIFocusHelper` for one-shot search field focusing and direct text entry; verified with `ComputerUseEscalationPhase3Tests` (7/7 pass).
- Phase 4 (End-to-End Verification Across 3-Tier Escalation Ladder): Verified Tier 1 Apple Native App headless / data lane planning and context assembly, Tier 2 Scriptable Third-Party App sdef inspection and synthesized scripting execution, Tier 3 Non-Scriptable UI App fallback escalation to live menu commands and Computer Use, and ambient context isolation across app switches. Verified by `FrontmostAppAgentE2ETests` (4/4 pass).
- Gate `./scripts/check.sh` clean build passed. Full test suite (25/25 tests) passed.

**Task #343: App Pets Stage 6 — Bounded proactive behavior (2026-11-02):**
- Completed and merged (#366).
- User-controlled opt-in proactivity per Pet and per behavior (`AppPetProactivitySettings`, disabled by default).
- Verified triggers based on read-only facts, clear provenance (`AppPetProvenance`), and explicit rationale ("why this Pet surfaced", "what changed").
- Interruption budgets (daily suggestion cap, minimum cooldown), quiet periods (active user typing, in-call/DND, quiet hours), and fingerprint-based deduplication.
- Headless monitoring bounded execution (`HeadlessMonitoringBudgetTracker`: max tokens, max duration, max rounds, max consecutive no-progress scans before backoff).
- Consequential action approval gate (`requiresApproval`, explicit `approveAndExecute` authorization; suggestions never act, widen scope, or launch UI silently).
- Unified suggestion state shared across detached Pet action bubbles (`AppPetActionBubbleKind.suggestion`), Dock strip, and App Chat sheets.
- All 9 deterministic tests passed (`AppPetProactivityTests`); full regression suite passed (38 tests).

**Task #342: App Pets Stage 5 — Detached Pet presentation overlay (2026-10-31):**
- Completed and merged (#364).
- 3-tier progressive disclosure lifecycle: floating desktop pet mascot with pinned bubbles, compact launcher, and expanded window.
- Persistent action bubbles retention until explicit dismissal (`✕`).
- Mascot click jumps directly to Tier 3 Expanded Window; chevron `^` converts pet into Tier 2 Launcher/App Chat sheet with smooth expansion; micro-bar `✏️` expands into inline input bar without summoning dock.
- Dragging dormant Pet icons out from running apps row materializes floating desktop companion; reattaching/closing preserves conversation and verified memory.

**Task #363: UTCP Direct Tool Calling Protocol for App Pets & API Connections (2026-10-31):**
- Completed and merged (#365). Universal Tool Calling Protocol (utcp.io) and OpenAPI 3.x schema support for zero-daemon direct HTTP and CLI tool execution. Integrated with `AgentToolRegistry`, `APIConnectionStore`, `AppPetManifest`, Keychain auth, and Settings UI.

**Task #341: App Pets Stage 4 — Customization via /mods (2026-10-30):**
- Completed and merged (#362). Per-Pet `AppPetManifest` schema, canonical manifests, `/mods` command parser, active mode state persistence, capability filtering, and UI integration.

**Task #340: App Pets Stage 3 — Three-tier memory (2026-10-30):**
- Completed and merged (#361). Three-tier memory separation and provider context projection.

**Dynamic Notch / MacBook Pro & Air Dynamic Island Anchor (2026-10-29):**
- Completed and owner-approved ("its prefect. push and merge.").
- Adds `.notch` anchor to `CornerDockAnchor` framing the hardware notch on notched MacBooks and top-center menu bar on external displays.
- Safe area notch clearance: queries `NSScreen.safeAreaInsets.top` dynamically (`ScreenNotchMetrics.currentNotchHeight`), placing all cards (Clipboard, Drop Shelf, App Chat, suggestions) safely below the camera housing.
- Full Liquid Glass fidelity: authentic `GlassBackground` translucency, live wallpaper blur, and specular rim highlights preserved on combined result sheets (`CornerCombinedCard`) and resting pills.
- Clean notch tap and top edge auto-hide: tap gesture on notch triggers smooth downward expansion (`.spring(response: 0.36, dampingFraction: 0.82)`); bottom-edge pointer immunity prevents false reveals.
- Live Activities & Shape: `DynamicIslandNotchShape` and `DynamicNotchLiveActivityView` (referencing NotchNook & Pinterest AI turn tracking).

**Handoff (2026-10-28, cloud session → Mac): four cost/auth follow-ups.** Two PRs merged this
session — **#347** (pin `"model": "sonnet"` in `.claude/settings.json`; cost-discipline section in
`00-MODEL-ROUTING.md`) and **#348** (classify expired-OAuth `claude` CLI failures as
`.notAuthenticated` instead of surfacing the raw "Failed to authenticate: OAuth session expired and
could not be refreshed" text — new `ClaudeCodeCLIService.isAuthFailure`; Mac-verified green, 2904
tests, new test `anExpiredSessionIsClassifiedAsAnAuthFailure` passed). Open follow-ups for a Mac
session, in order:
1. **Close the usage leak (biggest).** #347 defaults sessions to Sonnet, but the ~60% "Subagent"
   burn is the account-level `/builder` / `/loop /builder` skill likely spawning the **Opus
   `reviewer`** every iteration. That skill is NOT in this repo. Audit it: reviewer runs once per PR
   (pre-ready), not per cycle; builder sessions must start on Sonnet. Fix the skill, not the repo —
   see `00-MODEL-ROUTING.md` → Cost discipline rule 2.
2. **Re-auth the real subscription login.** The owner's original "OAuth session expired" was likely
   the Mac being out of disk (token cache can't write to a full disk; ~33 GB freed this session).
   Run `claude login` / `codex login` and confirm the provider answers — #348 only made the *message*
   actionable, it does not refresh a dead token.
3. **Don't recharge a third account.** Verify one full day of Sonnet-default usage first.
4. **Worktree cleanup.** Remove `.claude/worktrees/oauth-348` (merged as #348) and the ~2.3 GB
   `issue-42-overask/.build` if that PR is done (AGENTS.md cleanup rule; never a dirty/unmerged tree
   or one a running app was built from).

**Start here (2026-10-27):** read *State (2026-10-27)* below first — #324 and #328 merged, Codex's
#327 (App Pets docs) is in progress, and the next `ready` task is **#205** (#204 P10 is still held).

**#327 App Pets product architecture (docs only, 2026-10-27):** update the blueprint and impacted
architecture truth for one Dock, Global Context, App Pets, Combined Chat, memory and `/mods`.
No product code starts from this document until the owner verifies the final decision card and an
implementation plan is approved. Canonical spec:
`docs/superpowers/specs/2026-10-27-app-pets-combined-chat-design.md`.

**Fresh planner, start here (2026-10-26):** **#318 MERGED** — PR **#320** (`fab61e8e`) unified Global Context + frontmost Context Dock into one surface (`SurfaceFocus` + pure `SurfaceFocusRules.decide` + tests; lanes/`DockEngine`/`DockCore` untouched; "never merge layers" reworded in AGENTS.md/CLAUDE.md/blueprint). Owner hand-checked "320 passed"; issue #318 closed. Planner review posted a swipe-up-in-General finding then **retracted it as a false positive** (`destination()` early-returns for `.general` before the layer branch; read the diff hunk without the unchanged top block — lesson: review the whole function). Also merged: **#310** (opencode.json, `6f920942`), **#322** (planner handoff docs). **Local worktree `issue-318-unify-dock-surface-561302` not removed** (held the owner's running hand-check app). Cleanup is the owner's, once the app is quit and after checking the tree — `git -C <wt> status` shows one **untracked** `docs/screenshots/318/frontmost-focus.png` (an extra not in the merged PR; the numbered shots 1–3 are committed and in `fab61e8e`). Preserve that file if wanted, then remove (the squash-merge leaves the branch reading "3 commits ahead" though its content is merged): `git worktree remove --force .claude/worktrees/issue-318-unify-dock-surface-561302` then `git branch -D claude/issue-318-unify-dock-surface-561302`. `--force` only after confirming nothing untracked there matters (AGENTS.md cleanup rule). **#208 P13 / PR #312 MERGED** (`42c0b70e`, owner "312 passed" 2026-10-26) — dictionary rung + tool-less-provider live property read; frontier moves to #204. **#204 P10 held** by the owner (re-label `ready` to resume — ~14 shortcuts left). Queue candidate not yet `ready`: **#316** (refusal-text-as-answer). Builder sessions the planner spawns must be set to **Sonnet**; cross-session send can't reach a builder a *previous* planner spawned (memory `fresh-planner-cannot-reach-prior-builder`). Queue fed: `ready` = **#323** (Corner UI size/expand/side-rail — new, verify scope), **#205**. New: **#321** docs-only design proposal (owner's own cloud session) — owner's, not planner queue.

Owner rules: merge only on the owner's "merge N" / "N passed" (docs-only PRs the planner merges once green); **no `ship it` while the Hand-check queue has entries**; the builder runs each PR's hand check itself first (`.claude/commands/builder.md`). Owner 2026-10-11: only #78 and #238 need the owner's hand check; #224, #210, #194, #230, #124 may merge without one (record under *Skipped hand checks*).

**State (2026-10-15):**
- Done: #230 (fixes #228: Claude Code in app chats runs `mail.search` through `dorax_run_capability`, no osascript; owner hand-tested "230 passed" 2026-10-15), #224, #210, #194, #238, #229, #234, #231, #237, #240, #241.
- #78 and #124 are superseded by the head (selection actions live in `Services/SelectionActions.swift`; skills are in `.claude/skills`); the owner closes them. #239 is moot once they are closed.
- Next: **#196** P2 (`ready`), then **#197** P3, then #180, #185, #198 P4, #199 P5. #225 test-isolation fix is queued. Nothing is `in-progress`.
- **Owner rule (2026-10-15):** clean up worktrees after each PR merges, rather than letting them pile up (28 reached 17 GB). `git worktree remove <path>`; never a dirty or unmerged one, nor one a running app was built from. Written into `AGENTS.md`.

**State (2026-10-18):**
- Merged today: #290 (Global S3 time-words + weekday fix), #292 (Messages/Safari WAL readers), #291 (Claude project setup), #294 (S5 learn-from-picks), #295 (P3b two lanes), plus ChatGPT Subscription #293. #247 closed (already shipped via #251–#256).
- #279 (mail.search bulk) merged 2026-10-19 on the owner's "merge 279".
- #296 filed: data-lane Mail search not wired on the ChatGPT provider + Mail scope.
- App-agent lane: #197 P3 done (#276), #277 P3b done (#295), #198 P4 in review (#297, awaiting owner hand-check); next **#199** P5.
- **Owner rule (2026-10-18):** never merge before the owner's hand-check — a CI-green PR waits for the owner's "merge N".

**State (2026-10-19):**
- Merged into `general-chat-agent`: #297 (P4 shortcut steps), #299 (P5 reasoning-steps panel), #301 (#300 graphify platform-specific). **P1–P5 of the app-agent plan are done.**
- Mail app-chat bugs **#302, #296, #211 closed as phantoms** — all three were already fixed on `general-chat-agent`: mail body reads (commit `71da5937`, `MailMessageReaderTests`); `mail.search` headless route for tool-less providers in Mail scope (#279 bulk search + #293 ChatGPT provider); nested `dorax_ask` refused outright (`DoraXMCPServer.swift`). Full suite green (2759 passed). #302 was owner-hand-checked on a current GCA build. They had been reported from **stale main-based hand-check builds** (see the branch rule below) — not real regressions.
- App-agent lane frontier: **#200 P6** (`ready`) → **#201 P7** (`ready`) → #202/#203 P8/P9 · #208 P13 (after P6) · #204 P10 · #205/#206. Nothing `in-progress`.
- Verification card out for the other app-chat bugs (#235, #233, #188, #180): check each against current GCA before a builder writes any fix.

**State (2026-10-22):**
- Merged: **#309 (P8 CLI learner)** into `general-chat-agent` (`a51fea40`) on the owner's hand check ("hand check passed" 2026-10-22; CI green, suite 2792). Hand check found and fixed in-tree: the write gate read only the first token (nested deletes ran cardless — `2e1ab5e0`+`225ba472`), and scan feedback (`a97e89b7`): spinner + live scan-log tail, per-tool status (scanned-flat vs unreadable vs not-installed), 20 s exec watchdog for GUI tools (Obsidian --help hung forever), app-bundle run paths (iina-cli).
- **P1–P9 of the app-agent plan are done.** Merged: **#311 (P9 curated catalog + no-route card, folds the lane-fall fix)** into `general-chat-agent` (`5ca378af`) on the owner's hand check ("works perfect" 2026-10-22; CI green, suite 2804). The owner's Mail hand checks drove five in-tree fixes, all folded into #311: curated `AppToolCatalog` + `find_route` suggestions; the typed no-route card (installed-check, copy-install-only, menu fallback — shared across Corner and window); the data→UI lane fall with its plan card (`LanePlan.decide`, writes included — the closed-app dead ends in `LaneCoordinator.prepare` and `operate_app` are gone); the exec PATH now reads `TerminalPackageManager.userBinDirectories()` (a go-installed linked CLI ran → "command not found" before); and the app-chat prompt's CLI line carries the learned command manifest (the model composed `mail-app-cli archive` from the name alone before). Worktree `issue-203` removed after the merge; branch deleted.
- Owner 2026-10-22: the Settings sidebar reads as clutter (App Packs / Integrations / Plugins / Plugin Creator all take capabilities) — flagged, no issue filed yet, not part of #203.
- **Next: #208 P13 (scripting-dictionary rung)** → #204 P10 → #205/#206.

**State (2026-10-25):**
- **#200 P6 and #201 P7 closed** (done, hand-checked). P1–P9 complete.
- **#208 P13** in review on PR #312 (draft). Commits pushed (typed Apple Events, gated registration, read-back verify; hand-check rounds 5–6). CI green on the last build but the PR went **CONFLICTING** — base `general-chat-agent` moved under it; the builder must rebase before it can undraft/merge. Planner leaves it to the builder.
- **Queue fed:** `ready` = #208 (in-flight), **#205 P11**, **#204 P10** (two fresh ahead of the builder). #205 deps P5/#299 + E2/#170 are merged. #206 P12 stays blocked (needs #205 + E19a).
- **#310** (opencode.json config, non-queue) set to squash auto-merge on the owner's "merge 310"; `--admin` was blocked by the auto-mode classifier this session (no `Bash(gh pr merge:*)` allow rule), so auto-merge is the path. Branch was `BEHIND`; may need a re-update if auto-merge stalls.
- **#204 P10 shortcut 1 (Notes) done & merged** — #314 (retire the Notes keyword shortcut; owner hand-checked "314 passed") + follow-up #315 (`3cbee5ab`: owner hand check found gaps #314 missed — a **credential-redaction security fix** so note titles/snippets no longer reach the AI provider via `notes.search` model output; `notes.count` for real totals; and a tightly-scoped lane fix so find/search in a record-set app routes as a read, not `operate_app` screen-driving — `isActionRequest` untouched, two-sided test). Owner hand-checked "315 passed". #204 stays OPEN — ~14 more shortcuts, one PR each — but **HELD by the owner (2026-10-25, weekly-limit)**; resume by re-labelling `ready`.
- **#316 filed** (from #315 hand check): a tool's model-facing refusal text can surface to the user as the answer (`.ambiguous` branch of `operate_app` in `ComputerUseTool.swift`); #315 removed only this one trigger — other refusal branches/tools share the shape. Queue candidate, not yet `ready`.
- **#318 unify Dock surface — OWNER CONFIRMED, builder live (2026-10-25).** Merge Global Context + Context Dock (frontmost-app scope) into **one surface**: frontmost app = default focus, ⌘ zooms to Global, one shared state/row/input; lanes (headless read / UI act) unchanged. Overrides the blueprint's "never merge layers" rule (job-separation kept via query intent + lane; only shell/state merge) — brain decision `bea3d04e`. Issue #318 `in-progress`; a Sonnet builder session is running on branch `claude/issue-318-unify-dock-surface`, posting a **design note in the PR first** (reviewed before deep edits), then building. The work also rewords the "never merge layers" rule in AGENTS.md/CLAUDE.md/blueprint.
- **#310** (opencode.json config) still OPEN — squash auto-merge enabled but stalled on `BEHIND`; needs a branch re-update or manual nudge.
- **Model routing:** planner stays Opus; **builder sessions the planner spawns must be set to Sonnet** (`start_session model=claude-sonnet-5-5`) — see memory `planner-spawns-builder-sessions-on-sonnet`.
- **Next: #208 P13** (builder to finish) → (#204 resumes when the owner unholds) → #205/#206.

**State (2026-10-27):**
- Merged into `general-chat-agent`: **#324** (Task 323 Corner UI — Raycast-size compact chat, expand
  to the full window with the transcript, shared rail; `6c6c1a2e`). Owner hand-checked it in the Codex
  session ("its prefect", 00:17) and accepted expand staying in the conversation header rather than
  the footer. Also **#328** (`1ebcfae9`): the seven daily briefs 2026-10-19 → 10-27 that had been
  stranded on local branches.
- **In progress — #327 (Codex, owner's session): App Pets + Combined Chat blueprint, docs only**, in
  worktree `issue-327-app-pets-blueprint`. It edits `docs/master/DORAX-BLUEPRINT.md`,
  `docs/architecture/PRODUCT_LAYERS.md`, `UNIFIED_DOCK_SURFACE.md`, `CHAT_SCOPES.md` and adds
  `docs/superpowers/specs/2026-10-27-app-pets-combined-chat-design.md` and
  `docs/superpowers/specs/2026-10-28-pet-presentation-and-expansion-lifecycle.md` (3-tier lifecycle:
  floating desktop pet mascot with pinned bubbles and inline input, compact launcher, and expanded window).
  **Do not edit those files until #327 merges.** Direction the owner approved in that session: one Dock that opens as the
  frontmost app's Pet (⌘ or Backspace on an empty field goes to Global Context); every running-app
  icon is a dormant Pet that can be dragged out; General Chat stays Dora's Mac-wide conversation and
  borrows app abilities per turn without inheriting Pet memory; an App Pet becomes Combined Chat only
  when another persistent Pet is connected after approval; headless first; one shared native layer (selection, clipboard,
  windows, sharing, notifications, files). Open owner question: does a selection made before launch
  auto-attach to the frontmost Pet, or open the Selection Scope first?
- **#321** (draft Corner UI/UX plan) is superseded by #324 + #327; closed on the owner's request 2026-10-27.
- **Next:** #205 P11 (`ready`). #204 P10 stays held by the owner. #316 is a queue candidate.
- **Correction:** the 2026-10-27 daily brief compared against `main` (a stale release base), so its
  "00-NOW is 4 days stale" and "start at #208 P13" lines were wrong. The brief script should read
  `general-chat-agent` and skip held or merged items.
- **Repo repair (2026-10-27):** the pack index `pack-4eaf658c…` had lost its `.pack` data file, and a
  stale `multi-pack-index` (Sep 24) referenced it — together they produced 10,611 `git fsck` errors.
  The 54 objects that existed only there are unreachable and all still on GitHub. One reachable tree
  (`acb5f4f4`, local branch `claude/skills-folder-setup-2ed3e5`) was rebuilt from that worktree's
  index. The index files were moved to `~/cd-git-backup-20261027/` and `multi-pack-index` was
  regenerated; `fsck` is now clean apart from macOS `Icon\r` files that something wrote into `.git`
  on 2026-10-21 (owner to decide on removing them).
- **Rescue snapshots:** local branches `rescue/20261027-1155/*` (7) snapshot every dirty or
  branchless worktree as of 11:55. **Never merge them** — the main-checkout snapshot contains personal
  files. Delete once the owner has triaged the old local branches.
- **Worktrees:** removed `cd-docs-312` (#326 merged) and `issue-323-corner-ui` (#324 merged); pruned
  the stale `omnirouter-pricing-001390` entry.
- **Housekeeping (2026-10-27, owner-approved, Cowork session):** moved 12 stale worktrees to the
  macOS Trash (not `rm`; empty the Trash to free the space): `/private/tmp/ctx-323-verify`,
  `../Context-Dock-p13-check`, `../Context-Dock-t9`, `../Context-Dock-test`, `../Context-Dock-test-204b`,
  and `.claude/worktrees/` `daily-brief-2026-10-27`, `issue-150`, `issue-180-safari-follow-link`,
  `issue-208-handcheck`, `jolly-morse-b51c3e`, `skills-folder-setup-2ed3e5`, `task-189`; then
  `git worktree prune`. Kept: main checkout, both `~/.codex/worktrees/*`, `issue-327-app-pets-blueprint`.
  Their uncommitted work was checked before removal and not committed: t9's ~1,150 of 1,170 added
  lines were already on `general-chat-agent`; `-test` only reverted the droplet split; `issue-150` and
  `skills-folder-setup` were mode-bit and `caveman*` symlink noise; `task-189` turned the pbxproj
  `Icon\r` sweep into `Icon\n` (a bug). Patches are kept in
  `~/Developer/Context-Dock-worktree-backups/2026-10-27/`; detached commits not on the base are kept as
  local branches `backup/wt-{ctx-323-verify,Context-Dock-p13-check,Context-Dock-test-204b,issue-208-handcheck}`.
  Branches (incl. `claude/issue-180-safari-follow-link`, 1 unmerged commit) were left in place.
- **Personal files:** the two untracked résumé `.docx` files in the main checkout were moved to
  `~/Documents/Cv's/`. Other untracked items (Kanban Pro files, `skills/`, `.freebuff`, `.superpowers`,
  `release-beta.sh`, `sync-agents.sh`, `docs/ENGINEERING_TODO.md`) are project tooling and stayed.
- **Untracked sweep (2026-10-27, owner-approved, `0a1e0b3`):** gitignored the agent/tooling scratch
  so it stops showing as untracked — `.kanban/`, `.superpowers/`, `.freebuff/`, `skills/`,
  `attachments/`, `tickets/`, `MAPPING.md`, `sync-agents.sh`, `*.local-bak`,
  `.claude/skills/finish-before-expanding/`. Also deleted the orphan
  `Context-Dock/Services/OnDeviceStructuredStubs.swift` (never tracked, absent from `project.pbxproj`,
  zero callers). Left untracked for the owner to triage: `.gitattributes`,
  `.github/copilot-instructions.md`, `ORGANOGRAM.md`, `docs/ENGINEERING_TODO.md`, `scripts/release-beta.sh`.
- **graphify:** the main graph had not been rebuilt since 2026-09-22 — worktree updates never reached
  it. Rebuilt 2026-10-27; git hooks installed; worktree `--graph` rule and llmbrain lookup order
  added to `AGENTS.md`; OpenCode graph plugin added.

> **Integration branch — read this before catching up or cutting a worktree.** The live branch is
> **`general-chat-agent`**. Every builder PR bases on it (#276/#295/#297/#299/#301). **`main` is a
> stale release base, ~788 commits behind** — its tip is still PR #8; it only advances when a release PR
> (`scripts/release-prep.sh`) merges at `ship it`; `scripts/ship.sh` then only publishes. Therefore: catch up from `general-chat-agent`'s `00-NOW.md`, never main; cut
> every worktree with `source_branch general-chat-agent`; open PRs with base `general-chat-agent`. A
> build cut from main shows **old UI** and yields bug reports for things already fixed — exactly what
> made #302/#296/#211 phantoms.

## Next, in order (GitHub issues)

Owner order (2026-10-01): security first, then the AI engine plan, with the two owner bugs after E1.
The planner labels the next issue `ready` when the one before it is in review.

0. **App agent plan (owner 2026-10-06, "confirm plan")** — `docs/master/00-APP-AGENT-PLUGIN-PLAN.md`, in this order: ~~#195 P1~~ (#209, merged 2026-10-10) · ~~#196 P2~~ · ~~#197 P3~~ (#276) · ~~#198 P4~~ (#297) · ~~#199 P5~~ (#299, folds #185) · ~~#200 P6~~ · ~~#201 P7~~ · ~~#202/#203 P8/P9~~ (#309 + #311, merged 2026-10-22) · ~~#208 P13~~ (#312, merged 2026-10-26) · ~~#205 P11~~ (#367, merged) · ~~#368 Unified Frontmost App Agent & Autonomous Computer Use~~ (closed 2026-11-03) · **#204 P10** (retire remaining pre-model shortcuts in `DockCore+AIChat.swift`, one per PR: Notes #314/#315, Menu Command #402, Mail Question #403 merged; remaining shortcuts queued) · **#405–#413 Agent Harness Model (H0–H6)**.
1. ~~#146~~ (#163) · ~~#150 E2~~ (#170) — merged 2026-10-02
2. ~~#147~~ Drop Shelf becomes an icon at the end of the dock, in every app (UI) — closed 2026-10-04
3. ~~#165 E1b~~ (closed 2026-10-04) outbound-gate gaps: Mail/Messages/Notes untrusted, shell allow-list, exact typed URL (owner 2026-10-04: all three, option a)
4. ~~#151 E3~~ Prompt order (closed 2026-11-07) · **#152 E5a → #153 E5b** On-device (E5 needs the owner's escalation answer first) · **#397** Foundation Models native image input (after E5)
5. ~~#154 E6a → #155 E6b → #156 E7a · #157 E7b~~ (merged: #383, #389, #390, #391; closed 2026-11-07/08)
6. ~~#158 E8a → #159 E8b~~ (merged: #392, #393) → #160 E8c: built in #394 with a deterministic heuristic judge; **issue left open** for the owner (is that enough for 1.0, or add a model judge?)
7. **#134 Settings-card follow-ups** (`needs-owner`)

Labs, after 1.0: ~~E9 / E9a~~ (#340 / PR #361), ~~E9b `/mods`~~ (#341 / PR #362), ~~E17 CLI learner~~ (#202 / PR #309), ~~E18 / E19 proactive watch mode~~ (#343 / PR #366); remaining: E10–E16 from the engine plan, plus the blueprint's "Later" items — undo log and dry-run preview for writes, latency targets (first token under ~1 s), a per-turn "what left the Mac" view, a model-upgrade gate (rerun E8 before any new default model). **#398** App Intents / Siri AI (macOS 27.3+, opens discoverability via "Hey Siri, open Context-Dock for Xcode" — post-1.0).

**#327 owner-verified (2026-10-27, “okay. perfect”):** write a staged implementation plan and split it into issues in
this order: naming/scope model → conversation promotion/participant consent → three-tier memory →
`/mods` → detached Pet presentation → proactive Pet behavior. Each stage reuses the existing
Corner, stores, capability index and shared executor; no second engine or registry.
Plan written: [`2026-10-27-app-pets-rollout.md`](../superpowers/plans/2026-10-27-app-pets-rollout.md).
Implementation issues (all 6 stages complete): ~~#338 identity/scope~~ (#356, merged 2026-10-30) → ~~#339 promotion/consent~~ (#360, merged 2026-10-30) → ~~#340 memory~~ (#361, merged 2026-10-30) →
~~#341 `/mods`~~ (#362, closed 2026-10-31) → ~~#342 detached presentation~~ (#364, closed 2026-11-01) → ~~#343 proactive behavior~~ (#366, merged 2026-11-02).
Study copy (diagrams, reasoning, interview notes; not the source of truth for tasks): the owner's DoraX Master Blueprint and its pages — [AI turn](https://claude.ai/artifact/4jFrmW4XwXuetpV7sp5YLD), [target architecture](https://claude.ai/artifact/CDYUTY2zVpMTQDcSbyCQzT), [harness and graph](https://claude.ai/artifact/NX49kAEX2FskD9XWM57MmS), [agent blueprint](https://claude.ai/artifact/T7U6PWYuhZvbgCCdLc56sf).

Also open: cloud sessions must never merge their own PR (#114 merged before review).

## Skipped hand checks (re-check in one pass before any `ship it`)

- #224, #210, #194 — merged without a hand check on the owner's word, 2026-10-11 (none was `Hand check: required`).

## Hand-check queue

- (none waiting; #175's injection test passed with #187 on 2026-10-06)

Checked and passed: #118, #119, #121, #123, #125, #127, #137, #141 (2026-09-29/30); #148, #163, #164, #170, #174 (2026-10-04); #187 (#184, incl. #175's injection test) (2026-10-06).
A failed check becomes a `Fix:` issue at the top of the queue and its sentence goes into the matching test (routing: `RoutingPhrasebookTests`).

## Done — earlier log (2026-09 to 2026-10, table)

| Date | Task | PR |
|---|---|---|
| 2026-10-30 | #340 App Pets Stage 3: Three-tier memory separation (`AppPetMemoryController` for Tier 1 Pet identity memory with inferred confirmation, `CombinedWorkspaceMemory` for Tier 2 shared working memory across connected participants, `preferences.md` for Tier 3 Mac-wide Global memory; `dorax_remember` MCP tool saving to `preferences.md` with zero shell fallbacks; provider context projection with token budgets and near-limit choices; 'App Pet' header badges); owner hand-checked ("every request worked prefectly") | #361 |
| 2026-10-30 | #339 App Pets Stage 2: participant consent, atomic Combined Chat promotion, and General Chat TurnScope isolation — first-class ParticipantSet with minimumAdditionalPets offer ('+ Messages' preview chip + 'Connect Messages to this chat'), atomic in-place Combined Chat promotion without copying transcript, action approval separation, regression test forbidding hybrid 'Mail General Chat' identity | #360 |
| 2026-10-30 | #338 App Pets Stage 1: Pet identity (`AppPetID`) and single-Dock scope switching — clicking a running-app icon selects that Pet inside the Dock without activating the app, explicit Open App stays in the icon menu, ⌘ tap / empty-Backspace returns to Global Context, existing `dock_app_<bundleID>` history preserved; owner hand-checked ("working prefect") | #356 |
| 2026-10-26 | #208 P13: scripting-dictionary rung — read any scriptable app via its sdef; tool-less providers get a deterministic live property read (`sound volume`, `current track`) before the model, adapter/lanes untouched; owner hand-checked "312 passed" | #312 |
| 2026-10-26 | #318: unify Global Context + frontmost Context Dock into one surface (`SurfaceFocus` + pure decide fn; frontmost = default focus, ⌘ zooms to Global; lanes untouched; "never merge layers" reworded); owner hand-checked "320 passed" | #320 |
| 2026-10-19 | P5: Progress panel shows the whole reasoning trace — Understood→Lane→Tools→Chose→Gate→Result; folds #185 | #299 |
| 2026-10-19 | #300: graphify is platform-specific — documented, not mirrored | #301 |
| 2026-10-19 | P4: pre-model shortcuts report a "Shortcut: …" step | #297 |
| 2026-10-19 | Fix: mail.search scans in bulk (was 9-28 s per call); owner hand-tested ("merge 279") | #279 |
| 2026-10-18 | P3b: the app agent's two lanes — data never takes the window, UI lane's last rung is Computer Use | #295 |
| 2026-10-18 | S5: the router learns from the owner's picks | #294 |
| 2026-10-18 | Claude project setup — connectors off, skills parity, model routing | #291 |
| 2026-10-11 | A `dorax_ask` inside a `dorax_ask` is refused, not recursed (Mail chat showed 6 stacked rows, each failing after ~60 s); hand check skipped | #224 |
| 2026-10-11 | Spawned `claude`/`codex` CLIs drop the host Claude Code session's env ("Not logged in" in Mail chat when DoraX is launched from a Claude session); hand check skipped | #210 |
| 2026-10-11 | A `[TERMINAL_COMMAND: …]` directive runs and is hidden in app scopes (Corner Finder chat "list the files in Downloads"); hand check skipped | #194 |
| 2026-10-11 | Desktop planner takes the Coordinator line | #240 |
| 2026-10-11 | #232 Corner dock magnification: continuous, unclipped, macOS-Dock smooth; search, clipboard, selection, shelf and feedback icons magnify too; owner hand-tested ("234 passed") | #234 |
| 2026-10-11 | Clipboard board: ⌘↩ with several clips opens a paste-target picker; a mix of images with text or files pastes the images, not row labels; multi-clip drag to Finder; owner hand-tested ("237 passed"). The #232 session merged it itself — planners merge, builders never | #237 |
| 2026-10-11 | Recovered from backup: MCP servers match bundle ids case-insensitively (Safari chats see `safari-mcp`); an app's name doing its ordinary job ("console", "notes") no longer offers that app; owner hand-tested ("231 passed"). Follow-ups: #233, #235 | #231 |
| 2026-10-10 | Build log goes to `.build/build-debug.log`; `dev-run.sh`/`build-debug.sh` print only `build: OK` or the errors (agent tokens per build); owner hand-tested | #226 |
| 2026-10-10 | #195 P1: the Mail search shortcut claims only an exact "search/find …" command and answers headless through `mail.search` (Mail's window untouched); the owner's "from" sentence goes to the model; panel no longer says "Answered without running anything" after a step; owner hand-tested | #209 |
| 2026-10-10 | UI/UX: "/" jumps to any app's scope from Global or a Context Dock (owner's Corner lane) | #222 |
| 2026-10-10 | UI/UX: Finder from Global is Finder's own Context Dock, with an Ask AI row (owner's Corner lane) | #221 |
| 2026-10-09 | Corner UI/UX: one field — apps are steps inside Global; ⌘ and swipes walk them (owner's Corner lane) | #220 |
| 2026-10-09 | Corner UI/UX: layout previews show the desktop's windows; the app card opens in the sheet's right half (owner's Corner lane) | #219 |
| 2026-10-08 | UI round 2: list duplicates, Dock ← chip, command arrows, Context Dock pill, drag to dock (owner's Corner lane) | #218 |
| 2026-10-08 | Corner: resting on the apps folds into the dock; one ← back chip for every scope (owner's Corner lane) | #217 |
| 2026-10-08 | Corner: Terminal freeze and keys; droplet split; app step-in rests as its own Context Dock (owner's Corner lane) | #216 |
| 2026-10-07 | Corner: running app icons manage windows; pinned extensions in the apps piece; compact app card (owner's Corner lane) | #215 |
| 2026-10-06 | E1c: Claude Code CLI loses WebFetch/WebSearch/Bash in private-data chats; `dorax_read_url` / `dorax_run_command` and on-device tools go through the outbound gate; owner hand-tested ("184 passed") | #187 |
| 2026-10-05 | Mail chat reads the message body (selected, open or latest; Mail closed or open), fenced and capped; never routes Mail to Messages; owner hand-tested. Gate test moved to #184 | #183 |
| 2026-10-04 | Mail chat: choices only for matching routes; a turn that ran a step shows no pick card (Corner, Dock, chat window); owner hand-tested ("quit mail") | #181 |
| 2026-10-04 | E1b gate: Mail/Messages/Notes reads count as untrusted, shell allow-list, only the exact typed URL is trusted, every tool name classified; text-recovered sends go through the gate (injection hand check owed) | #175 |
| 2026-10-04 | Drop Shelf is an icon at the end of the dock in every app, Dock and Corner; the floating card is gone; owner hand-tested | #174 |
| 2026-10-02 | Flaky turn-log and Shortcuts temp-file tests fixed (hand check optional) | #171 |
| 2026-10-02 | E2 Recorder: one trace per turn in the turn log; owner hand-tested | #170 |
| 2026-10-02 | Builder pauses after one required hand check; `hand-check-optional` label; "merge N without hand check" | #168 |
| 2026-10-02 | Finder chat carries out a resolved call or says why not; owner hand-tested | #163 |
| 2026-10-01 | E1 outbound gate: private + untrusted turns ask before sending out (owner hand-tested; gaps in #165) | #164 |
| 2026-10-01 | A read-back that disagrees with the request fails the step | #142 |
| 2026-10-01 | Clipboard notice no longer blocks the frontmost app | #144 |
| 2026-10-01 | Chat transcript rewrite loop no longer pins the main thread; app quits during a turn; owner hand-tested | #148 |
| 2026-09-30 | Skill audit of 16a–18: 4 P1 fixed (approval queue instead of a dropped request, cancellable file search, `nonisolated ShortcutsService`, per-file VoiceOver labels on file cards); 15 P2 listed in the PR; owner hand-tested | #141 |
| 2026-09-30 | Result cards skip `~/Library` / system paths from step output (iCloud Drive and paths the answer names are kept) | #138 |
| 2026-09-30 | Flaky `AXMenuReaderScriptedFallbackTests` fixed: each reader posts as itself, each test listens to its own (5×2241 green) | #136 |
| 2026-09-30 | Old Shortcuts route retired: only `run_shortcut` (16d) runs a shortcut; owner hand-tested | #137 |
| 2026-09-24 | Plans, blueprint, harness, check.sh | #76 |
| 2026-09-24 | Corner fixes (restore, folder preview, pins, Dock navigation) | #79 |
| 2026-09-25 | One-shell dock; → never runs a system command (D4); ↑ reaches Global (F2) | #80, #81 |
| 2026-09-25 | First letter typed from the resting strip no longer lost (B5) | #82 |
| 2026-09-25 | Selection in the Corner (D10 ✅): the Dock's rows on the captured selection, answers in the card, Share, "send to …" with confirmation, Quick Note, file preview, Computer Use rule | #84 |
| 2026-09-25 | AGENTS.md: Dock/Corner rule, 00-NOW.md in "Start here" | #88 |
| 2026-09-25 | Menu safety list (4a): whole words; History ▸ Forward is navigation; Reopen Last Closed Window / Recently Closed stay in results; page rows still open by URL; unsure stays gated | #91 |
| 2026-09-25 | Safari tabs in the Corner (D13): Context Dock folds into its tab bar | #89 |
| 2026-09-26 | Pins in the Corner strip (4b): per-app pins of menu commands, actions, extensions and tabs lead the app's bar; any app with pins gets the bar; pinned destructive commands still ask. Safari "Save as Markdown" / "Ask AI" actions not built (asked in PR) | #94 |
| 2026-09-26 | AppleScript runs on one serial queue (fixes the Safari tab-click crash) | #95 |
| 2026-09-26 | Keyboard rules (task 5) in the shared `DockKeyRules`: result focus, pill row, empty-field Backspace ladder, list arrows, Return, Space, Finder folders, ⌘R in the Corner; one key press, one handler; ←/→ walk the apps both ways | #96, #98 |
| 2026-09-27 | AppleScript re-entrancy crash: one recursive lock owned by a thread, not `DispatchQueue.sync`; also the Corner dock auto-hides and shows (setting) | #100 |
| 2026-09-27 | The Corner no longer pulls DoraX in front of the app you are using; no blink when the strip hands the keyboard back | #101 |
| 2026-09-28 | Safari actions (task 6): Ask AI about this page, Save as Markdown (Downloads, never overwrites, Reveal); sensitive pages refused | #102 |
| 2026-09-28 | Per-app settings card: pin beside +, ⚙ in the app chip opens Can do / Sees now / Allowed | #105 |
| 2026-09-28 | Remaining scopes (task 7): a Global Command's row steps in, never runs (D4, D5); attach Finder's front folder (D7); D14 marked; D6 left for the owner | #106 |
| 2026-09-28 | Plugins from search open in the Corner's board (D6); Finder in front lists its menus; the Dock's window layouts in the app field | #107, #108 |
| 2026-09-28 | Sensitive pages never reach the chat: the page reader keeps only the origin and the guard's reason; `read_page` returns the refusal; sensitive tabs listed by origin (task 9) | #111 |
| 2026-09-28 | The Dock's menu reader never runs System Events on the main thread; the walk runs off-main and fills in (task 10) | #110 |
| 2026-09-28 | ⌘R in the Dock re-reads the app's menus, one rule and one re-read shared with the Corner (task 11, C12) | #112 |
| 2026-09-28 | System connectors: Global Commands as chat tools — reads free, writes ask, same runner as the Global row (task 12a) | #113 |
| 2026-09-29 | App Packs page in Settings: one switch per pack, detail page with the card's sections, "Sends data out" (task 12b) | #114 |
| 2026-09-29 | Activity rows: one row per real step in General Chat, Dock and Corner; read-back results; picker risk Medium; status reads preferred (task 14) | #115 |
| 2026-09-29 | Result cards for every chat turn: paths in an answer or step output become Open / Reveal / Quick Look / drag cards in Dock, Corner and the Chat Window; owner hand-tested (task 16b). Follow-up: paths under `~/Library` from step output are noise | #118 |
| 2026-09-29 | "find my …" no longer routes to Find My: phrase-like app names need a real cue, discovery never launches an app, a generic Edit row is not an answer to a search; owner hand-tested (task 16e) | #119 |
| 2026-09-29 | Model-first routing: the keyword shortcut preempts the model only on an exact command; the model picks from the scoped app's commands; phrasebook tests of the owner's real sentences (task 17) | #121 |
| 2026-09-29 | File search with Spotlight off: `find_files` agent tool (Spotlight, then a bounded scan of Desktop, Documents, Downloads, iCloud Drive), Finder pack and `dorax_find_files` MCP tool; owner hand-tested (task 18) | #123 |
| 2026-09-29 | Output files: `write_output_file` writes .md/.txt/.csv/.docx into `~/Documents/DoraX Outputs/` (never overwrites, confined to that folder, approval sheet, refused when unattended) and shows a card; `dorax_write_output_file` on the MCP server; owner hand-tested (task 16c) | #125 |
| 2026-09-29 | Shortcuts connector: `list_shortcuts` and `run_shortcut` (exact/case-insensitive name from the list, High-risk approval sheet, 60 s timeout, output cap, refused when unattended) and MCP twins; "shortcut" is a noun, not the Shortcuts app; owner hand-tested (task 16d) | #127 |
| 2026-09-29 | Approval bridge: a CLI turn DoraX launched gets the normal approval sheet; unattended refusal is per-run (task 16a) | #117 |

## Owner decisions (append-only)

| Date | Decision |
|---|---|
| 2026-09-24 | Name: **General Chat** everywhere, never "AI Assistant". |
| 2026-09-24 | Priority: move the ⌥⌥ Dock into the Corner with exactly the same behaviour, functions and navigation. |
| 2026-09-24 | Swipes in the Corner: exactly the Dock's, horizontal and vertical, over the input only (`00-DOCK-AND-CORNER.md` §4b). |
| 2026-09-24 | Selection actions + swipes are one task (`corner-parity`). |
| 2026-09-24 | Global Context lives on the ⌘⌘ row; no separate hotkey row. |
| 2026-09-25 | Selection in the Corner: **B** — reuse the Dock's rows through a bridge now, extract later. Conditions: (1) behind a `SelectionActionProviding` protocol, the Corner never names DockCore; (2) works cold, before ⌥⌥ was ever opened (verified: DockCore is built at launch); (3) Corner-side tests for rows, order, close button, Esc; (4) GitHub issue "Extract SelectionActionSource out of DockCore", must land before the Dock retires. |
| 2026-09-25 | Selection AI rows (Ask AI, presets) run through the Corner's own ask path; the prompt lives only in `DockPill.selectionAIPrompt`, which the Dock also reads. |
| 2026-09-25 | Selection Share rows left out of the Corner for now; D10 stays 🟡 ("Share missing") until they return. |
| 2026-09-25 | The Corner captures the selection when it builds its list and runs every row on that copy, never on the live Dock payload. |
| 2026-09-25 | New bug-fix sessions wait until the Selection PR merges. |
| 2026-09-25 | Replaces "Share left out": the Selection card does everything the Dock's Selection does **inside one panel** — answers (never a second card), Share (the app's own share routes: native destinations, typed "send to …"), file preview, all extensions. D10 → ✅ when these ship. |
| 2026-09-25 | AX-driven work (menus, Writing Tools, writing into another app) runs only with Computer Use on for that app; otherwise the user's AI provider does it (surface-cost spec). |
| 2026-09-25 | Quick Note: a Save-to-Quick-Note action on answers; the knowledge graph gets no action. |
| 2026-09-25 | Test sends go only to the owner (Gokula Kannan J). |
| 2026-09-25 | Selection test matrix: Safari is checked like the other apps, not in depth. |
| 2026-09-25 | The Context Dock (frontmost-app chat) folds its field away at rest into a bar of the app's own things — pinned actions, open tabs, pinned tabs — like Global Context's running apps; not Global's pins. Open tabs in #89; pins are task 5. |
| 2026-09-25 | ⌥⌥ opens the **Dock**, ⌘⌘ opens the **Corner** — fixed, no setting. Task 3 ("⌥⌥ opens Dock / Corner" setting) is dropped. |
| 2026-09-25 | Chat Window hotkey stays **⌃C** (advised ⌃⌥C). Known cost: a global hotkey takes the key from every app, so ⌃C no longer interrupts a running command in Terminal (or reaches any other app) while DoraX runs. Revisit if that bites. |
| 2026-09-25 | Safari tabs show as **pills in the Corner's strip next to the input**, like the Dock's tab strip — not as rows in the result list. The strip auto-sizes. |
| 2026-09-25 | The Corner's strip holds the user's **pins per app**: tabs, menu commands, app actions (e.g. Safari: Add to Bookmarks, Export as PDF, Save as Markdown, Ask AI) and the user's own actions. |
| 2026-09-25 | Every Corner scope (frontmost app / Context Dock, Safari, …) uses the **same shell size, field and strip style as Global Context** — one look, not a wider or smaller variant per scope. |
| 2026-09-25 | UI changes are checked by eye against a reference screenshot before a PR is called done (AGENTS.md); tests alone are not enough. |
| 2026-09-26 | Build Safari **"Ask AI about this page"** and **"Save as Markdown"** as app actions (task 6, after task 5). |
| 2026-09-26 | While typing, every Context Dock is compact: no tabs pill, no pinned pages, no extensions — just attach (+), send and pin; no expand. Replaces "Safari's tabs stay while a question is typed" (2026-09-25). An app's pins show in its bar and the field's pill at rest, ahead of the tabs. |
| 2026-09-26 | B2 (Backspace into inline text pills) is "—" in the Corner: its scope is one chip outside the text; leaving it is B3. (Accepted by merging #98, which asked for it.) |
| 2026-09-29 | Strict order: finish 16 (a, b, e) and 17, hand test, merge, then 18. 16c/16d move after 18. |
| 2026-09-28 | "App Pack" is the name for an app's bundle of actions, skills, menus and tools; System packs group Global Commands. No Discover/marketplace in 1.0. |
| 2026-09-30 | Planner (cloud) and builder (Mac Desktop) roles; GitHub issue labels are the queue; hand-check queue emptied — all merged work through #137 checked by the owner. |
| 2026-10-01 | AI engine plan accepted: `docs/master/00-AI-ENGINE-PLAN.md` (#161). E1–E8c are 1.0; E9–E16 are Labs. |
| 2026-10-01 | Security first: E1 (#149) runs next, then #146, E2, #147. #134 stays needs-owner. #44 closed (fixed in f2d3d5f). |
| 2026-10-01 | On-device fixes (E5a, E5b) are 1.0: on-device chat ships today and loses its history. |
| 2026-10-01 | The engine plan file defines tasks; this file sets the order. The owner's Master Blueprint pages are the study copy, not a second plan. |
| 2026-10-04 | E1b yes (#165): Mail/Messages/Notes reads count as untrusted; shell commands use an allow-list; only the exact typed URL is trusted. Runs after #147, before E3. |
| 2026-10-05 | Merges (A): only the cloud planner merges, on the owner's words "merge <n>" in the planner chat. The Mac builder never merges, even after a passed hand check. |
| 2026-10-05 | Owner "yes": the owner's "N passed" (hand check) is also permission to merge that PR once CI is green; docs-only PRs (no hand check) the planner merges itself once CI is green. |
| 2026-10-06 | Adopted the app agent + plugin manager plan: two lanes (data never takes the window; UI lane's last rung is Computer Use), menus out of the default prompt, plugin manager fronting existing registries, CLI learner, curated catalog, solved-task library. P1–P12 = #195–#206; P1–P3 go before #180/#185 (`00-APP-AGENT-PLUGIN-PLAN.md`). |
| 2026-10-27 | Product end state: **one Dock**. A normal launch opens the frontmost **App Pet**; Global Context is the launcher/home. Centre and corner are placements of the same shell. |
| 2026-10-27 | Running/pinned app icons are dormant Pets: click switches the Dock to that Pet; drag out creates a persistent detached Pet backed by the same profile, conversation stores and agent harness. |
| 2026-10-27 | Every Pet composes app identity, knowledge, skills, connectors, capability routes, conversation, short/long memory and `/mods`; it is not a permanent model process and not a new registry. |
| 2026-10-27 | Cross-app requests connect the minimum required Pets and promote the same thread to **Combined Chat**. Connecting scope is separate from write/outbound approval. |
| 2026-10-27 | Headless first: do not launch when a route can finish headlessly; start hidden if only the process is needed; explicit open/show launches directly; visible UI used only as fallback asks before taking focus. |
| 2026-10-27 | Selection, clipboard, windows, files, native sharing and notifications are shared host capabilities available to all Pets through one scope/approval/execution/verification layer. |
| 2026-10-27 | Command or empty Backspace returns an App Pet to Global Context without recreating the Dock or discarding typed text. |
| 2026-10-27 | #327 architecture confirmed after clarification: headless means structured adapter/API/MCP/CLI/Shortcut work, not Computer Use; Computer Use is the visible-UI last resort. Clicking a running-app icon changes the active Pet inside the same Dock and does not foreground the underlying app or create a window; dragging detaches it. |
| 2026-10-28 | **General Chat and App Pet Chat are separate identities.** General Chat is Dora's Mac-wide conversation and may use an app ability only for the current turn; this does not rename it, load Pet memory or restrict later turns. **Open in App Pet** explicitly creates the anchored, remembered app conversation. Combined Chat requires persistent connected Pets, not merely multiple tool routes. |
| 2026-10-28 | **Pet presentation & expansion lifecycle:** clicking/double-clicking the floating desktop mascot jumps directly to Tier 3 (Expanded Window); action receipt bubbles stay pinned until explicitly closed with ✕; micro-bar ✏️ expands into inline input `[+] [Start new chat] [↑]` without opening a window (spec: `docs/superpowers/specs/2026-10-28-pet-presentation-and-expansion-lifecycle.md`). |
| 2026-11-05 | **Two-Sided Normalized Adapter Architecture & Settings Consolidation:** Documented in `FRONTMOST_AGENT.md` (§7) and `CAPABILITY_LAYER.md`. DoraX acts as the governor and sandbox between frontmost apps and AI providers (Claude Code / Codex / Gemini), replacing fragmented manual scripts with the 3-Tier Escalation Ladder (built-in/UTCP → synthesized scripting → Computer Use UI automation). Settings UI consolidated via Task #373 (`docs/superpowers/specs/2026-11-05-streamline-settings-and-extensions.md`). |
| 2026-11-08 | **Apple API opportunities noted (not yet owner-confirmed):** (1) Foundation Models native image input (macOS 26.4+) — `OnDeviceToolBridge` already uses `FoundationModels` but falls back to Vision OCR for images; native multimodal is now available. Filed as **#397**, queued after E5b (#153). (2) Siri AI / App Intents (macOS 27.3 dev preview) — expose OpenAppPet, SwitchScope, SummariseContext as App Intents so Siri AI can invoke them. Filed as **#398**, Labs / post-1.0. Neither is `ready` until the owner labels it so. |
| 2026-11-09 | **Agent harness model (owner direction, details pending approval):** the AI provider is only the brain; Context-Dock is the harness ("our version of the Claude app"): it builds context from the frontmost app and selection, offers skills by name and a small tool core, runs tools, asks approval, verifies and **learns**. Menu commands stay, with two jobs: knowledge (titles, never pressed to know) and action as rung 3, above Computer Use and below saved skill / direct data / AI-written script, except in the UI lane where the menu goes first. A route that worked is saved as a skill (script, direct call or menu path, not only clicks) and tried first next time, on-device too (learn online, replay offline). Spec: `docs/superpowers/specs/2026-11-09-agent-harness-model.md`. Proposed work H1–H6 is not filed until the owner approves the spec and its §13 questions. |
| 2026-11-09 | **Agent harness spec approved** ("Confirm, do best that fits our app"): `docs/superpowers/specs/2026-11-09-agent-harness-model.md` rev. 3, Goldfish review 4 = 0 blocking. Owner confirmed: (13.1) read skills auto-save with "Saved as a skill · Undo", write/send/delete skills are offered ("Save as a skill?"), per #205 rule 4; (13.2) a replayed skill is approved like a fresh run, with existing "always allow" honoured and delete/send never standing, per SAFETY.md; (13.5) learned skills are listed in the app's Resources (Global tab for global ones) under "Made by DoraX", replacing #205 rule 6's "Settings › Plugins". (13.3, delegated) the menu browser stays as a power-user view. Filed **#405–#413** (H0–H6); none `ready` until labelled. |
| 2026-11-09 | **Unified Spotlight-Pet Surface approved** ("Yes make it prefect"): dissolves the modal ⌘ toggle between Global Context and App Pet into a single, context-biased intent bar. Queries simultaneously evaluate frontmost menus (boosted +500), global apps, system commands, files, and clipboard clips. High-confidence commands display inline ghost completion and run instantly on ↵. Natural-language questions apply a -100 penalty to incidental file keyword collisions, boosting [ 🤖 Ask Pet ] and [ 🌐 Search Web ] to the top. Spec: `docs/superpowers/specs/2026-11-10-unified-spotlight-pet-surface.md`. |
| 2026-11-09 | **Docs audit cleanup (owner: "do 1–5, delete CONTEXT.md, … do the best thing"):** `CONTEXT.md` and its generator `generate-context.sh` deleted (a June snapshot naming 24 removed files and the retired layer rule). `docs/ENGINEERING_TODO.md` deleted (99% duplicate of `docs/history/ENGINEERING_TODO.md`; TODOs live in #69–#74). `CHANGES.md` (journal stalled 2026-07-21), `FOUND.md`, `PRERELEASE_AUDIT.md`, `ARCHITECTURE_RELEASE.md` moved to `docs/history/`. Kanban Pro's `.github/copilot-instructions.md` and `ORGANOGRAM.md` (auto-generated on project load; swept into git by #371; left for triage on 2026-10-27) untracked and gitignored, so Kanban Pro keeps writing them locally and GitHub Copilot stops reading Kanban rules as repo instructions. `docs/engineering/codebase.md` refreshed against the code; `CLAUDE.md` skills table marks Mac-only skills. |

## Open decisions (owner)

- #160 E8c: PR #394 grades replays with a deterministic heuristic judge, not a model. Is that enough for 1.0? (If yes, close #160.)
- E5: in on-device-only mode, may DoraX *offer* a cloud model when a task is too big, or never mention it? Needed before #152.
- D9 Notifications, D11 Quick Note editor, D12 Mail in the Corner: move, or drop from v1?
