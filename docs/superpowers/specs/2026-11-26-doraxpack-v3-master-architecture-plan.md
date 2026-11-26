# DoraX Pack (`.doraxpack` v3) — Unified Master Architecture Plan

**Date:** 2026-11-26  
**Baseline Commit:** `c09cc07a` (`general-chat-agent`)  
**Status:** Approved Architecture Plan — Ready for Implementation in Fresh Session  
**Canonical Architecture Doc:** `docs/architecture/PLUGINS.md`

> [!IMPORTANT]
> This specification merges the **DoraX Pack v3 engine (`commands[]`, `tools/`, `hooks/`, `$DORAX_CONTEXT`, `dorax.*` sources, Keychain `preferences[]`, stale-while-revalidate caching)** with **Native Swift Core preservation, Web-App URL scoping (`YouTube`, `Linear`, `GitHub`), Dynamic Island Notch Live Activities, Animated Dock Glow, and the `graphify-out` file-search noise fix**.

---

## 1. One Unified Package Format: `.doraxpack` v3

Today DoraX has competing extension paths (`UserGlobalExtension`, Layered `L1–L3`, `PluginManifest`, `.doraxpack` v2, plus loose `SKILL.md` / `AGENT.md`). We unify **all user/store/app extensions** into **one folder/archive format (`.doraxpack`)** run by **one engine**, while keeping DoraX's core macOS boards (`Clipboard`, `Windows`, `Finder` submodes, `OCR`, Notch Page 0 `Music`) ultra-fast in native Swift and exposing their data via `dorax.*` sources.

```text
my-pack/                              (directory on disk; zipped = .doraxpack)
├── pack.json                         1. Identity, scope (apps + web domains), permissions,
│                                        preferences (secrets → Keychain), appearance/glow, commands[]
├── commands/                         2. Scripts for UI commands (list | grid | detail | form | instant | notch | cli)
├── skills/<name>/SKILL.md            3. Multi-step playbooks read by AI & runnable from rows (SkillFolder)
├── AGENT.md                          4. App / Web-App AI persona, tools, never-rules, verify-rules (AppAgentProfile)
├── tools/                            5. Headless AI tools (@pack mentions): scripts, CLI wrappers, MCP server configs
├── hooks/                            6. Reactive event triggers (frontmost-change | url-change | clipboard |
│                                        selection | notification | schedule) — pre-filtered in Swift!
└── page_scripts/                     7. Optional browser DOM readers/actions when a scoped Web-App URL is active
```

Every folder is optional:
- A simple **Global Command / Quicklink** is just `pack.json` (+ 1 script or 0 scripts using `"source": "dorax.*"`).
- A full **App Pack** (`Apple Notes`, `Mail`, `Spotify`) or **Web-App Pack** (`YouTube`, `Linear`, `GitHub`) includes `commands/`, `AGENT.md`, `skills/`, `tools/`, and `hooks/`.

---

## 2. Why `hooks/` Is a Superpower for DoraX (With 3 Strict Guardrails)

Raycast extensions are passive until you open the window or run polling menu-bar scripts. Because DoraX **already** runs native macOS observers (`AXContextReader`, `ClipboardHistoryEngine`, `SelectionScopeModel`, `ILauncherNotificationManager`), adding `hooks/` turns packs into **zero-polling context-aware assistants**:

