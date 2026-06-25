# Context-Dock

Context-Dock is an open-source native macOS launcher for fast app actions, live context actions, file workflows, and AI-assisted commands.

> Beta: Context-Dock 1.1 beta is an open-source test build. Use it to validate Global Context, Context Dock, Media Dock, General AI Chat, Context Dock Chat, Selection Shortcut Sheet, browser link actions, native window management, and beta updates before stable release.

## DoraX Architecture Truth

Product layers are defined in `docs/architecture/`.

- [Product Layers](docs/architecture/PRODUCT_LAYERS.md)
- [Unified Dock Surface](docs/architecture/UNIFIED_DOCK_SURFACE.md)
- [UI Rules](docs/architecture/UI_RULES.md)
- [Performance Rules](docs/architecture/PERFORMANCE_RULES.md)
- [Selection Shortcut Sheet](docs/architecture/SELECTION_SHORTCUT_SHEET.md)

Core rule: never merge product layers. Global Context, Context Dock, General Chat Mode, Context Dock Chat Mode, Media Dock, and Selection Shortcut Sheet each keep one job.

UI rule: one shell, multiple modes. All floating DoraX surfaces should use Unified Dock Surface Architecture so mode changes swap content inside same stable shell.

## Core Modes

### Global Context

Global Context is a cache-first universal command surface.

- Launch installed apps.
- Search cached menus from running apps while typing.
- Open browser history/bookmark/recent-tab results as real URLs in Safari, with favicon-backed link rows when available.
- Run native window-management actions even for quit, minimized, hidden, or cross-Space apps by launching/activating first, then applying the layout.
- Surface Apple menu commands instantly, excluding volatile Recent Items.
- Search files, workflows, extensions, and settings.
- Verify cached menu commands against live accessibility state before execution.
- Use selected text, URLs, images, or dragged files as optional input.

Global Context never scans accessibility menus while typing. App-switch and idle warmers refresh menu snapshots in background.

### Context Dock

Context Dock follows frontmost app and reads live context.

Selected text is additive context, not a separate mode. Context Dock keeps the
frontmost app, window, menus, and registered capabilities active while exposing
selection-aware AI actions. Global Context uses the same shared context snapshot
but prioritizes universal selection actions.

- Show current app actions and enabled state.
- Read selected text, selected files, browser URL, and window state.
- Execute Window actions using native shortcuts first, then accessibility click fallback.
- Attach Finder current folder for scoped file search.
- Collapse into compact app icon after command execution.

### Media Dock

Media Dock provides media-specific actions for images, video, audio, and PDFs.

## Architecture

```text
App
├─ AppState
├─ AppRouter
├─ DependencyContainer
└─ LauncherShell

Features
├─ GlobalContext
├─ ContextDock
├─ MediaDock
├─ AIChat
└─ Automation

Services
├─ AppMenuCapabilityCache
├─ MenuWarmCacheService
├─ AXMenuReader
├─ AXActionResolver
├─ MenuExecutionCoordinator
├─ FinderActionService
└─ ContextDockStore

AI
├─ AIRequestBuilder
├─ AIContextBuilder
├─ AIProviderRouter
├─ AIProviderAdapter
├─ CapabilityRegistry
├─ AIResponseParser
├─ AIExecutionEngine
├─ AISafetyPolicy
└─ KeychainStore
```

Main behavior rules:

- Global Context typing: persistent cache only.
- Global Context execution: activate app, live-verify, execute, refresh cache.
- Context Dock: frontmost app only, live-first availability.
- Extensions route AI through `ExtensionAIAdapter` and `AIProviderRouter`.
- AI provider API keys are stored in macOS Keychain and legacy UserDefaults keys migrate automatically.
- Launcher, extension, and standard AI requests route through `AIProviderRouter` to provider-specific adapters.
- Shared `AIRequest` carries request source, mode, history, and typed image/file/PDF/URL attachments.
- OpenAI-compatible endpoints support LM Studio, OpenRouter, and local `/v1` servers with configurable endpoint and model ID.
- `AISafetyPolicy` blocks destructive requests and exposes command, file-change, and private-cloud-data risk assessment.
- Context Dock AI requests include live app, bundle ID, window title, selected text/files, browser URL/title, and enabled menu capabilities.
- `ContextCollector` builds one shared snapshot for Global Context and Context Dock, including selection source/count, current directory, menus, and registered capabilities.
- Context Dock selection AI actions route through `AIProviderRouter`; selected text never passively switches Context Dock into Global Context.
- Selected-text cloud sharing can be disabled in AI settings. Local providers remain available.
- Structured action plans validate against `CapabilityRegistry`; unknown capabilities reject before execution.
- Medium/high-risk capabilities require approval. Cloud requests containing private context require explicit send approval.
- AI capability executions persist to `~/Library/Application Support/Context-Dock/ai-audit.json`.
- Provider HTTP/request/response handling lives under `AI/Providers`; `AIProviderService` remains a compatibility facade for legacy rich prompts and tool-loop orchestration.
- Git, Tailscale, and Xcode read-only capability packs use stable registered capability IDs.
- Approved capability output returns through concise AI result explanation, with raw-output fallback.
- OpenAI-compatible settings discover models through `GET /v1/models`; manual model IDs remain supported.
- Tool HTTP routes through provider-specific tool adapters.
- Provider tool definitions, JSON request bodies, iteration loops, and response handling live under `AI/Providers`; `sendWithTools()` remains orchestration facade.
- Finder rename/move/copy/new-folder capabilities require approval and show selected-file/before-after previews.
- Capability, terminal-command, and private-cloud approvals expire after 60 seconds.
- Settings includes text, vision, simulation-only tool-call QA, and compatible model discovery.

