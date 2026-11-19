# Historical Specs Archive

> [!CAUTION]
> **AI AGENTS AND DEVELOPERS — DO NOT USE THESE FILES AS IMPLEMENTATION GUIDES.**
>
> The specs below are preserved solely for historical provenance. They contain retired terminology
> (`L2Extension`, `SystemCommand`, `.adapterpack`, `.dxagent`, split-brain chat shells, dumping 50
> menu items into prompts) and obsolete patterns that were superseded before or during the
> Unified TurnEngine & .doraxpack v2 track (Tasks U1–U6, October–November 2026).
>
> For the current architecture, consult `docs/architecture/` and `docs/master/`.

## Archived specs

| File | Original Date | Why Retired | Modern Canonical Successor |
|---|---|---|---|
| `2026-08-23-dock-sheet-expansion-design.md` | 2026-08-23 | Superseded by unified Dock shell and detached App Pets architecture | `docs/master/00-DOCK-AND-CORNER.md`, `docs/master/DORAX-BLUEPRINT.md` |
| `2026-08-23-drop-shelf-design.md` | 2026-08-23 | Superseded by Selection Scope / drop action sources | `docs/architecture/CHAT_SCOPES.md`, issue #83 (selection-action-source) |
| `2026-08-26-corner-app-chat-parity-design.md` | 2026-08-26 | Superseded by Task U1 `AppScopedChatService` / `TurnEngine` | `docs/architecture/AI_TURN_LIFECYCLE.md`, PR #474 |
| `2026-08-26-developer-inspector-design.md` | 2026-08-26 | Superseded by modern Developer Inspector (P0 landed in worktree, P1 overlay below) | `docs/superpowers/specs/2026-08-31-developer-inspector-p1-overlay-design.md` → archived alongside |
| `2026-08-31-corner-dual-chat-design.md` | 2026-08-31 | Split-brain dual-chat shell retired; superseded by Task U1 & U2 `ConversationScope` | `docs/architecture/CHAT_SCOPES.md`, PR #474 & #475 |
| `2026-08-31-developer-inspector-p1-overlay-design.md` | 2026-08-31 | P1 overlay design superseded by current Developer Inspector implementation | `docs/architecture/` (developer tooling section) |
| `2026-09-03-corner-ai-chat-shell-design.md` | 2026-09-03 | Old chat-shell design superseded by Task U1 unified shell | `docs/architecture/AI_TURN_LIFECYCLE.md`, PR #474 |
| `2026-09-04-settings-integrations-redesign.md` | 2026-09-04 | Superseded by streamlined settings & extensions design | `docs/superpowers/specs/2026-11-05-streamline-settings-and-extensions.md` |
| `2026-09-15-corner-dock-strip-design.md` | 2026-09-15 | Superseded by Unified Dock Surface spec | `docs/master/UNIFIED_DOCK_SURFACE.md` (via `00-DOCK-AND-CORNER.md`) |
| `2026-09-15-plugins-design.md` | 2026-09-15 | `.adapterpack`/`.dxagent` model retired; superseded by Task U3 `.doraxpack` v2 & `PLUGINS.md` | `docs/architecture/PLUGINS.md`, PR #476 |
| `2026-09-23-surface-cost-and-computer-use.md` | 2026-09-23 | Superseded by `AGENT_REASONING_CONTRACT.md` and `FRONTMOST_AGENT.md` | `docs/architecture/FRONTMOST_AGENT.md` |
