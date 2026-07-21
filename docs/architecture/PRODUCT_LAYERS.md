# DoraX Product Layers

This file is architecture truth for DoraX surfaces. Do not merge product layers.

Floating surfaces must follow [Unified Dock Surface Architecture](UNIFIED_DOCK_SURFACE.md): one shell, multiple modes, stable state, mode-specific content.

## Layer Rule

Never merge product layers.

- Global Context is not Chat Mode.
- Context Dock is not Global Context.
- Context Dock Chat Mode is not AI Assistant Mode.
- Selection Shortcut Sheet is not a launcher.
- Media Dock is not a chat surface.

Each surface must keep one job: search, frontmost app actions, general chat, app-scoped chat, media, or selection-aware actions.

## Global Context

Global Context = Universal Search Layer.

Job:
- Search apps.
- Search extensions.
- Search running app menu cache.
- Search universal commands.
- Launch apps and commands fast.

Rules:
- No live AX refresh while typing.
- No menu scan while typing.
- Use cache-first index.
- Verify live state only when needed for execution.
- Rank installed and recent apps high.

## Context Dock

Context Dock = Frontmost App Command Layer.

Job:
- Show current app menus.
- Show current app actions.
- Show app adapters.
- Show app extensions.
- Execute frontmost-app commands.

Rules:
- Scope stays frontmost app.
- Result sheet stays stable while query changes.
- Live menu state may update, but UI must not recreate sheet per keypress.
- App command execution must feel native and instant.

## AI Assistant Mode

AI Assistant Mode = System-wide AI Workflow Layer.

Job:
- System-wide questions, app discovery, and cross-app workflows.
- Conversational fallback when no local capability is relevant.
- Visible attachments.
- Visible context.
- User-controlled provider/profile.

Rules:
- Not launcher.
- Not frontmost-app command sheet.
- Installed apps and adapters inform capability discovery; they do not silently grant access.
- Execution requires a typed route, appropriate approval, and an honest result.
- Context must be explicit and visible.

## Context Dock Chat Mode

Context Dock Chat Mode = Frontmost App Conversation Layer.

Job:
- Chat with current app/tool scope.
- Use frontmost app context.
- Use app-scoped tools/actions when approved.

Rules:
- Not AI Assistant Mode.
- Not Global Context.
- Must show current app/tool scope.

## Media Dock

Media Dock = Media Layer.

Job:
- Show media state.
- Show media actions.
- Control current media.

Rules:
- Not chat surface.
- Not universal search.
- Only media state and media actions.

## Selection Shortcut Sheet

Selection Shortcut Sheet = Selection-Aware Action Engine.

Job:
- Long-press Command.
- Use selected text, file, URL, image, or clipboard.
- Match triggers.
- Show app menu actions.
- Show extensions.
- Show shortcuts.
- Show AI actions.

Rules:
- Not launcher.
- Must be selection-aware.
- Must be fast and stable.
- Must use built-in extension/action system.

## Future Code Organization

Current code has many related files under `Search/`. Long-term target:

```text
Context-Dock/
  GlobalContext/
  ContextDock/
  ChatMode/
  MediaDock/
  SelectionShortcutSheet/
  SharedUI/
  Services/
  AI/
  Accessibility/
```

Do not move everything now unless builds are stable. Save docs and rules first.