## AI Provider Support

Launch-supported sources:

- Apple On-Device Intelligence
- OpenAI API
- Anthropic API
- Gemini API
- OpenRouter
- Ollama
- LM Studio

Generic OpenAI-compatible endpoints are experimental. They support user-managed local gateways and compatibility layers exposing `/v1/chat/completions`.

ChatGPT Plus and Claude Pro are consumer subscriptions, not official third-party APIs. Context-Dock does not provide direct subscription login, read browser cookies, or reuse desktop-app sessions. External subscription-backed bridges may work only when they expose a generic OpenAI-compatible endpoint; Context-Dock does not promise or maintain those bridges.

## Build

Requirements:

- Xcode 16 or newer
- macOS deployment target 26.1
- Accessibility permission for menu automation

```bash
xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock -configuration Debug build
xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock -configuration Release build
```

SwiftTerm resolves through Swift Package Manager automatically.

Project scripts wrap the common local workflows:

```bash
./scripts/build-debug.sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

Codex uses `.codex/environments/environment.toml` to expose a Run action backed by `./script/build_and_run.sh`.

## Install (beta)

Download the latest DMG from [Releases](https://github.com/krishgokulk/Context-Dock/releases), then:

1. Open `Context-Dock-1.1-beta.dmg` and drag **Context Dock** to **Applications**.
2. The beta is **not notarized yet**, so macOS quarantines it. Clear the quarantine flag in Terminal:

   ```bash
   xattr -cr /Applications/Context-Dock.app
   ```

3. Open Context Dock from Applications and grant **Accessibility** permission when macOS prompts.

> The `xattr -cr` step is only needed until the app is signed & notarized. After that, it installs normally.

## Beta Updates

Settings → Updates can check the open-source beta channel, download the latest DMG, and open the installer.

- `Automatic Updates` checks the GitHub-hosted manifest after launch.
- When enabled, new beta builds download automatically and the DMG opens when ready.
- Users can disable automatic updates anytime in Settings → Updates.
- Current manifest: `update-manifest.json`.

Prepare a beta update with:

```bash
./scripts/release-beta.sh
```

This bumps the build number, builds Release, creates and verifies `Context-Dock-1.1-beta.dmg`, updates `update-manifest.json`, then shows the git diff. Add `--commit` to commit the release files, or `--push` to commit and push after the build succeeds.

Or ship everything in one command — bump, build, DMG, push your branch, merge to `main`, and publish a GitHub Release with the DMG attached:

```bash
./scripts/ship.sh        # auto-increment build number
./scripts/ship.sh 9      # explicit build number
```

Run `ship.sh` from a work branch with your code already committed.

## Project Layout

```text
Context-Dock/
├─ App/
├─ Search/
├─ AI/
├─ Accessibility/
├─ Automation/
├─ Services/
└─ UI/
```

`ContentView.swift` stays minimal. Launcher behavior is split across `LauncherView` extensions and feature services.

Architecture milestone:

- Reduced `LauncherView.swift` from 14,948 to 3,234 lines.
- Reduced `LauncherSupportViews.swift` from 4,122 to 91 lines.
- Reduced direct `LauncherView` `@State` storage from 115 to 15 properties.
- Moved launcher, AI session, Context Dock, Global Context, and Finder state into feature ViewModels.
- Split search results, global actions, context actions, previews, notifications, AI providers, and dock actions into focused modules.

## Storage

Menu snapshots and Context Dock rules persist under:

```text
~/Library/Application Support/Context-Dock/
├─ apps/
└─ global/
```

Writes use debounce and content-hash deduplication.
