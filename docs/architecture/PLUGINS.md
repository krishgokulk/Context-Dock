# Plugins and `.doraxpack` v2 Packs

Architecture truth for the unified DoraX extension, App Pet, Web-App, and CLI pack system (updated
2026-11-26). Original design (archived): `docs/history/specs/2026-09-15-plugins-design.md`. Current
specifications:
- `docs/superpowers/specs/2026-11-05-streamline-settings-and-extensions.md`
- `docs/superpowers/specs/2026-11-26-doraxpack-v3-master-architecture-plan.md` (`.doraxpack` v3 Unified
  Master Architecture Plan: `commands[]`, `tools/`, `hooks/` with Swift pre-filters, `$DORAX_CONTEXT`,
  `dorax.*` sources, Keychain `preferences[]`, Web-App `domains`, Dynamic Notch Live Activities, and
  Animated Dock/Sheet Glow)

## Native Core vs. `.doraxpack` v2 Boundary

DoraX owns core macOS surfaces natively (`Clipboard`, `Windows`, `Finder` file submodes & Vision OCR,
`MediaPlayerObserver` Now Playing in Notch Page 0, `Quick Note`, `Drop Shelf` in Notch Page 1,
`Inline Calculator / Units / Dates / World Clock`, `Emoji & Symbols`, and core hardware toggles
`Wi-Fi` / `Bluetooth` / `Volume` / `Keep Awake`). Packs extend DoraX with **Global dashboards**,
**App integrations** (`Notes`, `Mail`, `Spotify`), **Web-App integrations** (`YouTube`, `Linear`,
`GitHub`), and **CLI wrappers** (`brew`, `docker`, `gh`) without duplicating native primitives.

## What a plugin / pack is (`.doraxpack` v2)

A **`.doraxpack` v2** folder (`Services/Plugins/DoraxPackV2.swift`) is the **single canonical package
format** in DoraX across all three scopes — **Global** (`target_app` omitted or `"global"`), **App**
(`target_app.bundle_id` set), and **Web-App** (`web_domains` / `extension_hooks` URL patterns):

```text
<pack-id>.doraxpack/
├── pack.json              # Manifest: metadata, target_app, permissions, capabilities, cli_tools, utcp_endpoints, mcp_servers, extension_hooks, data, actions, views
├── AGENT.md               # App Pet constitution: route priorities, behavioral rules, NEVER rules
├── modes.json             # Optional /mods presets (loaded into AppPetManifestRegistry)
├── skills/
│   └── <skill-name>/
│       └── SKILL.md       # Claude Code-compatible SKILL.md (frontmatter + procedural know-how)
├── scripts/
│   └── <helper>.py|.sh    # Inspectable helper scripts (arrive chmod 0644 until owner approves)
└── page_scripts/          # Optional JS snippets executed via Context-DockExtension bridge
    └── <hook>.js
```

In `pack.json`, a pack declares any subset of:

