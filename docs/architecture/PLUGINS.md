# Plugins

Architecture truth for the Global Context extension system. Design and reasoning:
`docs/superpowers/specs/2026-09-15-plugins-design.md`. Roadmap:
`docs/superpowers/plans/2026-09-15-plugins-todo.md`. Brain issue #26.

## What a plugin is

A **Plugin** is a JSON manifest in a **Pack** folder. It declares:

- `views` — any subset of `icon`, `widget`, `panel`, `window`, as trees over a fixed native
  component kit. The manifest picks and binds; it never styles.
- `data` — one script (`bash` / `applescript` / `jxa` / `scriptFile` / `shortcut` / `http`)
  whose output (`json` / `jsonl` / `lines` / `raw`) becomes the state the views bind to.
- `actions` — named scripts or built-ins (`copy`, `open`, `reveal`, `paste`, `push:<view>`,
  `shortcut`) the views and the agent may call, each with a declared `risk`.
- `inputs` — `query`, `selection.*`, `clipboard.*`; satisfied inputs decide where it appears.
- `agent` — optional: `instructions`, `SKILL.md` skills, `tools` ⊆ actions. Makes the plugin a
  participant in General Chat on the shared harness.
- `permissions` — declared, shown at install, gated at first run.

## Rules

- **Global Context stays search.** A plugin is something Global Context finds and launches;
  typing filters a `panel` plugin, it never converses. Conversation with a plugin happens in
  General Chat or in the dock / corner **chat mode**.
- **One renderer, many hosts.** `PluginRenderer` takes `HostTraits` (presentation, width
  class, keyboard owner, live budget). Dock sheet, corner panel, dock strip, detached window and
  the Creator preview all render the same tree. No host may fork a component.
- **Corner size is pure.** A plugin's height in the corner is a function of manifest + traits.
  Never measured.
- **Plugins are global adapters.** Their `tools` are adapter actions; their skills go through
  `SkillScope`; approval goes through `AICapabilityApprovalCenter`. No second agent system.
- **Skills steer, never grant.** `tools` and approval are enforced after the model answers.
- **Scripts are visible and gated.** Shown in the Creator, the install preview and the detail
  view. In the Creator, Run test precedes Save. Anything beyond read prompts on first run.
- **Plugins is its own Settings section.** Integrations keeps app adapters. Packs carry plugins
  only.
- **The Creator is a plugin** and a mode of the General Chat window, not a separate window.

## What it replaces

`SystemCommand` / `SystemCommandsRegistry` (Route A), `provider:custom` rows
(`CustomListProviderService`, `ScopedListPanelContent`), and `UserGlobalExtension` /
`UserGlobalExtensionStore` / `ExtensionPanelManager` (Route B). Both routes are retired only
after the migrated set passes parity tests (plan Phase 8).

## Code homes

```
Services/Plugins/     manifest, schema, pack, registry, migration, runner, environment, permissions
UI/Plugins/           renderer, HostTraits, sizing, components/, window, creator workspace
AI/PluginAuthoring/   creator engines and the authoring prompt
```
