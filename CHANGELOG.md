# Changelog

All notable changes to Context-Dock are tracked here.

## 1.1 - Beta

### Changed

- The Drop Shelf's tray icon only appears once the shelf holds something, or while you drag a file.
- An app's Context Dock now has a panel beside the conversation, like Claude's: each step as it runs, the command's output, the files the answer made, your uploads, the app's connectors and adapter, and what DoraX can do there. Hide it with the sidebar button. The chat field is now a rounded composer.
- Arrowing through results in the corner splits the result card, list on the left, details on the right: a preview of the file, image or folder, the app, or where a menu command lives.
- General Chat in the corner opens at once, as its field alone (no start card), instead of waiting on the chat history to load.
- The corner dock rests as a compact bar as wide as its apps, and opens to exactly the Dock's input bar size (600 × 56) in every mode — Global Context, each app's Context Dock and General Chat; running apps and an app's tabs scroll inside a fixed pill, and a long prompt grows the field upward to three lines instead of wrapping into a narrow column.
- When the front app exposes nothing readable, the chat now names the app, says what it can see (the window title) and why the rest is unreadable, and suggests selecting or pasting the text instead of offering a pointless re-read; an attached screenshot's OCR says "found no text" or "could not run", not "recognized zero text".
- A System setting (volume, dark mode, Bluetooth) that the Mac reports differently from what was asked now fails the step and says so, instead of reporting success.
- The clipboard notice in the corner no longer blocks the app you are working in: clicks outside the notice itself now reach the app underneath.
- File cards: VoiceOver and Voice Control now name each Quick Look, Open and Reveal button after its file, so a card of many files no longer has a dozen identical "Open" buttons.
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

- Turn log (opt-in, `doraxTurnLogEnabled`): each chat turn now writes one `turn.trace` record with its provider, model, tools sent and called, tokens per round including prompt-cache reads and writes, prompt section sizes, which answer checks fired, fallbacks, and time to first token and total; never the question or answer. `python3 scripts/turn-cache-ratio.py` prints the cache-read ratio over the last 50 turns.
- Security gate: once a chat turn has read your private data (mail, messages, notes, files) and a web page or other outside text, anything that could send data out (a link to a site you did not type, a message, a Shortcut, a command that reaches the network) asks first, saying why; unattended runs refuse instead.
- General Chat can read your Global Commands' current state ("is Bluetooth on?") without an approval prompt; commands are grouped into System packs (Bluetooth, Wi-Fi, Sound, Appearance, …).
- General Chat can write a .md, .txt, .csv or .docx for you into ~/Documents/DoraX Outputs (never overwrites; you approve each file) and shows it as a card; also `dorax_write_output_file` for the DoraX MCP server.
- General Chat can list your Shortcuts and run one by exact name (you approve each run and see the name and input; never run unattended); also `dorax_list_shortcuts` / `dorax_run_shortcut` for the DoraX MCP server.
- Files a chat answer names — in any chat, any provider — appear as cards under it with Quick Look, Open, Reveal in Finder and drag out.

### Fixed

- The app no longer freezes and spins at full CPU during a long chat turn, and it quits promptly (including on restart or log out): a command waiting for approval in the dock chat used to re-add its approval card over and over until the main thread was saturated.
- An everyday phrase that happens to be an app name no longer hijacks a chat: asking a Finder chat to "find my passport pdfs" stays in Finder instead of offering to run a command in Find My. "open Find My" still reaches the app.
- DoraX no longer opens an application while it is still working out what to offer — an app is launched only after you approve the action.
- A generic Edit ▸ Copy / Paste / Cut / Select All / Undo command is no longer offered as the answer to a search.
- In an app chat, a one-tap action is offered only when what you typed is the command itself ("copy", "new folder", "empty trash"). Any other sentence goes to the model, which sees the app's matching commands and picks one — or none.
- A Finder (or any app) chat that picked a Finder action no longer ends in "couldn't carry it out on this surface" while still spinning: the action runs with its normal approval, or the answer says what is missing (for example a destination folder), and the reply bubble no longer shows that sentence while the answer is still being written.
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
