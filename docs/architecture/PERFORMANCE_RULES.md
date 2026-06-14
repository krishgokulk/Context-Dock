# DoraX Performance Rules

Performance goal: Raycast/Spotlight-level typing feel.

Unified Dock Surface rule: mode changes must not recreate floating window. Keep same shell/material/focus and swap mode content inside.

## Typing Path

Typing must update input immediately.

Rules:
- Search text state updates synchronously.
- Heavy work runs after debounce.
- Rebuilds are cancellable.
- New query cancels stale query work.
- No AX refresh while typing.
- No menu scan while typing.
- No full pill rebuild every keypress.

## Global Context

Global Context is cache-first.

Rules:
- Search indexed data while typing.
- Use running app menu cache.
- Exclude noisy global menu items from cache/search:
  - Services
  - Writing Tools
  - AutoFill
  - Start Dictation
  - Emoji & Symbols
  - Apple menu noise
- Live verify only before execution or when idle refresh is safe.
- Rank installed apps and recent apps high.

## Context Dock

Context Dock is frontmost-app live-first, but UI-stable.

Rules:
- Live menu updates can happen after typing path.
- Query filters existing rows inline.
- Result sheet stays mounted.
- Backspace must not collapse sheet to compact mode when valid previous rows exist.
- No sheet recreation per word.

## Selection Shortcut Sheet

Selection Shortcut Sheet must be instant after long-press Command.

Rules:
- Precompute available actions when selection/context changes.
- Filter in memory.
- Avoid live AX scans during user filtering.
- Shortcut/icon metadata must be cached.

## Caching

Rules:
- Cache for speed, not visible UI proof.
- Do not show `Cached` badges in demo/user UI.
- Cache writes must be debounced.
- Use content-hash dedupe for config writes.

## Execution

Rules:
- Close launcher/sheet immediately after accepted action when action launches external UI.
- Activate target app before menu execution if required.
- Prefer native shortcut/menu execution.
- Use AX click fallback only when native path fails.
- Record recent/most-used actions after successful execution.
