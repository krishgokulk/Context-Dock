# Context-Dock

## Recent fixes (merged on 2026-05-08)

This repository was updated by merging branch `xcode-sync-20260508-030912` into `main` (commit d67e5bcc...). The merge contains a number of updates, fixes and small refactors. Summary of what changed and what was fixed:

- Updated Xcode project and workspace files
  - `Context-Dock.xcodeproj/project.pbxproj` and workspace scheme/Package.resolved were modified to keep Xcode project in sync.

- Added new utilities and modules
  - `Context-Dock/AXSearchFieldInjector.swift` (new)
  - `Context-Dock/DebugLogger.swift` (new)
  - `Context-Dock/DockActionFeedback.swift` (new)
  - `Context-Dock/QueryFailureGuide.swift` (new)
  - `Context-Dock/SystemCommands.swift` (new)

- Removed files
  - `Context-Dock/LayeredExtensionsSettingsView.swift` was deleted as part of the refactor.

- Major refactors and large edits
  - `Context-Dock/ContentView.swift` received a large update (many changes) — likely UI flow, state handling or view composition improvements.
  - `Context-Dock/AutomationSettingsView.swift` and `Context-Dock/SettingsView.swift` were updated.
  - `Context-Dock/LayeredExtensionManager.swift`, `Context-Dock/FileIndexManager.swift`, and other core files received smaller API/behavior changes.

- Functional additions and bug fixes
  - `Context-Dock/AXMenuEnumerator.swift`, `Context-Dock/AXMenuReader.swift`, and `Context-Dock/SafariCommandBridge.swift` were updated — improvements to accessibility/menu integration and Safari bridging.
  - `Context-Dock/DebugLogger.swift` was introduced to centralize logging and aid debugging.
  - `Context-Dock/SystemCommands.swift` provides higher-level system command helpers.

If you'd like a more detailed changelog (per-file diff or annotated notes), I can:

- Generate a per-file diff and add it to this README or a separate `CHANGELOG.md`.
- Create a short PR description with highlights for reviewers.

Commit & merge info
- Merged branch: `xcode-sync-20260508-030912`
- Merge commit: `d67e5bccceac1f00cf75513dfbf89ae1d4d0c885`

If you want me to expand any of the bullets above with specific code-level details (for example, the exact changes in `ContentView.swift`), tell me which files to summarize and I will include file-level diffs and explanations.

---
Generated: 2026-05-08
