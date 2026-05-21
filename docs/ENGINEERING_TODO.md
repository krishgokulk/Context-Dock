# Engineering TODO

Track release work here. Keep each item small enough for one pull request.

## Done

- [x] Reduce Global Context short-query noise by requiring 3+ characters for global app search.
- [x] Reduce Global Context recent document noise by requiring 3+ characters.
- [x] Use stable row IDs for Context Dock vertical result rows.
- [x] Use stable row IDs for Global Context app, menu, and cross-app menu rows.
- [x] Confirm Apple Menu items are excluded from persistent per-app menu cache.
- [x] Confirm dynamic recent menu branches are excluded from persistent per-app menu cache.
- [x] [Find] Add first-pass app-scoped Find pill and submit routing before generic Finder/context actions.
- [x] [Find] Replace result-row Find with inline input token and optional child-menu picker.
- [x] Verify Debug build with isolated DerivedData.

## Next

- [ ] [Find] Define `AppFindProfile` routing for app-specific Find/Search behavior.
- [ ] [Find] Extract first-pass Find routing into a declarative `AppFindProfile` service.
- [ ] [Find] Add app-specific Find profiles for Photos, Mail, Notes, Safari, Finder, Preview, TextEdit, Xcode, and VS Code.
- [ ] [Find] Prefer app-native search surfaces when available: Photos search field, Mailbox Search, Notes search, Finder folder search, browser page find.
- [ ] [Find] Fall back to `Edit > Find > Find...`, `Cmd+F`, find pasteboard, and AX search-field injection when no profile exists.
- [ ] [Find] Add manual QA cases for `find [query] in [app]`, `[app] find [query]`, and scoped Context Dock queries.
- [ ] Add debug timing for `scheduleDockPillRebuild`.
- [ ] Add debug timing for `scheduleGlobalGroupedListRebuild`.
- [ ] Add debug timing for `AXMenuReader.refreshAllMenuItems`.
- [ ] Add debug timing for `AppMenuCapabilityCache.menuItems`.
- [ ] Extract duplicate menu loading policy into `MenuLoadService`.
- [ ] Define shared `DockResultListModel` for Global Context and Context Dock rows.
- [ ] Decide whether Global Context should preserve focus across query changes.
- [ ] Add a lightweight in-app debug panel for menu cache age and AX scan duration.

## Release Blockers

- [ ] Complete manual release checklist on a clean app launch.
- [ ] Complete manual release checklist after app has been running for 30 minutes.
- [ ] Run Debug and Release builds.
- [ ] Create GitHub release notes from `CHANGELOG.md`.

## Deferred

- [ ] Automated UI tests for keyboard navigation.
- [ ] Snapshot tests for result list row identity.
- [ ] Automated tests for Find routing once app-specific profiles are extracted.
- [ ] Telemetry export for local performance traces.
