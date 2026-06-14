# Selection Shortcut Sheet

Selection Shortcut Sheet is DoraX selection-aware action engine.

It appears on long-press Command and shows actions for current selected text, file, URL, image, clipboard, and frontmost app context.

## Not A Launcher

Selection Shortcut Sheet is not Global Context.
It should not become app search, file search, or general chat.

Job:
- Read current selection.
- Match triggers.
- Show relevant actions.
- Run selected action.

## Inputs

Supported inputs:
- Selected text.
- Selected file/folder.
- Selected image.
- Selected URL.
- Browser URL/title.
- Clipboard text/file/URL.
- Frontmost app.
- Current window title.

## Action Sources

Action sources:
- Built-in selection extensions.
- User-created extensions.
- Frontmost app menu actions.
- App adapters.
- macOS Shortcuts.
- AI actions.

## Matching

Rules:
- Match trigger rules in memory.
- Prefer exact app/selection matches.
- Prefer recently used and most-used actions.
- Filter visible results inline while sheet stays stable.
- No live menu scan while filtering.

## Shortcuts

macOS Shortcuts can be linked into the sheet.

Rules:
- Each shortcut must show a scannable icon.
- If macOS does not expose exact private shortcut glyph/color, use stable name-based SF Symbol/color.
- Shortcut actions must pass selected input when applicable.
- Shortcut execution must feel native.

## Extensions

User can paste AI-generated extension JSON.

Rules:
- Import must auto-detect target: Global Context, Context Dock, or Selection Shortcut Sheet.
- Selection-aware actions belong here, not Global Context.
- Built-in extension system should power shortcut sheet actions.

## UI

Rules:
- Opens fast on long-press Command.
- Keeps same sheet identity while results update.
- Supports arrow navigation.
- Supports pointer click.
- Does not steal meaning from Global Context.
