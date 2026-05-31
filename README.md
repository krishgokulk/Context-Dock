# Context-Dock

Context-Dock is a native macOS launcher for fast app actions, live context actions, file workflows, and AI-assisted commands.

## Core Modes

### Global Context

Global Context is a cache-first universal command surface.

- Launch installed apps.
- Search cached menus from running apps while typing.
- Surface Apple menu commands instantly, excluding volatile Recent Items.
- Search files, workflows, extensions, and settings.
- Verify cached menu commands against live accessibility state before execution.
- Use selected text, URLs, images, or dragged files as optional input.

Global Context never scans accessibility menus while typing. App-switch and idle warmers refresh menu snapshots in background.

### Context Dock

Context Dock follows frontmost app and reads live context.

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
```

Main behavior rules:

- Global Context typing: persistent cache only.
- Global Context execution: activate app, live-verify, execute, refresh cache.
- Context Dock: frontmost app only, live-first availability.
- Extensions route AI through `ExtensionAIAdapter` and `AIProviderRouter`.

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

## Storage

Menu snapshots and Context Dock rules persist under:

```text
~/Library/Application Support/Context-Dock/
├─ apps/
└─ global/
```

Writes use debounce and content-hash deduplication.
