# Settings Integrations Redesign

**Date:** 2026-09-04
**Status:** approved in conversation, pending written-spec review

## Goal

Make Context-Dock Settings understandable without weakening its app-scoped architecture.
Users choose an app first, see everything Context-Dock can use with that app, and reach
global capabilities through a parallel Global scope. Everyday information is visible first;
technical configuration remains close and discoverable.

This redesign consolidates presentation and navigation. It does not change capability
execution, approval semantics, persistence formats, provider routing, or product-layer
boundaries.

## Product language

Use **Integration** throughout the user interface. An integration is the complete set of
capabilities Context-Dock has for one app.

Keep **adapter pack** only where the implementation artifact matters, such as import/export
dialogs and technical diagnostics. Do not expose **App Adapter** as the normal product name.

Use **Resources** as the user-facing group for skills, CLI tools, MCP servers, API
connections, shortcuts, and context readers. This avoids putting protocol and implementation
terms in primary navigation while keeping them visible inside the group.

## Information architecture

The Settings sidebar has three sections:

### General

- General
- AI Providers

### Integrations

- Integrations

### System

- Permissions
- Appearance
- Hotkeys
- Data & Storage
- Updates
- Advanced
- About

The single Integrations destination replaces the permanent sidebar entries for Create
Extension, Commands, CLI Tool Scope, App Adapters, and Selection Scope. Their capabilities
remain available inside Integrations; only the fragmented entry points are consolidated.

Media remains governed by the existing architecture rule that Media Dock is not a chat
surface. Any existing Media Settings behavior must remain separate unless a later design
explicitly relocates it. This redesign does not redefine Media Dock or its ownership.

## Integrations workspace

Integrations uses one settings shell and a three-column layout:

1. The existing Settings sidebar.
2. An integration browser containing a scope selector, search, and list.
3. The selected integration or global capability detail.

The browser has two scopes:

- **Apps:** one row per configured app integration. Selecting a row shows the complete
  integration for that app.
- **Global:** commands, selection-aware actions, standalone CLI tools, and MCP servers that
  the user intentionally made available without a frontmost-app relationship.

The scope selector is stable when the user changes detail tabs. The selected scope, list
item, and detail tab remain stable while the Settings window is open. A later persistence
decision may restore them across launches, but cross-launch persistence is not required by
this design.

Search matches names and relevant technical identifiers, including app name, bundle ID,
capability name, command, and capability type. Results remain grouped within the selected
scope; search does not silently mix app-scoped and global authority.

## App integration detail

Selecting an app opens a header and four tabs:

### Overview

Overview answers what the integration is and whether it is ready:

- app icon, app name, bundle identifier, and enabled state;
- overall health and actionable setup warnings;
- counts for actions and resources;
- a plain-language summary of what Context-Dock can do with the app;
- concise capability health and setup suggestions.

Overview is informative. Editing belongs in the relevant detail tab.

### Actions

Actions contains capabilities that perform an app-visible operation. Existing frontmost-app
actions and browser-extension actions remain distinct groups because they use different
execution surfaces. Each row exposes its enabled state and the existing edit or remove flow.

### Resources

Resources contains:

- Skills
- CLI Tools
- MCP Servers
- API Connections
- Shortcuts
- Context Readers

Each resource type has a named group with its count and health. Empty groups are collapsed
by default and provide one clear Add action when opened. Populated groups show concise rows;
editing details remain in sheets or focused child views instead of expanding the main page
indefinitely.

### Access

Access makes the integration's authority legible:

- required macOS permissions;
- approval and consent policy;
- trust state;
- data scopes and context access;
- network or Keychain implications;
- destructive removal of the complete integration.

Access summarizes existing authority. It must not invent a second permission system or
weaken approvals owned by execution services.

## Global detail

Global uses the same visual grammar as app integrations but represents capabilities that are
not bound to a frontmost app. It groups global commands, selection actions, standalone CLI
tools, and global MCP servers without presenting them as if they belonged to an app.

Global and Apps may reuse list rows, section containers, status treatments, and editors, but
their scopes remain typed and distinct. Moving a capability between them is an explicit user
operation, never a presentation-side inference.

## Creation and import

One **Add** menu replaces Create Extension as a permanent destination. Its contents follow
the current scope and, where useful, the selected detail tab.

In Apps scope it can offer:

- Choose App
- Import Integration
- Add Action
- Add Skill
- Add CLI Tool
- Add MCP Server
- Connect API
- Link Shortcut

In Global scope it can offer:

- Add Command
- Add Selection Action
- Add CLI Tool
- Add MCP Server

The menu may prioritize contextually relevant items, but every supported creation path must
remain reachable. Existing editors and import validation are reused. Adapter-pack wording is
permitted inside Import Integration after the user chooses the file-based workflow.

## Component boundaries

`SettingsView` remains the only Settings shell and continues to own sidebar selection and
shared chrome state.

`IntegrationsSettingsPage` owns the Apps/Global scope selector, search, integration list, and
detail selection. It does not own persistence for individual capabilities.

`IntegrationDetailView` owns the shared app header and Overview, Actions, Resources, and
Access tab selection. Focused child views render each tab so capability-specific concerns do
not accumulate in one large view.

A lightweight, read-only `IntegrationInventory` composes data from existing owners such as:

- `AppAdapterManager`
- `SkillStore`
- `TerminalPackageManager`
- `MCPServerManager`
- `APIConnectionStore`
- shortcut stores
- consent and permission stores

The exact form may be a value model plus a coordinator or view model, but it has three firm
constraints:

1. It is not another persistence layer.
2. Mutations go through the manager that already owns the data.
3. It preserves the distinction between app-scoped and global capabilities.