| Hook Event (`on:`) | Native Pre-Filter in `pack.json` (`<0.05ms` in Swift) | Real DoraX Examples |
|---|---|---|
| **`frontmost-change`** | `"apps": ["com.apple.dt.Xcode", "com.spotify.client"]` | Switch to Xcode → Notch wing shows `⎇ branch · build status`; switch to Notes → subtle warm Gold Dock tint. |
| **`url-change`** | `"domains": ["youtube.com", "github.com", "meet.google.com"]` | Open a YouTube video or Google Meet → Notch quietly offers `● Summarize Video` / `⏱ Meeting Timer`. |
| **`clipboard`** | `"types": ["url", "color", "text"]`, `"regex": "^#[0-9A-Fa-f]{6}$"` | Copy `#A486FF` → Notch shows color chip & `⌘K` stages `Copy as SwiftUI Color`; copy a PR URL → stages `Checkout PR`. |
| **`selection`** | `"fileExtensions": ["pdf", "mov", "png"]`, `"regex": "Traceback"` | Select a `.mov` in Finder or stacktrace in Terminal → injects high-signal Selection Scope actions (`Compress`, `Explain Error`). |
| **`notification`** | `"senderApps": ["com.apple.mail"]`, `"contains": "VIP"` | VIP email or CI failure arrives → triggers crimson/blue **Dock Glow pulse** + actionable Notch banner. |
| **`schedule`** | `"every": "30m"` or `"cron": "0 9 * * 1-5"` | Morning agenda brief in Notch, background `brew outdated` badge, or recurring hydration/focus nudge. |

> [!CAUTION]
> **3 Mandatory Hook Guardrails (So Hooks Never Lag or Spam):**
> 1. **Swift Pre-Filter First:** A hook **must** declare a lightweight filter (`apps`, `domains`, `types`, `regex`, `fileExtensions`). DoraX evaluates the filter in Swift first and **never spawns a subprocess** on unmatched clipboard copies or app switches.
> 2. **Consent + Coalescing + Circuit Breaker:** Hooks require explicit install-time approval (`hook:clipboard`, `hook:frontmost`, etc.), debounce rapid events (`250ms`), enforce a `3s` timeout, auto-disable after 3 consecutive crashes, and can be toggled off per-pack in `⌘K → Configure Pack`.
> 3. **Suggest/Surface Only — Never Silent Destructive Writes:** Hooks may update pack state, show a Notch wing/banner, trigger a Dock glow, or stage a top suggestion; any write/destructive action still requires user confirmation.

---

## 3. Scope Resolution: Native Core, Frontmost Apps & Web Apps (`YouTube`, `Notes`, `Mail`, `Spotify`)

```json
"scope": {
  "surfaces": ["global", "appPet", "selection", "notch"],
  "apps": ["com.apple.Notes"],
  "domains": ["youtube.com", "youtu.be"]
}
```

- **Global Context (`⌥⌥` / `⌘⌘`):**
  1. **When an App or Web-App IS Frontmost:** DoraX checks `frontmost.bundleId` **and** (when a browser/PWA is frontmost) `frontmost.url` via `WebContextEngine`. Matching pack commands + `SKILL.md` workflows rank **first** under **`Contextual — YouTube`** or **`Contextual — Notes`**!
  2. **When in the Background:** Commands with `surfaces` containing `"global"` remain searchable by name/keyword/alias (e.g. typing `"notes"`, `"mail unread"`, `"spotify queue"`, `"youtube"` from Xcode without switching apps).
- **App Pet Focus (`⌥↵`):** Loads that App/Web-App Pack's `AGENT.md` (`tools`, `never`, `verify`), `skills/`, and `tools/` over DoraX's single AI engine.
- **Native Swift Core Stays Native + Feeds `dorax.*` Sources:**
  - `ClipboardBoardCard`, `Windows` layout previews, `Finder` `Space`/`→`/`Extract Text` OCR, and Notch Page 0 `Music` **remain native Swift** for instant 60fps UX.
  - Any pack can read them with **zero scripts** via `"data": { "source": "dorax.clipboard" | "dorax.windows" | "dorax.frontmost.menus" | "dorax.nowPlaying" | "dorax.browser.tabs" | "dorax.files" | "dorax.calendar" | "dorax.notifications" }`, or receive permission-gated **`$DORAX_CONTEXT` JSON on `stdin`**.

---

## 4. Inside the `680 × 440` Result Sheet, Notch & Dock Glow

