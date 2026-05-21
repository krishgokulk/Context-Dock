# Engineering Decisions

Record decisions that affect stability, performance, or release behavior.

## 2026-05-21: Apple Menu Stays Session-Scoped

Apple Menu entries are universal system actions, but some children such as Recent Items and Documents are dynamic. Persisting them in per-app menu cache can make results stale and can pollute app-scoped searches.

Decision:

- Read Apple Menu from live/session menu data.
- Do not persist Apple Menu items in `AppMenuCapabilityCache`.
- Do not treat Apple Menu as a normal app capability.

## 2026-05-21: Dynamic Recent Branches Stay Out Of Persistent Cache

Recent documents, recent projects, closed tabs, and similar branches change frequently. Persistent cache can quickly become wrong.

Decision:

- Filter dynamic recent branches before saving app menu capabilities.
- Allow browser history/bookmark branches only where explicitly handled.

## 2026-05-21: Short Global Queries Prefer Frontmost Menus

One- and two-letter queries create too many app and recent document matches. This makes Global Context feel noisy and unstable.

Decision:

- Require 3+ characters for global app search.
- Require 3+ characters for Global Context recent document results.
- Let 1-2 character queries stay focused on frontmost/session menu results.

## 2026-05-21: Result Rows Use Stable IDs

Index-based row IDs cause SwiftUI lists to lose identity when query updates reorder results.

Decision:

- Context Dock vertical rows use `DockPill.id`.
- Global Context app rows use `SearchResult.id`.
- Global Context menu rows use `DockPill.id` plus source context where needed.

## 2026-05-21: Find Commands Need App-Specific Profiles

Every macOS app exposes "Find" differently. Some apps use plain `Edit > Find > Find...`, some expose app-level search, and some have multiple Find variants. Mail has Mailbox Search plus message-local Find. Notes has note-list search and in-note Find. Photos needs library search, not text find.

Decision:

- Route explicit `find/search [query] in [app]` intents before generic AI/file actions.
- Use app-specific `AppFindProfile` behavior where known.
- Prefer app-native library/mailbox/note search for content queries.
- Use `Edit > Find > Find...`, `Cmd+F`, find pasteboard, and AX injection as fallback only.
- Keep per-app Find behavior declarative so new apps can be added without expanding `ContentView.swift`.
