<div align="center">

# Context-Dock

**A native macOS launcher that adapts to whatever you're doing.**

App actions, live frontmost-app context, file workflows, media controls, and AI commands — in one fast, unified dock.

![macOS 26.1+](https://img.shields.io/badge/macOS-26.1%2B-black?logo=apple)
![Swift 5](https://img.shields.io/badge/Swift-5-orange?logo=swift)
![Beta](https://img.shields.io/badge/status-beta-blue)

[Install](#install) · [Modes](#modes) · [App Adapters](#app-adapters) · [AI Providers](#ai-providers) · [Build](#build)

</div>

---

## What it is

Context-Dock (DoraX) is one floating shell with multiple modes. The dock swaps content for what you're doing — searching apps, acting on the frontmost app, controlling media, or chatting with AI — without ever becoming a different window.

**Core rule:** never merge product layers. Global Context, Context Dock, Media Dock, General Chat, Context Dock Chat, and the Selection Shortcut Sheet each keep one job. See [`docs/architecture/`](docs/architecture/).

## Modes

| Mode | Job |
|---|---|
| **Global Context** | Cache-first universal search — launch apps, run cached app commands, open browser history/bookmarks as real URLs, native window management across Spaces. Never scans menus while typing. |
| **Context Dock** | Follows the frontmost app — live app actions, selected text/files, browser URL, window state. Selected text is additive context, not a separate mode. |
| **Media Dock** | Now-Playing controls for whatever is playing — artwork, scrubber, transport. |
| **AI Chat** | General and app-scoped chat. Scoped chat carries live app/window/selection context. |

## App Adapters

App Adapters are **plugins** — install full app support (actions, shortcuts, CLI tools, MCP servers) in one shot.

- **Import Adapter Packs** — `.adapterpack` folder, `.zip`, or `.json` (`adapter.json` metadata + `actions.json`). Parsed once into an in-memory index; the dock never re-parses JSON while typing.
- **Plugin detail** — Overview · Actions · Shortcuts · CLI Tools · MCP, each its own page.
- **Add Action** — intent-grouped types (Open URL / Deep Link, Run Shortcut, AI Prompt, Menu Item, AppleScript, Terminal Command…) with risk badges and approval for high-risk actions.
- Packs install to `~/Library/Application Support/DoraX/AppAdapters/`. No restart.

## AI Providers

| Supported | Notes |
|---|---|
| Apple On-Device Intelligence | Runs locally, offline |
| OpenAI · Anthropic · Gemini | API key (stored in Keychain) |
| Ollama · LM Studio · OpenRouter | Local / self-hosted |
| **Shortcuts** | Route prompts through a macOS Shortcut — use any provider it can reach |
| OpenAI-compatible `/v1` | Experimental — user-managed gateways |

API keys live in the macOS Keychain. Cloud requests with private context require explicit send approval; high-risk capabilities require approval and expire after 60s.

## Install

Download the latest DMG from [**Releases**](https://github.com/krishgokulk/Context-Dock/releases).

1. Open the DMG, drag **Context Dock** to **Applications**.
2. The beta isn't notarized yet, so clear the quarantine flag:
   ```bash
   xattr -cr /Applications/Context-Dock.app
   ```
3. Launch it and grant **Accessibility** when prompted.

> The `xattr` step is only needed until the app is signed & notarized.

**Updates:** Settings → Updates checks the beta channel and can auto-download new builds. Manifest: [`update-manifest.json`](update-manifest.json).

## Build

Requires **Xcode 16+**, macOS deployment target **26.1**.

```bash
xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock -configuration Debug build
```

SwiftTerm resolves via SPM automatically. Ship a beta in one command (bump → build → DMG → push → GitHub Release):

```bash
./scripts/ship.sh        # auto-increment build number
./scripts/ship.sh 9      # explicit build number
```

## Architecture

```
App/            Entry point, window, hotkeys, settings
Search/         Launcher UI, search engine, dock surfaces
AI/             Provider routing, context building, execution, safety
Accessibility/  AX menu reading, context snapshots, event bus
Automation/     Cross-app routing, app adapters, share intents
Services/       Context, media, files, adapters, infrastructure
UI/             Reusable components, settings pages
```

- **Global Context** searches a persistent cache; execution activates the app, live-verifies, runs, then refreshes the cache.
- **Context Dock** is frontmost-app, live-first.
- All AI routes through `AIProviderRouter` to provider adapters; `AISafetyPolicy` gates destructive/cloud-private requests.

Truth files: [Product Layers](docs/architecture/PRODUCT_LAYERS.md) · [Unified Dock Surface](docs/architecture/UNIFIED_DOCK_SURFACE.md) · [UI Rules](docs/architecture/UI_RULES.md) · [Performance Rules](docs/architecture/PERFORMANCE_RULES.md).

## Storage

```
~/Library/Application Support/Context-Dock/   # menu snapshots, dock rules (debounced, hash-deduped)
~/Library/Application Support/DoraX/AppAdapters/   # imported adapter packs
```

## License

© 2025–2026 Krishgokul. All rights reserved. See [`LICENSE`](LICENSE).
