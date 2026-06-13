# Engineering TODO

Track release work here. Keep each item small enough for one pull request.

## Done

- [x] Finish app architecture split; stop broad architecture extraction work.
- [x] Add `AIProviderRouter` and provider adapter boundary.
- [x] Move AI API keys from UserDefaults to macOS Keychain with legacy migration.
- [x] Add configurable OpenAI-compatible endpoint and model support.
- [x] Add `AIContextBuilder` foundation.
- [x] Add `AISafetyPolicy` foundation.
- [x] Preserve on-device AI path and rich context behavior.
- [x] Reduce Global Context short-query noise by requiring 3+ characters for global app search.
- [x] Reduce Global Context recent document noise by requiring 3+ characters.
- [x] Use stable row IDs for Context Dock vertical result rows.
- [x] Use stable row IDs for Global Context app, menu, and cross-app menu rows.
- [x] Confirm Apple Menu items are excluded from persistent per-app menu cache.
- [x] Confirm dynamic recent menu branches are excluded from persistent per-app menu cache.
- [x] [Find] Add first-pass app-scoped Find pill and submit routing before generic Finder/context actions.
- [x] [Find] Replace result-row Find with inline input token and optional child-menu picker.
- [x] Verify Debug build with isolated DerivedData.

## Next

### AI Foundation: Single Request Pipeline

Final rule: UI and feature files never call OpenAI, Anthropic, Gemini, Ollama, or compatible endpoints directly. Every request routes through `AIProviderRouter`.

- [x] Replace direct provider calls in `LauncherView+AIProviderCalls.swift` with `AIProviderRouter`.
- [x] Move remaining provider-specific HTTP and response decoding into `AI/Providers/`.
- [x] Delete obsolete direct provider helper methods after all callers migrate.
- [x] Add routing assertions or debug logging to detect requests bypassing `AIProviderRouter`.
- [x] Add manual QA matrix covering AI Chat, Global Context, Context Dock, extensions, and terminal AI for every configured provider.
- [x] Add provider-specific tool HTTP adapters for OpenAI, Anthropic, Gemini, Ollama, and OpenAI-compatible endpoints; remove direct tool HTTP calls from `AIProviderService`.
- [x] Move provider-specific tool definitions, iteration, request bodies, and response handling from `AIProviderService.swift` into `AI/Providers/AIProviderToolLoops.swift`; keep `sendWithTools()` as orchestration facade.

### AI Provider Support Policy

Context-Dock supports provider APIs and endpoint abstractions. It does not integrate directly with consumer AI subscriptions or reuse browser/desktop-app sessions.

Launch-supported providers:

- Apple On-Device Intelligence
- OpenAI API
- Anthropic API
- Gemini API
- OpenRouter
- Ollama
- LM Studio

Experimental provider:

- Generic OpenAI-compatible endpoint
- Local gateways and compatibility layers exposing `/v1/chat/completions`
- Subscription-backed bridges only when an external tool exposes a compatible endpoint

Not supported:

- Direct ChatGPT Plus subscription integration
- Direct Claude Pro subscription integration
- Login with ChatGPT or Claude
- Reading browser cookies
- Reading ChatGPT, Claude, or other desktop-app sessions
- Promising support for subscription-backed models behind third-party bridges

Architecture rule:

```text
Context-Dock
  -> AIProviderRouter
  -> Official provider API
     OR
  -> OpenAI-compatible endpoint
```

ChatGPT Plus and Claude Pro are not provider types. Context-Dock treats external subscription bridges as generic OpenAI-compatible endpoints.

- [x] Group Settings AI sources into `Official`, `Local`, and `Experimental`.
- [x] Label OpenAI-compatible endpoint support as experimental.
- [x] Add OpenRouter preset using OpenAI-compatible adapter.
- [x] Add LM Studio preset using OpenAI-compatible adapter.
- [x] Keep Ollama first-class adapter and local provider.
- [x] Add endpoint connection test that validates `/v1/chat/completions` compatibility.
- [x] Add clear warning that third-party compatibility layers are user-managed and unsupported.
- [x] Document provider support policy in README.
- [x] Document that ChatGPT Plus and Claude Pro do not include official third-party API access.
- [x] Never add cookie/session extraction or unofficial subscription login flows.

### AI Request And Multimodal Context

- [x] Replace text-focused `AIProviderRequest` with shared `AIRequest`.
- [x] Add request mode: `answer`, `plan`, `execute`, `explainResult`.
- [x] Add request source: `globalContext`, `contextDock`, `mediaDock`, `aiChat`, `extension`, `workflow`.
- [x] Add typed attachments: image, file, PDF, URL.
- [x] Route existing image-specific provider paths through adapter attachment support without changing current behavior.
- [x] Add provider capability checks for vision, file input, tool calls, and local-only processing.
- [x] Define graceful fallback when selected provider cannot process an attachment.

### AI Context Behavior