The inventory refreshes from existing published changes. If an owner is not observable, the
implementation plan must define a narrow refresh adapter instead of introducing broad
NotificationCenter traffic.

## Navigation compatibility

Existing deep links and internal requests to old Settings destinations must resolve into the
new workspace:

- App Adapters → Integrations / Apps
- Commands → Integrations / Global / Actions
- CLI Tool Scope → Integrations / Global / Resources
- Selection Scope → Integrations / Global / Actions, focused on selection-aware actions
- Create Extension → Integrations with the Add menu or matching creation flow presented

Compatibility mapping should be centralized and testable. Call sites should migrate to a
typed Integrations destination over time; the first rollout must not break existing entry
points.

## State and data flow

1. The selected Settings destination opens Integrations.
2. `IntegrationsSettingsPage` selects Apps or Global and derives a filtered inventory.
3. Selecting an item supplies an identity to its detail view.
4. The detail view reads composed display data from `IntegrationInventory`.
5. User mutations call the existing owning manager.
6. Published owner changes recompute the affected inventory and update the view.

The selected identity must be resilient to refresh. If the selected item is removed, the UI
selects the nearest sensible remaining item or shows the scope's empty state. It must not
display stale details.

## Errors, health, and destructive actions

Missing binaries, disconnected MCP servers, invalid API credentials, unavailable
permissions, and failed imports appear as inline statuses beside the affected resource. One
broken resource does not disable or visually condemn an otherwise healthy integration.

Health text must say what is wrong and provide the smallest relevant recovery action. Do not
use color as the only signal.

Removing an individual capability uses its existing confirmation policy. Removing a complete
integration requires confirmation that lists what will be removed and what will remain. The
implementation must resolve that inventory before presenting the confirmation; it must not
promise removal of data owned outside the integration.

## Accessibility and responsive behavior

The workspace must support:

- full keyboard navigation across sidebar, scopes, list, tabs, and controls;
- meaningful VoiceOver labels and values for status, counts, toggles, and health;
- visible focus treatment;
- increased contrast and reduced motion;
- light and dark appearance;
- narrow and wide Settings window sizes.

At narrow widths, the layout may collapse the integration browser into navigation, but it
must preserve the Apps/Global scope and a clear route back. Empty, loading, and error states
retain structural stability and do not cause avoidable column jumps.

## Staged rollout

Each stage is independently reviewable and stops for user verification before the next.

### Stage 1: Navigation foundation

- Add the Integrations destination and Apps/Global browser.
- Add centralized compatibility routing for old Settings destinations.
- Verify selection behavior, resizing, keyboard navigation, and unchanged stored data.

### Stage 2: App integration detail

- Build Overview, Actions, Resources, and Access from existing managers.
- Compare every item and count with the existing App Adapters UI.
- Keep the old rendering reachable internally until behavioral parity is proven.

### Stage 3: Global consolidation

- Present Commands, Selection Scope, standalone CLI tools, and global MCP servers in Global.
- Verify creation, editing, enable/disable, and deletion for each capability type.

### Stage 4: Cleanup and polish

- Remove obsolete permanent sidebar entries after parity is proven.
- Complete empty, loading, health, and error states.
- Complete accessibility and visual verification.
- Remove compatibility rendering only when deep-link and behavior tests prove it is safe.

## Verification

Every code-editing stage follows the repository workflow and ends with:

- focused tests for navigation, scope isolation, inventory composition, and mutations;
- regression coverage for old deep-link mappings;
- parity checks against existing app and global capability inventories;
- the complete offline test suite via `./scripts/test.sh`;
- `git diff --check`;
- `graphify update .` after substantial code changes;
- build and relaunch via `./scripts/dev-run.sh`, never raw `xcodebuild` plus `open`;
- a manual walkthrough in light and dark appearance at narrow and wide sizes.

Manual verification also covers a populated app, an empty app, a partially broken app, an
empty Global scope, and a populated Global scope.

## Explicit exclusions

This design does not include:

- changes to runtime action execution or approval policy;
- a new capability persistence format or data migration;
- automatic conversion between app-scoped and global capabilities;
- a marketplace or remote plugin catalogue;
- a separate Extension Studio window;
- changes to AI provider configuration;
- changes to Media Dock's product role;
- Developer Inspector P1 implementation or UI.

## Alternatives considered

### Capability-first Settings

A top-level page for every capability type resembles technical plugin managers and makes
fleet-wide MCP or skill administration direct. It was rejected as the primary model because
it obscures Context-Dock's app-scoped promise and encourages users to reason about internal
mechanisms before their task.

### Simple Settings plus Extension Studio

Separating ordinary preferences from a dedicated builder surface produces the calmest
Settings window. It was rejected because it creates another product surface, splits related
configuration, and adds navigation cost before the current app-first workspace has proven
too dense.

### One expandable app page

A single disclosure-based detail page is initially approachable. It was rejected because
large integrations become long and state-heavy. Four stable tabs scale better while keeping
Overview calm.

## Success criteria

The redesign succeeds when:

- a new user can find everything Context-Dock can do with a chosen app from one place;
- app-scoped and global capabilities never appear to share authority accidentally;
- an experienced user can reach any technical resource within two selections after choosing
  Integrations;
- existing capability counts, editing flows, deep links, and stored data remain correct;
- broken resources are identifiable and recoverable without disabling healthy siblings;
- the Settings UI remains native, keyboard-accessible, responsive, and consistent with the
  shared Context-Dock shell;
- the redesign introduces no new product layer and does not absorb Developer Inspector,
  Media Dock, or chat surfaces into Settings.
