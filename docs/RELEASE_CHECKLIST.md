# Release Checklist

Use this checklist before every public or shared build.

## Build

- [ ] Debug build passes:
  `xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock -configuration Debug CODE_SIGNING_ALLOWED=NO build`
- [ ] Release build passes:
  `xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock -configuration Release CODE_SIGNING_ALLOWED=NO build`
- [ ] SwiftPM dependencies resolve without network surprises.
- [ ] No unrelated files in `git status`.

## Global Context

- [ ] Empty Global Context shows correct frontmost app pill.
- [ ] Typing 1-2 letters does not flood app/recent document results.
- [ ] Typing 3+ letters shows expected app results.
- [ ] Apple Menu commands appear in Global Context.
- [ ] Apple Menu recent applications/documents are fresh after app switch.
- [ ] Global Context app/menu rows do not jump to top while typing.
- [ ] Keyboard navigation keeps the focused row visible.
- [ ] Return executes the focused app/menu command.
- [ ] Escape clears focus before closing the dock.

## Context Dock

- [ ] Context Dock pill shows only the frontmost app icon/name.
- [ ] Context Dock result sheet does not jump to top while typing.
- [ ] Frontmost app menu commands appear and execute.
- [ ] `find [query]` in scoped app opens the correct app-native Find/Search surface.
- [ ] App switch refreshes menu commands for the new app.
- [ ] Finder selection actions appear when files/folders are selected.
- [ ] Safari commands appear with page/tab context.
- [ ] Xcode/Code/Terminal commands appear without visible lag.
- [ ] Keyboard navigation and Return execution work.

## Cache And AX

- [ ] Apple Menu items are not persisted as per-app capabilities.
- [ ] Recent Items/Open Recent branches are not persisted unless explicitly allowed for browser history/bookmarks.
- [ ] AX menu scan failure falls back to snapshot/cache.
- [ ] App switch does not trigger repeated concurrent AX scans.
- [ ] Menu commands still execute after app relaunch.

## Manual Regression Pass

- [ ] Finder
- [ ] Safari
- [ ] Xcode
- [ ] Visual Studio Code
- [ ] Terminal
- [ ] System Settings
- [ ] Photos Find/Search
- [ ] Notes Find/Search
- [ ] Mail Mailbox Search and message-local Find
- [ ] Messages/Mail if installed and signed in

## Release Notes

- [ ] `CHANGELOG.md` updated.
- [ ] `docs/ENGINEERING_TODO.md` updated.
- [ ] New decisions added to `docs/DECISIONS.md`.
- [ ] GitHub issue/PR linked to commit.