1. **`pack.json` Multi-Command Schema (`commands[]`):**
   - **Modes:** `list | grid | detail | form | instant | notch | cli | ai`.
   - **Items:** `title`, `subtitle`, `icon` / app icon / swatch, right `accessories` (`text`, colored `tag`, `date`, `progress`, `color`, `avatar`, CPU/RAM metrics), split `detail` (`markdown` with code blocks/tables/images on left + `metadata[]` key-value column on right), and typed `actions[]`.
   - **Consistent Chrome:** Top `<` Back + live filter input + **top-right filter/sort dropdown (`▾`)**; bottom footer with Pack icon + command title on left, **`Primary Action ↵`**, and searchable **`Actions ⌘K`** on right (with per-action shortcuts, **red destructive confirmation**, **`View Pack Logs`**, and **`Configure Command`** for `hotkey`, `alias`, `tint`, `enable/disable`).
   - **Reliability:** Stale-while-revalidate cache (shows last good output while refreshing), strict timeouts, inline error state with **`Retry`**, and Keychain storage for secret `preferences[]`.
   - **AI Chat `@pack` Mentions:** Every pack's `tools/` and read commands can be `@`-mentioned in General Chat / App Pet.
2. **Dynamic Island Notch (`mode: notch` + Hook Output):**
   - Compact camera-bezel wings (`⏱ 12:04`, `● REC 03:21`, `⎇ 2 PRs`) + expanded interactive Notch page (timers, quick record stop/save, notifications, per-app `NotchPinStore` pins).
3. **Dock & Sheet Color, Glow & Fluid Animations (`appearance`):**
   - `appearance: { tint: "#HEX", glow: "none | soft | pulse | breathe | orbit" }` tints and animates the rim around the Dock & `680 × 440` Result Sheet while a pack command, timer, recording, or hook alert is active — with global user intensity/off settings and macOS **Reduce Motion** compliance.

---

## 5. Context-Aware Creation ("Create for `<Frontmost App / Website>`")

Opening **AI Studio** (`Create Extension` or `"Create for <Safari / Notes / YouTube>"` in Global Context) automatically gathers:
- Live frontmost app bundle ID, AX menu tree, scripting dictionary (`sdef`), active browser domain/URL, linked CLI tools & MCP servers, and existing `AGENT.md`.
- Synthesizes the complete `.doraxpack` (`pack.json` + `commands/` + `AGENT.md` + `skills/` + `tools/` + `hooks/`), runs:
  1. **Schema & Diagnostic Check** (`PluginDiagnostic`)
  2. **Read-Only Live Dry Run** rendered directly inside the `680 × 440` sheet
  3. **Permission & Hook Review Card** (context fields read, network hosts, file writes, hooks, UI clicks)
  4. **One-Click Install** (plus starter templates & hot-reloaded folder editing).

---

## 6. Safe Cleanup & Step-by-Step Build Order

1. **Immediate Search Fix (`18% of 450` Screenshot):** Exclude `graphify-out`, `.cache`, `.git`, `.build`, `DerivedData`, `node_modules` and `32+`-char hex-hash cache filenames from Global File Search.
2. **Safe `.zip` Backup & Legacy Cleanup:**
   - Zip and remove legacy user/global clutter (`extensions.json`, Layered `L1–L3` folders, `store-packs`, `Currency`, and disabled `provider:custom` sample commands in `SystemCommands`).
   - **Keep repo `Packs/*.doraxpack`** (`Finder`, `Safari`, `Mail`, `IINA`, `Antigravity`) intact and migrate them cleanly to `.doraxpack` v3 so existing App Pet tests stay 100% green.
3. **Pack v3 Runtime, Context Bridge (`$DORAX_CONTEXT` + `dorax.*`), `List`/`Detail` Renderer & `⌘K` (`Configure Command` + `Logs`):**
   - Install **1 flagship reference pack first** (**Process & Port Monitor** or **Focus Timer & Quick Record**).
4. **Grid, Form, `mode: notch` Live Activities, and `appearance` Dock Color/Glow Engine.**
5. **Frontmost App + Web-App (`domains`) Scope Ranking, `hooks/` Dispatcher (with Swift pre-filters), and `mode: cli`.**
6. **AI Studio `"Create for <App / Web-App>"` v3 Upgrade + Templates + Retire Legacy Code.**
