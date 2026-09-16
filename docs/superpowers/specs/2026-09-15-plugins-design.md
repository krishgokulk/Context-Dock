# Plugins — Global Context extension system (design)

Status: proposed, 2026-09-15. Replaces Global Commands (`SystemCommand`, Route A) and
Global Extensions (`UserGlobalExtension`, Route B) with one system. Plan:
`docs/superpowers/plans/2026-09-15-plugins-todo.md`.

## 1. One sentence

A **Plugin** is a user-installable, AI-authorable unit for Global Context: a JSON manifest
that declares *views* rendered natively by DoraX, backed by *scripts* that produce data and
run actions, fed by the *query*, the *selection scope* and the *clipboard scope*.

## 2. Layer placement (architecture truth)

- Global Context searches and launches. Plugins are what it finds and launches. A plugin's
  *views* never converse; the `ai` component is a single-prompt tool. **Conversation with a
  plugin happens in General Chat** (§8b), where the plugin is a named participant on the
  shared harness — the same way an app adapter is.
- Plugins render inside existing surfaces — dock result sheet, corner result panel, dock
  strip, a detached window — through **one renderer**. No new container species
  (`UNIFIED_DOCK_SURFACE.md`).
- Selection-aware plugins surface in the Selection Shortcut Sheet through the existing
  built-in extension route (`SELECTION_SHORTCUT_SHEET.md` — "built-in extension system should
  power shortcut sheet actions"). They stay selection actions there, never search.
- Clipboard-input plugins surface as actions inside the clipboard scope.
- App adapters are **not** plugins. Integrations keeps Apps. Plugins is its own Settings
  section, global only.

## 3. What it replaces

| Today | After |
|---|---|
| `SystemCommand` + `SystemCommandsRegistry` (23 built-ins, user commands) | Plugin manifests; built-ins ship as the **DoraX Essentials** pack |
| `provider:custom` + `refresh:N` + `query:live` rows (`CustomListProviderService`, `ScopedListPanelContent`) | `panel.list` view |
| `UserGlobalExtension` + `UserGlobalExtensionStore` + `ExtensionPanelManager` | deleted; AI composer becomes the `ai` component in a `window` view |
| Settings → Integrations → Global → Commands group | Settings → **Plugins** |
| Add Command / Add Extension sheets | Plugin Creator + Import |

Migration converts every existing user command on first launch, keeps a backup, and never
loses a keyword.

## 4. Concepts

```
Pack  (folder, distributable)
 └─ Plugin  (manifest.json — searchable unit, has keywords, icon)
     ├─ data      one script producing JSON state
     ├─ actions   named scripts / built-ins the views can call
     ├─ inputs    which scopes it wants (query, selection.*, clipboard.*)
     ├─ agent     instructions + skills (SKILL.md) + which actions are tools   (§8b)
     ├─ views     icon | widget | panel | window   (declare any subset)
     ├─ sample    state used by previews before the script is trusted
     └─ permissions
```

A plugin with only `panel.list` and a 10-line script is a complete plugin. So is one with only
an `agent` block and two skills.

## 5. Presentations and hosts

One renderer. The host passes `HostTraits { presentation, widthClass, keyboardOwner, liveBudget }`.

| Host | Presentation | Width class | Rules |
|---|---|---|---|
| Dock result sheet | `panel` | regular | split `list+detail`, grid 4–6 cols, ⏎ / ⌘⏎ / ⌘K |
| Corner result panel | `panel` | compact | split collapses to list, detail via push, grid 2–3 cols, metadata stacks, secondary actions ⌘K only |
| Dock strip (#24) | `icon`, `widget` | slot / family | live budget low while strip is shrunk; max 4 live widgets |
| Detached window | `window` | 360 / 480 / 640 | opened by the row's ▢ or a widget click; shares shell glass, corner radius, animation curves |
| Creator preview | any | any | same renderer, unsaved manifest |

- `icon`: one strip slot, or a two-slot **capsule** (avatar + waveform + label). May be live
  (badge, countdown, pulse).
- `widget`: WidgetKit families `small` 1×1, `medium` 2×1, `large` 2×2. Pinnable in the strip.
- `panel`: Raycast-class, keyboard first. Typing filters it (plugin is the search scope) by
  default; `"scope": false` opts out.
- `window`: full tree; height by content up to 70 % of the screen; scrolls inside.
- Row ▢: opens `window` if declared, else pops the `panel` tree into a centred window unchanged.

Corner size stays a pure function of manifest + traits (memory `corner-pill-size-must-be-pure`);
the renderer reports its height from the tree, never from measurement.

## 6. Component kit

Derived from the owner's board (Live Activities, Raycast list/detail, status chips, forms).

**v1**

| Group | Components |
|---|---|
| Containers | `card`, `vstack`, `hstack`, `grid(columns)`, `section(header)`, `divider`, `footerCard` |
| Header | `header(icon, title, trailing: chip \| status \| menu \| timer)` |
| Text | `title`, `subtitle`, `body`, `caption`, `markdown`, `stat(value, label, delta)` |
| Rows | `row(leading: icon \| thumb \| dot, title, subtitle, accessories, trailing: chip \| time \| chevron \| action)`, `checkRow`, `eventRow(timeRange, durationChip)`, `activityRow(dot, statusWord, relativeTime)`, `fileRow(size, delete)` |
| Panel views | `list(filter: local \| query, sections)`, `listDetail(markdown, metadata)`, `grid`, `detail`, `form(fields, submit)`, `actionPanel`, `emptyState`, `loading` |
| Controls | `button(primary \| pill \| ghost)`, `iconButton`, `buttonRow`, `toggle`, `slider`, `stateButton(states)` |
| Chips | `tag(color)`, `statusBadge(pending \| running \| success \| failed \| expired \| waiting)`, `chipRow(counts)`, `segment` |
| Live | `progress(bar \| dots \| checklist)`, `timer`, `waveform`, `liveText`, `pulse` |
| Media | `mediaCard(art, title, artist, transport, volume)`, `thumbnail`, `avatar` |
| Input | `textField`, `searchField(recents, clearAll)`, `dropzone` |
| AI | `ai(prompt, inputs)` — one prompt, one answer, rendered as `markdown` |

**v2**: `masonry`, `tree` (indented rows), `pager`, `toolbar`, hover-reveal row actions.
**Out**: orbit icon cluster, signature canvas, fanned card stack, node-graph diagram, `webview`.

Every component owns its Liquid Glass styling; a manifest picks and binds, never styles.

## 7. Manifest

```json
{
  "id": "sonos-now-playing",
  "name": "Sonos",
  "icon": "hifispeaker.fill",
  "keywords": ["sonos", "music", "kitchen"],
  "inputs": ["query"],
  "scope": true,
  "data": {
    "type": "bash",
    "script": "data.sh",
    "refresh": { "icon": 30, "widget": 5, "panel": 0, "window": 1 },
    "timeout": 5
  },
  "actions": {
    "toggle": { "type": "bash", "script": "actions/toggle.sh", "optimistic": "playing" },
    "volume": { "type": "bash", "script": "actions/volume.sh", "risk": "low" },
    "openApp": { "type": "open", "app": "Sonos" }
  },
  "permissions": ["network:local"],
  "sample": { "room": "Kitchen +1", "artist": "Casio", "track": "Jungle · For Ever", "playing": true, "queue": [] },
  "views": {
    "icon":   { "capsule": [ { "thumbnail": "{{art}}" }, { "waveform": "{{playing}}" } ] },
    "widget": { "family": "medium",
                "root": { "mediaCard": { "title": "{{room}}", "artist": "{{artist}}", "track": "{{track}}",
                                          "transport": "toggle", "volume": "volume" } } },
    "panel":  { "list": { "filter": "local", "items": "{{queue}}",
                          "row": { "title": "{{item.title}}", "subtitle": "{{item.artist}}",
                                   "actions": [ { "title": "Play", "action": "play", "value": "{{item.id}}" } ] } } },
    "window": { "width": "regular",
                "root": { "vstack": [ { "mediaCard": "…" }, { "section": { "header": "Up next", "rows": "{{queue}}" } } ] } }
  }
}
```

- Binding: `{{key}}` into script JSON; `{{item.*}}` inside repeated rows.
- Data script prints JSON. For `panel.list`, the contract is
  `{ "items": [ { "id", "title", "subtitle", "icon", "accessories": [...], "detail": { "markdown", "metadata": [...] }, "actions": [...] } ] }`.
- Built-in action types: `copy`, `paste`, `open`, `reveal`, `push:<view>`, `shortcut`, plus
  script types `bash`, `applescript`, `jxa`, `scriptFile`, `http` (GET JSON, host declared).
- Schema-validated on load and on every write. Invalid = diagnostics, never a crash or a blank.

## 8. Inputs: query, selection scope, clipboard scope

`inputs` declares what a plugin wants. Satisfied inputs decide **where it appears and how it ranks**.

| Input | Environment the script gets | Surfaces |
|---|---|---|
| `query` | `CD_QUERY` (exists) | search, panel |
| `selection.text` | `CD_TEXT` (exists) | Selection Shortcut Sheet, panel |
| `selection.files` | `CD_FILES` (newline-separated paths) | Selection Shortcut Sheet, panel |
| `selection.url` | `CD_URL` (exists) | Selection Shortcut Sheet, panel |
| `selection.image` | `CD_IMAGE` (path) | Selection Shortcut Sheet |
| `clipboard.text` / `clipboard.files` / `clipboard.image` | `CD_CLIP_TEXT`, `CD_CLIP_FILES`, `CD_CLIP_IMAGE` | clipboard scope actions, panel |
| `clipboard.history` | `CD_CLIP_HISTORY` (JSON path, last N) | clipboard scope |
| row context | `CD_ROW_ID`, `CD_ROW_TITLE`, `CD_ROW` (exist) | actions |
| host | `CD_HOST` (dock \| corner \| strip \| window), `CD_WIDTH` (compact \| regular), `CD_APP` (exists) | all |
| control value | `CD_VALUE` (slider / toggle / form field) | actions |

Rules:
- A plugin whose required input is absent is hidden from that surface; an optional input
  merely lowers its rank. `inputs` entries may carry `?` for optional (`"selection.text?"`).
- Selection plugins go through `SelectionScopeExtensionPolicy`; clipboard plugins through
  `ClipboardScopeService`. Neither surface becomes a launcher.
- `clipboard.history` and `selection.image` are read permissions shown at install.

## 8b. Plugins as agents — skills, tools, General Chat

DoraX already runs **one shared agent harness**: each installed app contributes an adapter
(tools + context readers) and `AdapterSkill`s, assembled per turn into specialist behaviour
(`APP_KNOWLEDGE_SKILLS.md`, `SkillScope`, `ScopedTurnRunner`). A plugin is a **global adapter**
on that same harness. Nothing new is invented; the scope gains a case.

```json
"agent": {
  "instructions": "You are the Sonos assistant. Rooms, queue, volume. Ask before grouping rooms.",
  "skills": ["skills/sonos-api/SKILL.md", "skills/room-etiquette/SKILL.md"],
  "tools": ["toggle", "volume", "play", "openApp"],
  "inputs": ["selection.text?", "clipboard.text?"]
}
```

- `instructions` — the plugin's standing prompt.
- `skills` — folders in **Claude Code `SKILL.md` format** (frontmatter `name`, `description`,
  body, optional `references/`). Users already collect these from the web; they paste or
  import them unchanged. Loaded through `SkillScope` with the existing progressive
  disclosure: unpinned skills cost a name and a summary per turn, pinned ones their body.
- `tools` — the subset of the plugin's `actions` the model may call. Each carries its
  declared `risk`; anything beyond read goes through `AICapabilityApprovalCenter` exactly as an
  adapter action does. This also answers #21: plugin actions *are* adapter actions, so the ask
  agent can reach them.
- Where the user talks to it:
  - **General Chat window** — `@sonos …` or the plugin scope pill. Resolution through
    `GeneralChatScopeResolver` (#19): per step, ask only when two participants answer to the
    same word. A combined chat names every participant it is with (Task 2, done).
  - **Dock / corner input in chat mode** with the plugin scoped — same turn runner, same
    scope. Search mode stays search; the mode toggle is the boundary.
- Providers without native tools (Claude Code, Apple Intelligence) get the skills and
  instructions but no tools — *it answers, the app acts*, as everywhere else in DoraX
  (`CLAUDE.md`, "Diagnosing an AI turn").
- A plugin with an `agent` block and no views is valid: a pure specialist you talk to.
- Skills are user-editable per plugin in Settings → Plugins → *plugin* → Skills
  (`SkillEditorSheet`, add from folder / paste / Git). The plugin's own skills ship in its
  pack; the user's additions live beside it and survive updates.

## 9. Search

- Indexed through `GlobalSearchService.ActionSpec.plugin(id:)`: name, description, keywords.
- `SearchCandidateEligibility` admits plugins; `SearchPresetMerge` keeps **merge and rank**
  (a keyword hit is evidence one row is good, not that others are bad).
- A `panel` plugin becomes the search scope on ⏎ / Tab; the sheet keeps its identity while the
  query changes (no rebuild per keypress).

## 10. Runtime

- One `PluginScriptRunner` replaces `UserExtensionScriptRunner` and the runner inside
  `CustomListProviderService`. Off the main thread; result diffed onto the tree on main.
- Timeouts: icon 2 s, widget 3 s, panel 5 s, action 10 s; a timeout renders `emptyState`
  with the reason.
- Cache per (plugin, query, inputs hash); `filter: local` never re-runs the script on typing.
- Refresh is per presentation; paused when the host is hidden or the strip is shrunk;
  at most 4 live widgets pinned.
- No live AX refresh and no menu scan on the plugin path while typing.

## 11. Security and permissions (plain language)

A plugin is a script that runs as the user. These rules hold for every channel, including the
Creator:

1. The script is always visible: in the Creator, in the install preview, and in the plugin's
   detail view. Nothing generated or downloaded executes silently.
2. In the Creator, **Run test** must be pressed once, with the script on screen, before Save
   is enabled.
3. `permissions` declares what a plugin touches: `network:<host>` / `network:local`,
   `filesystem:read` / `filesystem:write`, `system:power`, `system:process`, `clipboard:history`,
   `selection:image`. Anything beyond read-only prompts on first run through
   `AICapabilityApprovalCenter`, the same gate every other DoraX action uses.
4. Community packs are unsigned. Install preview lists every permission and lets the user open
   every script before anything is written. Verified marks only packs merged into the official
   repo after review. Unverified installs carry a visible "not reviewed" label.
5. Updates are never automatic for unverified packs; the update prompt shows the script diff
   and highlights permission changes. Verified packs may auto-update only if the user opts in.
6. Disable keeps the files and stops every script; Uninstall removes the folder.
7. Declared network hosts are enforced where the runner can (environment allowlist), not only
   displayed.
8. Worker-engine Creator sessions run with their working directory jailed to the pack folder and
   no access to Settings or other packs.
9. Skills are text that steers the model. A skill can never grant a tool, widen a permission,
   or bypass approval: the `tools` list and the approval gate are enforced by the app after the
   model answers, whatever the skill says. A skill imported from the web is shown in full
   before it is saved, and text arriving through skills, page reads or script output is
   treated as untrusted input to the turn, never as instructions from the user.

## 12. Plugin Creator — a mode of the General Chat window

The Creator is **not a separate window**. It is the General Chat window with a *Create plugin*
workspace opened beside the thread — one shell, one input, one thread, mode-specific content
(`UNIFIED_DOCK_SURFACE.md`). Opened from: Settings → Plugins → Add → Create; the strip icon of
the built-in **Plugin Creator** plugin; or `@creator make me a …` in General Chat.

```
┌ General Chat ───────────────────────────── ⟨ Create plugin: Sonos ⟩ ──────────────────────┐
│ thread                          │ PREVIEW [icon][widget][panel·dock][panel·corner][window]  │
│ you: like image 2, kitchen room │ real renderer · real glass · sample → live after Run test │
│ creator: added mediaCard medium │ ⚠ 0 issues  [Run test] [Preview in dock] [Save]           │
│   ● read sonos-cli --help       ├───────────────────────────────────────────────────────────┤
│   ● wrote manifest.json         │ SOURCE  manifest.json │ data.sh │ actions/ │ skills/       │
│ [img][img]  Engine: API ▾       │ (editable, two-way with the thread)                       │
│ > add a volume slider           │                                                           │
└─────────────────────────────────┴───────────────────────────────────────────────────────────┘
```

- **The Creator is itself a plugin** with an `agent` block (§8b): instructions = the DSL
  spec and the kit reference; tools = `writeManifest`, `writeScript`, `validate`, `runTest`
  (gated), `render`; skills = whatever the user adds. Being a plugin is what makes it
  extensible without special code paths.
- **User-added skills for the Creator.** Settings → Plugins → Plugin Creator → Skills. Drop a
  `SKILL.md` folder, paste one, or add a Git URL. Claude Code format, so the references people
  already collect (a vendor's CLI docs, a design-system guide, "how Sonos's API works") plug in
  unchanged. Loaded through `SkillScope` with progressive disclosure, so ten skills cost ten
  summaries, not ten bodies.
- Every manifest write → validate → re-render all five tabs. Sample data until Run test.
- Edit with AI: chat, or click an element in the preview to scope the next prompt to that node.
  Manual edits in Source flow back to the thread's context.
- Preview in dock mounts the unsaved plugin in the real dock / corner / strip as a ghost.
- Every change is a version; undo is picking a version.
- **Engine A — API structured output** (Claude API, vision): one schema-constrained JSON per
  turn, skills injected as system-prompt sections. Ships first; needs no CLI.
- **Engine B — Worker** (Claude Code / Codex CLI inside `TerminalView`, cwd = pack folder,
  the user's Creator skills mounted as its skills directory, image paths in the prompt).
  Writes, tests scripts, iterates; the app file-watches the folder. Lands with the worker
  layer (sequence item 6); this is its first real use.
- The thread is an ordinary General Chat thread scoped to the Creator participant; it shows in
  history like any other, and closing the workspace leaves the thread. What the Creator may
  *do* is bounded by its `tools` and the pack folder, not by which window it is in.

## 13. Packs and distribution

```
sonos-pack/
├── pack.json         id, name, author, version, icon, description, permissions, minAppVersion
├── plugins/
│   ├── now-playing/  manifest.json, data.sh, actions/
│   └── rooms/        manifest.json
├── assets/
└── README.md
```

Channels: **Create** (Creator) · **Local** (folder or `.doraxpack` zip dropped on Settings,
Finder Open With, `dorax://install?path=`) · **Git source** (`dorax-marketplace.json` index in
any repo; pull = update — the Claude Code marketplace model) · **Official directory**
(`krishgokulk/dorax-plugins`, static `index.json`, PRs, Verified after review) ·
`dorax://install?source=…&pack=…` deep link.

Settings → Plugins: tabs **Installed · Discover · Sources**; card = icon, name, author, plugin
count, version, permission badges, Verified, enable toggle; Add ▾ = Create · From folder ·
From Git URL · Browse official. No telemetry at launch: sort by recently added / GitHub stars.

## 14. Migration

1. Built-ins (23 commands today) → **DoraX Essentials** pack, shipped in the bundle, updated
   with the app. Slider/toggle built-ins become `widget.small` + `panel`; list built-ins become
   `panel.list`; one-shot commands become an `actions.run` with no data script.
2. User-created `SystemCommand`s → manifests in `~/Library/Application Support/Context-Dock/plugins/migrated/`,
   original JSON kept beside them. Keywords, icons, undo scripts preserved (`undo` becomes a
   named action).
3. `UserGlobalExtension`s → `window` plugins with the `ai` component when `aiEnabled`.
4. Route A and Route B code deleted only after the migrated set passes the parity tests.

## 15. Non-goals

Raycast extension compatibility · arbitrary code or web views · app-scoped adapters as plugins
· install counts or a hosted store at launch · signing · paid plugins.

## 16. Open decisions (defaults the plan assumes)

| Decision | Default |
|---|---|
| Widget families | `small`, `medium`, `large`; `capsule` is an icon form only |
| ▢ expand | detached window; expand-in-place not in v1 |
| `http` data source | yes, GET JSON only, host must be declared |
| Live widgets in strip | max 4 |
| Panel as search scope | on by default, `"scope": false` opts out |
| Creator engine order | A first, B with the worker layer |
| Official repo | `krishgokulk/dorax-plugins` |
| Verified review at launch | owner review; unverified shown in Discover with label |

## 17. Constraints carried from architecture truth

`PERFORMANCE_RULES.md`, `UI_RULES.md`, `UNIFIED_DOCK_SURFACE.md`, `PRODUCT_LAYERS.md`,
`SELECTION_SHORTCUT_SHEET.md`; corner size purity; #24's strip owns icon/widget hosting;
#22's scope pills must be able to show a plugin scope.
