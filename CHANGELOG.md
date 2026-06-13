# Changelog

All notable changes to Context-Dock are tracked here.

## 1.1 - Beta

### Changed

- Improved Global Context app-scope ranking so apps, useful menus, and recent menu use surface first.
- Stabilized Context Dock result sheet sizing and row identity while typing.
- Polished settings navigation, AI providers, extension import, and shortcut sheet flows.
- Added AI profiles and provider routing for beta testing.
- Improved native menu execution for quit, stop, open-with, and frontmost-app actions.

### Beta Notes

- DMG build is ready for user testing.
- App is not notarized unless built with a Developer ID signing identity.

## Unreleased

### Fixed

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