- `target_app` — `{ "bundle_id": "<bundleId>", "name": "<AppName>" }` for an App pack, `web_domains` (e.g. `["youtube.com", "youtu.be"]`) for a Web-App pack, or omitted / `"global"` for Global Context. When the matching App or Web-App URL is frontmost, Global Context automatically elevates the pack's commands and skills under `Contextual — <Name>`; when in the background, its commands remain searchable globally by name/keyword.
- `capabilities` & `actions` — named tools (`scriptFile`, `cli`, `applescript`, `jxa`, `menubar`, `urlScheme`, `shortcut`, `http`, Notch hooks `notch.notify` / `notch.wing` / `notch.timer` / `notch.record`, or built-ins `copy`, `open`, `reveal`, `paste`, `push:<view>`, `set`), each with a declared `safety` / `risk`, optional shortcut, and optional `sandbox` (`container` micro-VM, PR #481).
- `cli_tools` — embedded (`.app/Contents/MacOS/<binary>`) or PATH CLI binaries executed strictly as **argv, never a shell string**.
- `utcp_endpoints` — zero-daemon OpenAPI / UTCP HTTP endpoints executed directly by `UTCPDirectExecutor`.
- `mcp_servers` — lazy `stdio` MCP servers linked to `target_app.bundle_id` (e.g. `/usr/bin/safaridriver --mcp`).
- `extension_hooks` — declarative browser/app extension scripts (`page_scripts/*.js`) with `url_matches`, `exclude_sensitive_urls`, and `safety`, registered in `ExtensionHookRegistry` (`Services/SafariExtensionHookRegistry.swift`, PR #478) and executed by `Context-DockExtension`.
- `views` & `data` — any subset of `icon`, `widget`, `panel` (full `680×440` Result Sheet with `<` Back, top-right filter/mode dropdown, colored row tags, metric accessories, Split Markdown + Right Metadata Sidebar, Visual Swatch Grids, Forms, Gauges, and searchable `⌘K` Actions popover), `window`, and `notch` (`PluginNotchView`: `wing` 44×32 pt badge + `page` 314×96 pt strip + live timer/recording hooks in the Dynamic Island Notch, PR #480).
- `style` — optional accent `#HEX` color and Dock / Result Sheet glow animation (`off`, `ambient`, `pulse`, `orbit`, `burst`) rendered via `DockAuraEngine`.
- `inputs` — `query`, `selection.*`, `clipboard.*`; satisfied inputs decide where it appears.
- `agent` — references `AGENT.md`, `modes.json`, `skills/*/SKILL.md`, and `tools` ⊆ capabilities/actions.
- `permissions` — declared, shown at install, gated at first run.

## First-Party Dogfooded `.doraxpack` v2 Bundles (`Packs/`)

Shipped in `Packs/` and loaded on startup via `FirstPartyPacks.swift` (PR #476):
- `Packs/Finder.doraxpack`
- `Packs/Safari.doraxpack` (with `page_scripts/extract-article-and-links.js`, PR #478)
- `Packs/Mail.doraxpack`
- `Packs/IINA.doraxpack`
- `Packs/Antigravity.doraxpack`

## Atomic Binding Contract (`StorePackInstaller.installV2`)

Installing or saving a `.doraxpack` binds every resource atomically into existing stores without
creating a new registry (`StorePackInstaller.swift`, completed in Task U8c):

1. `pack.json` → `PluginRegistry` (views, search keywords, widgets, notch views) + `CapabilityRegistry` (via `PluginCapability.make`).
2. `capabilities` / `actions` → `AppAdapterManager` (when `target_app` is an app) or `SystemCommandsRegistry` (when global).
3. `cli_tools` → `TerminalPackageManager` (linked to `target_app.bundle_id`).
4. `utcp_endpoints` → `APIConnectionStore` & `UTCPToolBridge`.
5. `mcp_servers` → `MCPServerManager` (scoped to `target_app.bundle_id`).
6. `skills/*/SKILL.md` → `SkillStore` (scoped to `target_app.bundle_id` or `generalChat`).
7. `AGENT.md` → `AppAgentProfileStore` (merged cleanly, preserving user edits).
8. `modes.json` → `AppPetManifestRegistry` (powers `/mods`).
9. `extension_hooks` → `ExtensionHookRegistry` + `CapabilityRegistry` (hot-loaded by `Context-DockExtension`).

## Rules

- **Global Context stays search.** A plugin is something Global Context finds and launches;
  typing filters a `panel` plugin, it never converses. Conversation with a plugin happens in
  General Chat or in the dock / corner **chat mode**.
- **One renderer, many hosts.** `PluginRenderer` takes `HostTraits` (presentation, width
  class, keyboard owner, live budget). Dock sheet, corner panel, dock strip, Dynamic Island Notch,
  detached window and the Creator preview all render the same tree. No host may fork a component.
- **Corner size is pure.** A plugin's height in the corner is a function of manifest + traits.
  Never measured.
- **Plugins are adapters on the shared harness.** Their `tools` register in `CapabilityRegistry`
  and `AppAdapterManager`; their skills go through `SkillScope`; approval goes through
  `AICapabilityApprovalCenter`. No second agent system.
- **Skills steer, never grant.** `tools` and approval are enforced after the model answers.
- **Scripts are visible, dry-run tested and gated.** Shown in the Creator, the `OwnerReviewCard`
  (`AgenticAIPackBuilder.swift`, PR #477) and the detail view. Scripts arrive non-executable (`0644`)
  until approved. Anything beyond read prompts on first run.
- **Extensions in Settings (#373 / PR #374):** Consolidated under `Settings ▸ Extensions` with
  two rows: `Apps` (per-app adapters, capabilities, `AGENT.md`, and permissions) and `Store / Packs`
  (with `[+ Create Pack]` / `✨ Build Pack with AI` powered by `AgenticAIPackBuilder`).
- **The Creator is a 4-stage agentic pack authoring mode** (`AgenticAIPackBuilder`), not a separate window.

## Code homes

```
Packs/                5 first-party dogfooded .doraxpack v2 bundles (Finder, Safari, Mail, IINA, Antigravity)
Services/Plugins/     DoraxPackV2, FirstPartyPacks, StorePackInstaller, manifest, schema, registry, migration, runner
Services/             SafariExtensionHookRegistry, SafariEscalationPolicy, NotchPinStore
UI/Plugins/           renderer, HostTraits (incl. notchWing/notchPage), sizing, components/, window, creator workspace
UI/                   NotchQuickActionsView, DynamicNotchLiveActivityView
AI/PluginAuthoring/   AgenticAIPackBuilder, AIPackSynthesizer, PluginAuthoringEngine, PluginAuthoringPrompt
```
