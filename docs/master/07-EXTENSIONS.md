# 07 — Extensions (L1 / L2 / L3) and the global extension system

> **Status: DRAFT / under review — written against current code (audit-clean).** Not merged yet.
> Tags: `[code]` verified in source · `[owner]` owner's stated knowledge · `[?]` needs confirmation.

---

## 1. The three-layer extension model

`[code — CLAUDE.md, L2ExtensionManager.swift, BuiltInExtensions.swift]`

| Layer | Trigger | What it is | Where it shows |
|---|---|---|---|
| **L1** | keyword in the search bar | quick actions | Global Context (`01`), Selection Sheet (`05`) |
| **L2** | context (selected files/text, app in focus) | context actions + the AI assistant + custom terminal tools | Context Dock, chat, Selection Sheet |
| **L3** | browser / web context | web-page actions | the Safari Web Extension target |

---

## 2. L1 — keyword quick actions

- **Built-in** (`Services/BuiltInExtensions.swift`): copy, copyPath, fileInfo, getInfo,
  revealInFinder, countWords, summarize, uppercase, lowercase, appInfo, pasteFromClipboard —
  run with no external script. `[code]`
- **User global extensions** (`UserGlobalExtensionStore`, `userext://` ids): user-defined,
  each with its own `searchTerms`; appear in Global Context search. `[code]`

## 3. L2 — context actions, the AI assistant, and custom terminal tools

- **Custom terminal tools** (`AI/L2ExtensionManager.swift`): each extension is a folder under
  `~/Library/Application Support/ILauncher/L2Extensions/` with `extension.json` (metadata +
  parameter schema) + a script (`bash`, `python`, …). **The AI can call them as first-class
  tools alongside `run_command`.** `[code]` This is how a user teaches DoraX a new capability
  without touching the app.
- **CLI/TUI tools** (`TerminalPackageManager`): installed command-line tools registered as
  capabilities (`cliTool` results, `cli://` scopes).
- **The AI assistant** itself lives at L2 (the whole `08` engine).
- **Capability registration** (`AI/AppWorkflowToolCatalog.swift`): registers adapter runners,
  MCP tools, API info, and adapter-pack recommendations into the `CapabilityRegistry`, so L2
  capabilities are discoverable by the engine's `find_capability` / `run_capability`. `[code]`

## 4. L3 — browser / web

- The **Safari Web Extension** is a separate build target
  (`Context-DockExtension`, `com.krishgokul.ContextDock.SafariExtension`). `[code — CLAUDE.md]`
- Web-context actions and page reading (`AXWebReader`, `SafariTabManager`,
  `SafariDeepContextReader`) feed page content to chat and actions.
- `[?]` The exact division of labour between the Safari extension and the AX-based web readers
  needs a dedicated pass — both read web content by different means.

---

## 5. App Adapters vs extensions (clarifying an overlap)

These are **different things** and the docs should keep them apart: `[owner]`
- **Extensions** (this doc) = L1 quick actions / L2 custom tools / L3 web actions the *user or
  app* adds.
- **App Adapters** (`03` §8) = per-app integration bundles (actions + linked MCP/Shortcuts/
  CLI/skills) consumed by scoped chat.
They meet in the `CapabilityRegistry`, which is the single index the engine ranks over (`08`).

---

## 6. Engineering map

| Concern | File |
|---|---|
| L1 built-ins | `Services/BuiltInExtensions.swift` |
| L1 user global ext | `UserGlobalExtensionStore` |
| L2 custom terminal tools | `AI/L2ExtensionManager.swift`, `AI/L2ExtensionUIViews.swift` |
| L2 capability registration | `AI/AppWorkflowToolCatalog.swift`, `AI/CapabilityIndex.swift` |
| CLI tools | `TerminalPackageManager` |
| L3 web reading | `AXWebReader`, `SafariTabManager`, `SafariDeepContextReader` |
| L3 Safari extension | `Context-DockExtension` target |

---

## 7. Known gaps / open questions

1. **L2 custom tools run arbitrary scripts** (`bash`/`python`) as first-class AI tools — this
   is powerful and a **security-review target**: what sandbox/approval applies when the model
   calls a user script? `[risk]`
2. **L3 boundary** — Safari extension vs AX web readers overlap; document who owns what. `[?]`
3. **Discovery/versioning** — how users find, install, update and trust third-party
   extensions/adapter packs is `[?]` (relevant to the plugins plan in `docs/superpowers/`).
4. **No tests** on extension loading/schema validation. `[gap]`

---

*End of draft. Redline directly; merges after owner confirmation.*
