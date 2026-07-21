# Unified Dock Surface Architecture

Core idea:

One shell.
Multiple modes.
Stable state.
Mode-specific content.

## Problem

DoraX can be fast internally but still feel glitchy if floating UI surfaces use different shells.

Bad behavior:
- Close old panel.
- Open new panel.
- Resize immediately.
- Reload blur/material.
- Rerender everything.
- Lose input focus.

Good behavior:
- Keep same panel.
- Change mode state.
- Crossfade content.
- Preserve input focus.
- Keep material, buttons, spacing, row style, and size rules stable.

## UnifiedDockShell

All floating DoraX surfaces should share one base shell:

```text
UnifiedDockShell
  Header
  Input Bar
  Context Chips
  Content Area
  Footer / Hints
```

Shared shell owns:
- Rounded floating window.
- Native macOS material.
- Same input field position.
- Same close/minimize controls.
- Same row style.
- Same spacing.
- Same animation rules.
- Same light/dark behavior.
- Same focus preservation behavior.
- Same stable size rules.

Modes own only content.

## Mode Content

```text
UnifiedDockShell
  GlobalContextContent
  ContextDockContent
  GeneralChatContent
  ContextDockChatContent
  MediaDockContent
  SelectionShortcutContent
```

## Global Context

Uses Unified Dock Shell.

Content:
- Universal search results.
- Apps.
- Extensions.
- Running app menus.
- Commands.

Rules:
- Same shell as other modes.
- Search content only.
- No chat layout.

## Context Dock

Uses Unified Dock Shell.

Content:
- Frontmost app actions.
- App menu commands.
- App extensions.

Rules:
- Same shell as Global Context.
- App-scoped content only.
- No universal search takeover.

## AI Assistant Mode

Uses Unified Dock Shell.

Content:
- AI messages.
- Visible attachment chips.
- Provider/capability state.
- System-wide capability discovery and execution status.

Rules:
- Chat content only.
- Not Global Context.
- Not Context Dock Chat.

## Context Dock Chat Mode

Uses Unified Dock Shell.

Content:
- Chat with current app.
- Tool/app scope chips.
- Command/action result cards.

Rules:
- App-scoped chat only.
- Show current app/tool scope.

## Media Dock

Uses Unified Dock Shell compact size.

Content:
- Now playing.
- Media actions.
- Timeline/metadata.

Rules:
- Media only.
- No chat surface.
- No universal search.

## Selection Shortcut Sheet

Uses Unified Dock Shell variant.

Content:
- Selected item.
- Recommended actions.
- Matched workflows.
- App actions.
- AI actions.

Rules:
- Selection-aware actions only.
- Not launcher.
- Same shell behavior: stable, focused, consistent.

## Premium Feel Rules

Do before more features:

1. One shell component.
2. One input component.
3. One row component.
4. One animation system.
5. No window recreation for mode changes.
6. Stable size rules.
7. Visible context chips.

## Context Chips

Always show what DoraX is using:
- Frontmost app: Safari, Finder, Xcode, Messages.
- Selection: Selected Image, Selected Text, Finder File.
- Tool scope: Weather, Terminal, Browser, AI profile.
- Media scope: Now Playing, device/source.

## Implementation Rule

Do not build new floating panels with custom visual containers.

Use or evolve `UnifiedDockShell`, then plug mode content inside.
