# DoraX UI Rules

UI must make product layer obvious. User should know which surface they are using without reading docs.

All floating DoraX surfaces must use Unified Dock Surface Architecture: one shared shell, one input family, one row family, one animation system, stable size rules, and visible context chips.

## Unified Dock Shell

Shared shell:
- Header.
- Input Bar.
- Context Chips.
- Content Area.
- Footer / Hints.

Mode content changes inside same shell. Window/material/control shell should not be recreated for mode changes.

## Global Context

- Looks like universal search.
- Top results prioritize apps, common commands, and exact query matches.
- Result sheet remains stable while typing.
- No debug badges like `Cached`.
- Avoid technical labels unless user needs decision context.
- Ghost text, match capsule icons, keyboard focus, Enter execution, and visible rows must all read from the same navigation state.
- Down Arrow reveals prepared results; typing updates background rows/icons without resizing or replacing the sheet.
- Enter with a focused row executes that row. Enter with only the render-default first row may execute only when the query is not chat/question-style and the row matches typed text.

## Context Dock

- Looks app-scoped.
- Frontmost app identity must stay visible.
- Results are current app commands/actions.
- Query changes update rows inline, not window/sheet identity.
- Do not show unrelated global actions ahead of app actions.
- App-switch/default rows may execute from Enter only when they are the visible row source; do not rebuild a different pill list during execution.

## Chat Modes

- Chat mode must look like conversation.
- General Chat shows general context and attachments.
- Context Dock Chat shows current app/tool scope.
- Do not make chat look like menu search.
- Do not make launcher behave like chat.

## Media Dock

- Media Dock shows media state first.
- Controls are media controls.
- No general chat controls.
- No global search behavior.

## Selection Shortcut Sheet

- Appears from long-press Command.
- Shows selected content/action matches.
- Not a launcher list.
- Supports text, file, URL, image, clipboard, app menus, extensions, shortcuts, and AI actions.
- Icons must be scannable and consistent.

## Visual Stability

- Do not recreate result sheet per keystroke.
- Keep window identity stable.
- Resize content smoothly.
- Avoid flicker from state resets.
- Avoid layout jumps on backspace.

## Labels

- Use product-level language:
  - Global Context
  - Context Dock
  - General Chat
  - Context Dock Chat
  - Media Dock
  - Selection Shortcut Sheet
- Avoid implementation labels in user UI unless user opens advanced/debug settings.
