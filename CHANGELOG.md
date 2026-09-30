# Changelog

All notable changes to Context-Dock are tracked here.

## 1.1 - Beta

### Changed

- Result cards no longer list cache and system files from `~/Library`, `/Library`, `/System` and `/private` that a search passed through; iCloud Drive files and files the answer names still show.
- File search now works with Spotlight off: `find_files` tries Spotlight, then scans Desktop, Documents, Downloads and iCloud Drive, for the in-app agent, the Finder pack and the DoraX MCP server.
- Improved Global Context app-scope ranking so apps, useful menus, and recent menu use surface first.
- Stabilized Context Dock result sheet sizing and row identity while typing.
- Polished settings navigation, AI providers, extension import, and shortcut sheet flows.
- Added AI profiles and provider routing for beta testing.
- Improved native menu execution for quit, stop, open-with, and frontmost-app actions.

### Beta Notes

- DMG build is ready for user testing.
- App is not notarized unless built with a Developer ID signing identity.

## Unreleased

### Added

- General Chat can read your Global Commands' current state ("is Bluetooth on?") without an approval prompt; commands are grouped into System packs (Bluetooth, Wi-Fi, Sound, Appearance, …).
- General Chat can write a .md, .txt, .csv or .docx for you into ~/Documents/DoraX Outputs (never overwrites; you approve each file) and shows it as a card; also `dorax_write_output_file` for the DoraX MCP server.
- General Chat can list your Shortcuts and run one by exact name (you approve each run and see the name and input; never run unattended); also `dorax_list_shortcuts` / `dorax_run_shortcut` for the DoraX MCP server.
- Files a chat answer names — in any chat, any provider — appear as cards under it with Quick Look, Open, Reveal in Finder and drag out.

### Fixed

- An everyday phrase that happens to be an app name no longer hijacks a chat: asking a Finder chat to "find my passport pdfs" stays in Finder instead of offering to run a command in Find My. "open Find My" still reaches the app.
- DoraX no longer opens an application while it is still working out what to offer — an app is launched only after you approve the action.
- A generic Edit ▸ Copy / Paste / Cut / Select All / Undo command is no longer offered as the answer to a search.
- In an app chat, a one-tap action is offered only when what you typed is the command itself ("copy", "new folder", "empty trash"). Any other sentence goes to the model, which sees the app's matching commands and picks one — or none.
- Stabilized Context Dock result rows by using stable pill IDs instead of row indexes.
- Stabilized Global Context app/menu result rows by using stable row IDs.
- Reduced noisy Global Context matches by requiring 3+ characters for app search.
- Reduced noisy Global Context recent document matches by requiring 3+ characters.

### Verified

- Debug build passes with isolated DerivedData:
  `xcodebuild -project Context-Dock.xcodeproj -scheme Context-Dock -configuration Debug -derivedDataPath /tmp/context-dock-deriveddata-release-audit2 CODE_SIGNING_ALLOWED=NO build`

### Known Work

- Add debug timing around result rebuilds, menu reads, and menu cache lookups.
- Extract duplicate menu loading logic into a shared service.
- Define a shared result list state model for Global Context and Context Dock.
- Add app-specific Find/Search routing for Photos, Mail, Notes, and other scoped apps.
