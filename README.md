Context-Dock:
An AI-native macOS productivity dock** — a lightweight, always-visible floating panel that merges a multi-provider AI chat assistant, an embedded terminal, intelligent file management, a Safari browser bridge, and a layered extension system into a single keyboard-accessible panel at the edge of your screen.



Table of Contents

1. [Overview](#overview)
2. [Features](#features)
3. [Architecture](#architecture)
4. [Repository Structure](#repository-structure)
5. [Requirements](#requirements)
6. [Setup & Build Instructions](#setup--build-instructions)
7. [Key Implementation Details](#key-implementation-details)
8. [Current Status](#current-status)
9. [Contributing](#contributing)
10. [License](#license)
11. [Contact](#contact)

 Overview

Context-Dock is a macOS menu-bar/accessory application (`LSUIElement = true`) that provides a draggable, floating command dock. The app automatically detects what the user is doing — which app is in focus, which files are selected in Finder, what text is highlighted, and what page is open in Safari — and uses that context to power AI-assisted actions, automation scripts, terminal commands, and cross-app workflows.

A bundled **Safari Web Extension** (`Context-DockExtension`) enriches the browser integration by streaming rich page context (URL, title, selected text, page text, scroll position) to the main app in real time through a shared App Group and Darwin notifications.

---

## Features

### 🧠 AI Chat Assistant (L2 Layer)
- Chat with **OpenAI** (GPT-4o and others), **Anthropic Claude**, **Google Gemini**, **Ollama** (local), or Apple's on-device **Foundation Models** (macOS 26.0+)
- **Full context awareness**: the active app, selected files/text, and the current Safari page are automatically injected as system-prompt context
- **Streaming responses** with real-time token display
- Inline **code block saving** — AI-generated code snippets can be saved directly from the chat view
- Per-conversation history with context badges per message

### 💻 Embedded Terminal with AI Bridge
- Full interactive terminal using **SwiftTerm** (`LocalProcessTerminalView`) running the user's default shell
- **AI ↔ Terminal bridge** (`TerminalAIBridge`): the AI can propose shell commands; the terminal executes them and streams output back to the AI for iterative workflows
- **Risk classification** (`TerminalCommandClassifier`): commands are categorised by risk level; destructive commands require explicit user approval via a dedicated approval sheet (`CommandApprovalView`)
- **Panel mode** for side-by-side AI + terminal usage

### 📁 AI File Manager
- AI-assisted file creation, editing, deletion, and refactoring with **diff preview** (`FileChangesApprovalView`)
- Selective per-change approval before any disk writes
- Automatic backups before modifications; deletions route to Trash
- Pattern learning from repeated operations to generate reusable templates

### 🌐 Safari Browser Bridge
- A **Manifest V3 Safari Web Extension** (content script + service worker) captures page context on load, navigation, selection, and scroll events
- Context flows: `JS content_script → background.js → sendNativeMessage → SafariWebExtensionHandler.swift → App Group UserDefaults → SafariBrowserBridge → @Published latestContext`
- Cross-process wakeup via **Darwin notifications** (no polling)
- `SafariCommandBridge` provides a three-tier command system — keyword matching (instant, offline), compact AI tags, and direct AppleScript menu invocation — to control Safari (tab management, search, page JS, element scraping)

### 🧩 Layered Extension System
Three runtime layers, each with its own trigger model:

| Layer | Purpose | Trigger |
|-------|---------|---------|
| **L1** (legacy) | File / app search actions | File type or keyword |
| **L2** (main) | Context-aware scripts & AI tools | Active app, selected file type, or keyword |
| **L3** | Browser & web enhancements | URL pattern |
| **Cross** | Multi-app automations | Always |

- Extensions are defined as JSON + a script file (Bash, Python, JXA, AppleScript, or Lua)
- Built-in extensions include Safari tab management, AI summarisation, file compression, translation, and more (`BuiltInExtensions.swift`)
- User-created extensions live in `~/Library/Application Support/ILauncher/L2Extensions/`
- Extension matching uses `IntelligentExtensionMatcher` and `AIShortcutMatcher` for fuzzy/NL-based lookup

### 🔀 Cross-App Router
- Capability-based routing: detects content type (text, URL, file, AX-selected text) and generates contextual **DockPills** for running compatible apps
- Supported targets include Bear, Notion, Obsidian, Apple Notes, Mail, Messages, Telegram, Safari, Chrome, Firefox, VS Code, and more (`CrossAppRouter.swift`)

### 📅 System Data Integration (`L2UnifiedAssistant`)
Natural-language access to:
- **Contacts** — find, get info, compose email, initiate call
- **Calendar** — daily schedule, upcoming events, create events, meeting prep
- **Reminders** — show, create, complete tasks
- **Photos** — find and export photos
- **Files/Finder** — find, organise, and analyse files

### 🐙 GitHub Tool Integration
- Paste a GitHub URL to analyse the repository and install CLI tools directly into the L2 extension layer (`L2GitHubBridge`, `GitHubToolView`)

### 🎵 Mini Player Overlay
- Floating `NSPanel` that appears when a media tool (e.g., `ymc`) is running, with play/pause/next/stop controls (`MiniPlayerOverlay`)

### ⚙️ Settings
- **General**: launcher position, hotkey, appearance, pinned apps/items
- **AI**: provider selection, API key management, model selection
- **Automation**: AppleScript rules, AX trigger rules, browser automation
- **Permissions**: in-app permission grant guide

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                Context-Dock (main app)          │
│                                                 │
│  ┌──────────────┐   ┌────────────────────────┐  │
│  │ ContentView  │   │    AppSettings         │  │
│  │ (main panel) │   │ (@MainActor singleton) │  │
│  └──────┬───────┘   └────────────────────────┘  │
│         │                                       │
│  ┌──────▼──────────────────────────────────┐    │
│  │         L2UnifiedAssistant              │    │
│  │  (Calendar · Contacts · Files · Media)  │    │
│  └──────┬──────────────────────────────────┘    │
│         │                                       │
│  ┌──────▼──────────┐   ┌─────────────────────┐  │
│  │ AIProviderService│   │  TerminalAIBridge   │  │
│  │ OpenAI/Claude/  │   │  (SwiftTerm +        │  │
│  │ Gemini/Ollama/  │◄──►  AI command loop)   │  │
│  │ FoundationModels│   └─────────────────────┘  │
│  └─────────────────┘                            │
│                                                 │
│  ┌──────────────────┐  ┌──────────────────────┐ │
│  │ ContextDetector  │  │  LayeredExtension    │ │
│  │ AXContextReader  │  │  Manager (L1/L2/L3)  │ │
│  │ (AX API + AS)    │  └──────────────────────┘ │
│  └──────────────────┘                           │
│                                                 │
│  ┌──────────────────────────────────────────┐   │
│  │      SafariBrowserBridge                 │   │
│  │  (App Group UserDefaults + Darwin notif) │   │
│  └──────────────────────────────────────────┘   │
└──────────────────────┬──────────────────────────┘
                       │  App Group
          ┌────────────▼────────────────┐
          │  Context-DockExtension      │
          │  (Safari Web Extension)     │
          │  SafariWebExtensionHandler  │
          │  background.js              │
          │  content_script.js          │
          └─────────────────────────────┘
```
Major Modules

| File / Module | Responsibility |
|---|---|
| `ILauncherApp.swift` | App entry point, `KeyableWindow` NSWindow, global hotkey registration, `FocusableHostingView` |
| `ContentView.swift` | Root SwiftUI view — search bar, extension pills, AI chat, terminal panel, context overlay |
| `AIProviderService.swift` | Multi-provider AI chat: streaming, context injection, on-device session caching |
| `ContextDetector.swift` | AX + AppleScript-based context detection (Finder selection, browser URL, clipboard) |
| `AXContextReader.swift` | Accessibility API reader for selected text, focused element, active app |
| `SafariBrowserBridge.swift` | Receives page context from the Safari extension via App Group + Darwin notification |
| `SafariWebExtensionHandler.swift` | (Extension target) NSExtensionRequestHandling — writes native message payloads to UserDefaults |
| `SafariCommandBridge.swift` | Three-tier Safari command execution (keyword → compact tag → AppleScript menu) |
| `L2UnifiedAssistant.swift` | NL intent router for Calendar, Contacts, Files, Photos, Media, Terminal |
| `LayeredExtensionManager.swift` | Loads and manages L1/L2/L3/Cross extension definitions from disk and built-ins |
| `L2ExtensionManager.swift` | User-created script extensions with JSON manifests |
| `TerminalAIBridge.swift` | Bidirectional AI ↔ SwiftTerm communication, approval queue, execution history |
| `L2AIFileManager.swift` | File create/edit/delete with diff preview and per-change approval |
| `CrossAppRouter.swift` | Capability database + content-type routing to installed third-party apps |
| `AppSettings.swift` | `@Published` settings store (hotkey, AI provider, pinned apps, extensions) |
| `ExtensionModels.swift` | Core data models: `ILExtension`, `ExtensionLayer`, `ExtensionTrigger`, `ExtensionTag` |

---

## Repository Structure

```
Context-Dock/
├── Context-Dock/                    ← Main app target (Swift source)
│   ├── ILauncherApp.swift           ← App entry point & window management
│   ├── ContentView.swift            ← Root UI (search, AI, terminal, layers)
│   ├── AppSettings.swift            ← Settings model & persistence
│   ├── UserContext.swift            ← UserContext enum & UserContextDetector
│   ├── ContextDetector.swift        ← AX/AppleScript context detection
│   ├── AXContextReader.swift        ← Accessibility API reader
│   ├── AXTriggerRule*.swift         ← AX-based extension trigger rules
│   ├── AIModeView.swift             ← AI chat SwiftUI view
│   ├── AIProviderService.swift      ← Multi-provider AI service
│   ├── AIResultViewer.swift         ← Response rendering (code, markdown)
│   ├── L2UnifiedAssistant.swift     ← NL intent routing (L2 brain)
│   ├── L2AIFileManager.swift        ← AI-powered file operations
│   ├── L2ExtensionManager.swift     ← User-created script extensions
│   ├── L2ExtensionUIViews.swift     ← Extension UI components
│   ├── L2WorkflowEngine.swift       ← Multi-step workflow executor
│   ├── L2IntentSystem.swift         ← L2ToolIntent enum & resolution
│   ├── LayeredExtensionManager.swift← L1/L2/L3 extension loader
│   ├── ExtensionModels.swift        ← ILExtension, triggers, tags, layers
│   ├── BuiltInExtensions.swift      ← Built-in extension catalogue
│   ├── IntelligentExtensionMatcher.swift ← Fuzzy/NL extension matching
│   ├── TerminalView.swift           ← SwiftTerm view integration
│   ├── TerminalAIBridge.swift       ← AI ↔ terminal command bridge
│   ├── TerminalCommandClassifier.swift ← Risk classification for commands
│   ├── SafariBrowserBridge.swift    ← App Group → @Published page context
│   ├── SafariCommandBridge.swift    ← Three-tier Safari command executor
│   ├── SafariTabManager.swift       ← Tab open/close via AppleScript
│   ├── CrossAppRouter.swift         ← Cross-app content routing
│   ├── L2GitHubBridge.swift         ← GitHub repo analysis & tool install
│   ├── GitHubToolView.swift         ← GitHub tool UI
│   ├── MiniPlayerOverlay.swift      ← Floating media player panel
│   ├── SettingsView.swift           ← Settings UI (General/AI/Automation)
│   ├── AppleAppsAPI.swift           ← AppleScript wrappers for Apple apps
│   ├── MailAutomation.swift         ← Mail automation helpers
│   ├── MessagesAutomation.swift     ← Messages automation helpers
│   ├── ContactSearchManager.swift   ← Contacts framework integration
│   ├── FileIndexManager.swift       ← File index for fast search
│   ├── SafariDeepContextStubs.swift ← Stub: history/bookmarks (removed)
│   ├── OnDeviceStructuredStubs.swift← Stub: @Generable structured output
│   ├── Info.plist                   ← App permissions & URL scheme
│   └── Assets.xcassets              ← App icons & assets
│
├── Context-DockExtension/           ← Safari Web Extension target
│   ├── SafariWebExtensionHandler.swift ← NSExtensionRequestHandling
│   ├── Info.plist                   ← Extension bundle info (min macOS 13.0)
│   ├── Context-DockExtension.entitlements ← App Group entitlement
│   └── Resources/
│       ├── manifest.json            ← MV3 extension manifest
│       ├── background.js            ← Service worker (native message relay)
│       ├── content_script.js        ← Page context collector
│       └── _locales/                ← Localisation strings
│
├── Context-Dock.xcodeproj/          ← Xcode project file
├── Base.lproj/                      ← Base localisation
├── ilauncher-api/                   ← (API helper scripts/configs)
├── uuid-generator.sh                ← UUID generation utility
└── README.md                        ← This file
```


Requirements

| Requirement | Value |
|---|---|
| **macOS** | Main app: check `MACOSX_DEPLOYMENT_TARGET` in Xcode project settings (Safari extension requires **macOS 13.0+**, on-device AI requires **macOS 26.0+**) |
| **Xcode** | 15 or later (Swift 5.9+); Xcode 26+ required to build the on-device Foundation Models integration |
| **Swift** | 5.9+ |
| **Safari** | 15.4+ (required for Manifest V3 Web Extension support) |
| **Apple Developer Account** | Required for code signing and App Group entitlements |
| **AI API Keys** | Optional — OpenAI, Anthropic, or Google Gemini API key if using cloud providers; Ollama installed locally for on-device OSS models |

### Required macOS Permissions (requested at runtime)

- **Accessibility** — detect selected text, focused elements, active app
- **Automation (AppleEvents)** — control Mail, Safari, Finder, Calendar, Reminders, Notes, Messages
- **Contacts** — search address book
- **Calendars** — read/create events
- **Reminders** — read/create tasks
- **Photos** — search and export media
- **Desktop / Documents / Downloads folders** — file management

---

Setup & Build Instructions

1. Clone the repository

```bash
git clone https://github.com/krishgokulk/Context-Dock.git
cd Context-Dock
```

2. Open in Xcode

```bash
open Context-Dock.xcodeproj
```

3. Configure signing & provisioning

1. Select the `Context-Dock` project in the Project Navigator.
2. Under **Signing & Capabilities** for the `Context-Dock` target, choose your Apple Developer Team.
3. Repeat for the `Context-DockExtension` target.
4. Both targets must share the same App Group: **`group.com.krishgokul.ContextDock`** (already configured in entitlements).

**Note:** If you are building for personal use only, "Automatically manage signing" works with a free Apple ID, but App Groups require a paid developer account.

4. Select the scheme and build

- Scheme: **Context-Dock** (builds both the main app and the Safari extension)
- Destination: **My Mac**
- Press **⌘R** to build and run, or **⌘B** to build only

5. Enable the Safari Extension

1. Open **Safari → Settings → Extensions**.
2. Enable **Context Dock**.
3. Grant access to **All Websites** so the content script can collect page context.

6. Add an AI Provider (optional)

1. Open the app and click the **gear icon** to open Settings.
2. Go to the **AI** tab.
3. Select a provider (OpenAI, Claude, Gemini, Ollama) and paste your API key.
4. On-device Foundation Models are available automatically on macOS 26.0+ without an API key.

7. Grant macOS Permissions

Open the **Permissions** settings tab inside the app for guided prompts for Accessibility, Contacts, Calendar, etc. Some permissions (Accessibility, Automation) must be granted in **System Settings → Privacy & Security**.

---

Key Implementation Details

### Safari Extension Data Flow

```
Page event (load / navigate / select / scroll)
  │
  ▼  content_script.js
  → {type: "pageContext", url, title, selectedText, pageText, scrollPercent, …}
  │
  ▼  background.js (service worker)
  → browser.runtime.sendNativeMessage("com.krishgokul.ContextDock", payload)
  │
  ▼  SafariWebExtensionHandler.swift
  → UserDefaults(suiteName: "group.com.krishgokul.ContextDock")
     .set(JSONSerialization data, forKey: "safariExtension.latestPayload")
  → CFNotificationCenterPostNotification (Darwin)
  │
  ▼  SafariBrowserBridge.swift (main app)
  → @Published latestContext: SafariPageContext?
  → All SwiftUI views / AI system prompt updated instantly
```

AX-Based Context Detection

`ContextDetector` and `AXContextReader` use the Accessibility API (`ApplicationServices`) to read the focused element and selected content from the frontmost application without requiring repeated AppleScript Automation permission prompts. AppleScript is only used for Finder file paths and specific Apple app integrations.

Terminal AI Bridge — Approval Loop

1. AI proposes a shell command (via `run_command` tool call in the model response)
2. `TerminalCommandClassifier` assigns a risk level: `.info`, `.safe`, `.moderate`, `.dangerous`
3. Moderate/dangerous commands are held in `TerminalAIBridge.pendingApproval`
4. `CommandApprovalView` shows the command and risk badge; user approves or rejects
5. On approval, the command is injected into the SwiftTerm PTY; output is captured and fed back to the AI

Extension Trigger Rules

`AXTriggerRule` + `AXTriggerRuleEngine` let users define rules that automatically show or execute an extension when a specific accessibility condition is met (e.g., "when VSCode is frontmost and a `.py` file is selected, show the Python tools extension").

On-Device AI (macOS 26.0+)

`AIProviderService` conditionally imports `FoundationModels` and maintains a cached `LanguageModelSession` to avoid repeated session creation overhead. Structured output stubs (`OnDeviceStructuredStubs.swift`) exist where the `@Generable` macro was removed; these return `nil` to allow compilation on earlier OS versions.

---

Current Status

✅ Implemented & Working

- **Floating panel** window (draggable, always-on-top, global hotkey activation)
- **AI chat** with OpenAI / Claude / Gemini / Ollama (streaming, context injection)
- **Safari browser bridge** (JS extension → native handler → real-time context)
- **Safari command control** (tab navigation, open URL, search, AppleScript menu clicks)
- **Embedded SwiftTerm terminal** with AI command bridge and approval flow
- **L2 extension system** (JSON + scripts: bash, Python, JXA, AppleScript, Lua)
- **Built-in extensions**: Safari tab management, AI summarise/translate, file tools
- **AI file manager** (create/edit/delete with diff preview and per-change approval)
- **Cross-app router** (route text/URLs to Bear, Notion, Telegram, Chrome, etc.)
- **System integrations**: Contacts, Calendar, Reminders, Photos (via `L2UnifiedAssistant`)
- **GitHub tool discovery & install** (`L2GitHubBridge`)
- **Mini player overlay** for background media tools
- **Settings UI** (AI provider config, hotkey, pinned apps, layer toggles)
- **AX trigger rules** (auto-show extensions based on accessibility conditions)

❌ Known Gaps

- No automated tests (unit or UI)
- No CI/CD pipeline
- Microphone / voice command input (permission declared, feature not implemented)
- Location-based suggestions (permission declared, feature not implemented)

---

Contributing

Contributions are welcome! Please open an issue to discuss significant changes before submitting a pull request.

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Commit your changes: `git commit -m "Add my feature"`
4. Push: `git push origin feature/my-feature`
5. Open a pull request against `main`

---

License

This project is a personal project owned by [krishgokulk](https://github.com/krishgokulk). Unauthorized use or distribution of the code is strictly prohibited.

---

Contact

- **GitHub**: [@krishgokulk](https://github.com/krishgokulk)
- **Issues**: [github.com/krishgokulk/Context-Dock/issues](https://github.com/krishgokulk/Context-Dock/issues)

---

## Changelog

### 2026-04-25 (4)
- **Auto-exit app scope when scoped app becomes frontmost** — if the user pinned Safari scope via Tab and then switches to Safari, the explicit scope dissolves automatically (search text cleared, `l2TargetApp` nil'd); the dock resumes normal frontmost-app mode without requiring "Exit Scope"
- **"play X from this page" → page JS click** — `parseIntent` now handles `play / watch / open video` prefixes the same as `click`, stripping "from this page / on this page" context phrases; the matching element is scrolled into view and clicked (works on-device and offline, no AI call)
- **Safari command pill for "play"** — pill shows with `play.circle` icon when query starts with "play" or "watch"

### 2026-04-25 (3)
- **Safari "click X" / "search X" / "open X" commands** — `parseIntent()` now handles:
  - `click <text>` / `tap <text>` — injects page JS that finds and clicks any element (link, button, or text node) matching the visible text, with `scrollIntoView` first
  - `search <query>` (bare, no "in new tab" required) — opens a new tab and searches Google/YouTube/Amazon depending on context
  - `search <query> in new tab` — fixed: previously the `new tab` menuMap alias stole these queries before the search logic ran
  - `open <name>` — if single-word with a dot, navigates to URL; otherwise searches on Google
  - `go to <url or name>` — same URL-vs-search logic
- **Safari excluded from MenuIntentRouter** — `menuRouteEligible` now skips menu routing when Safari is frontmost; Safari uses its own three-tier command system instead of the generic menu cache
- **TERMINAL_COMMAND guard** — Safari compact system prompt now explicitly forbids `[TERMINAL_COMMAND]` and `[EXECUTE_COMMAND]` tags when Safari is frontmost
- **safariMenuMap expanded** — added missing Window menu items: Minimise, Zoom, Fill, Centre, Bring All to Front, Mute Other Tabs; added "switch previous tab" / "back tab" aliases to Show Previous Tab
- **Safari command pills** — `buildSafariCommandPills(query:)` now generates DockPill entries for page-level Safari commands (search, click, open, highlight, extract prices) as the user types, so they appear as pills in the suggestion row just like app menu items do; menu items are excluded from this path to avoid duplicates with the AX pill system

### 2026-04-25 (2)
- **PDF global context fix** — "explain about this file" and other content questions on a selected PDF now read the document and answer directly; previously the AI emitted a `[TERMINAL_COMMAND:]` tag instead of answering from content. Fast-path now covers: explain, describe, what is, tell me about, this file, translate, analyze, overview, key points, highlight, summarize

### 2026-04-25
- **SafariDeepContextReader** — implemented: reads Safari browsing history via AppleScript, ranks entries by query relevance, injects matched history into AI context block
- **generateMailIntent** — implemented: keyword-based mail query classifier (detects subject/from/to/attachment/date token kinds, strips filler words, identifies questions vs searches); works without Apple Intelligence
- **ContextAppSuggestionsRow** — implemented: real scrollable chip row showing "Open With" app icons (via `DefaultAppResolver`) and relevant extension chips (via `IntelligentExtensionMatcher`); auto-refreshes when context changes
- **MenuIntentRouter** — new: routes natural language → frontmost app's cached menus → click, with on-device AI disambiguation fallback (tiny ~20-token prompt, no cloud needed)
- **SafariCommandBridge** — extended: menu-click tier via AppleScript `System Events`, NL alias table covering all File/Window menu actions, compact system prompt for cloud AI only
- **Global context routing** — fixed: text/file/folder selections now always activate global context before menu routing; `hasActiveSelection` checked independently of dock scope
- **Git repository** — initialized; LICENSE (all rights reserved) added
- **Backup files removed**: `ContentView.swift.backup`, `ContentView.swift.bak2`, `SettingsView.swift.bak`
- **Bug fixes**: `ArraySlice +` concatenation replaced with `Array(slice) + Array(slice)`; `ScriptExtension.icon` corrected to `ScriptExtension.type.icon`