- [x] Add `AIRequestBuilder` for feature-specific request construction.
- [x] Expand `AIContextBuilder` for Global Context with selection.
- [x] Expand `AIContextBuilder` for Global Context without selection.
- [x] Expand `AIContextBuilder` for Context Dock frontmost app, menu capabilities, selection, browser URL, and window state.
- [x] Expand `AIContextBuilder` for Finder files and current folder.
- [ ] Expand `AIContextBuilder` for Safari URL and page content.
- [ ] Expand `AIContextBuilder` for Media Dock image, video, audio, and PDF context.
- [x] Keep Global Context AI answer-first and execution-light.
- [x] Keep Context Dock AI app-scoped, capability-aware, approval-gated, and execution-capable.
- [x] Make selected text additive to Context Dock instead of auto-switching scope.
- [x] Keep app menus and capability matching available while selected text exists.
- [x] Add shared `ContextSnapshot` / `ContextCollector` for Global Context and Context Dock.
- [x] Add Context Dock selection AI actions: Explain, Summarize, Rewrite, Translate.

### Capability Planning And Execution

- [x] Add `Capability` model with stable ID, title, app bundle ID, input schema, risk level, and executor.
- [x] Add `CapabilityRegistry`.
- [x] Register Git read-only capabilities: status, diff, log, and branches.
- [x] Register Tailscale read-only capabilities: status and netcheck.
- [x] Register Xcode read-only capabilities: project listing and build-settings inspection.
- [x] Register menu execution, terminal suggestion/execution, Finder reveal/rename plan, Safari summarize-page, and extension capabilities.
- [x] Add `AIActionPlanner` structured capability output.
- [x] Add `AIResponseParser` with strict schema validation.
- [x] Reject invented or unregistered capability IDs.
- [x] Add `ExecutionEngine` for approved capability execution.
- [x] Add result explanation path after execution with raw-output fallback.
- [x] Add AI-suggested command fallback when no registered capability matches.
- [x] Require preview and approval for every suggested command.

### AI Safety And Privacy

- [x] Connect `AISafetyPolicy` assessment to command/capability approval UI.
- [x] Connect Finder file-change risk to selected-file and before/after approval UI.
- [x] Add Finder rename/move/copy/new-folder capabilities with selected-file and before/after approval preview.
- [ ] Add Finder compress/tag capabilities.
- [x] Block destructive commands before execution.
- [x] Add private-data cloud warning before sending selected text, files, contacts, or page content.
- [x] Add AI execution audit history.
- [ ] Add provider-routing privacy settings:
  - Global Context provider
  - Context Dock provider
  - Coding provider
  - Private-data provider
  - Fast-actions provider
- [ ] Add privacy settings:
  - [x] Send selected text to cloud
  - Send Safari page content to cloud
  - Send file contents to cloud
- [ ] Add execution safety settings:
  - Always preview terminal commands
  - Always approve file changes
  - Block destructive commands
  - Show audit history

### AI Provider Settings UX

- [x] Add `/v1/models` discovery for OpenAI-compatible endpoints with manual model-ID fallback.
- [x] Add Test Text action.
- [x] Add Test Vision action.
- [x] Add simulation-only Test Tool Calls action.
- [ ] Show provider capability matrix and Local/Cloud badge.
- [x] Expire capability, terminal-command, and private-cloud approvals after 60 seconds.

### AI Pipeline Target

```text
Global Context / Context Dock / Media Dock / AI Chat / Extensions
  -> AIRequestBuilder
  -> AIContextBuilder
  -> CapabilityRegistry
  -> AIProviderRouter
  -> AIProviderAdapter
  -> AIResponseParser
  -> AISafetyPolicy
  -> ExecutionEngine
  -> ResultRenderer
```

- [ ] [Find] Define `AppFindProfile` routing for app-specific Find/Search behavior.
- [ ] [Find] Extract first-pass Find routing into a declarative `AppFindProfile` service.
- [ ] [Find] Add app-specific Find profiles for Photos, Mail, Notes, Safari, Finder, Preview, TextEdit, Xcode, and VS Code.
- [ ] [Find] Prefer app-native search surfaces when available: Photos search field, Mailbox Search, Notes search, Finder folder search, browser page find.
- [ ] [Find] Fall back to `Edit > Find > Find...`, `Cmd+F`, find pasteboard, and AX search-field injection when no profile exists.
- [ ] [Find] Add manual QA cases for `find [query] in [app]`, `[app] find [query]`, and scoped Context Dock queries.
- [ ] Add debug timing for `scheduleDockPillRebuild`.
- [ ] Add debug timing for `scheduleGlobalGroupedListRebuild`.
- [ ] Add debug timing for `AXMenuReader.refreshAllMenuItems`.
- [ ] Add debug timing for `AppMenuCapabilityCache.menuItems`.
- [ ] Extract duplicate menu loading policy into `MenuLoadService`.
- [ ] Define shared `DockResultListModel` for Global Context and Context Dock rows.
- [ ] Decide whether Global Context should preserve focus across query changes.
- [ ] Add a lightweight in-app debug panel for menu cache age and AX scan duration.

## Release Blockers

- [ ] Complete manual release checklist on a clean app launch.
- [ ] Complete manual release checklist after app has been running for 30 minutes.
- [x] Run Debug and Release builds.
- [ ] Create GitHub release notes from `CHANGELOG.md`.

## Deferred

- [ ] Provider streaming through shared adapter protocol.
- [ ] Provider-specific multimodal optimization after shared attachment behavior is stable.
- [ ] Capability marketplace and third-party capability signing.
- [ ] Automated UI tests for keyboard navigation.
- [ ] Snapshot tests for result list row identity.
- [ ] Automated tests for Find routing once app-specific profiles are extracted.
- [ ] Telemetry export for local performance traces.
