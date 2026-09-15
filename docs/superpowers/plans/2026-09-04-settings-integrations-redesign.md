# Settings Integrations Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace fragmented extension settings with one app-first Integrations workspace containing distinct Apps and Global scopes.

**Architecture:** Keep `SettingsView` as the single shell and add a focused `IntegrationsSettingsPage`. A pure `IntegrationInventoryBuilder` composes existing manager snapshots into display models; existing managers remain the persistence and mutation owners. Preserve legacy deep links until the new workspace reaches parity, then hide obsolete sidebar destinations without changing runtime capability behavior.

**Tech Stack:** Swift 5, SwiftUI and AppKit on macOS 26.1, Combine, swift-testing, pure Xcode project with filesystem-synchronized groups.

**Spec:** `docs/superpowers/specs/2026-09-04-settings-integrations-redesign.md`

## Global Constraints

- Use **Integration** in normal UI; use **adapter pack** only in import/export or diagnostics.
- Apps and Global are typed, separate authority scopes; never infer movement between them.
- Existing managers remain persistence and mutation owners; inventory is read-only composition.
- Do not change runtime execution, approval semantics, stored formats, or provider routing.
- Do not absorb Media Dock, chat surfaces, or Developer Inspector into Settings.
- Reuse the native Settings shell and standard SwiftUI controls before adding custom chrome.
- After every code-editing task, run its focused tests, `git diff --check`, and `./scripts/dev-run.sh`.
- Stop after each task so the user can verify before the next task begins.
- Preserve unrelated working-tree changes and stage only files owned by the current task.

---

## File Map

### New production files

- `Context-Dock/UI/Settings/Integrations/IntegrationModels.swift` — scope, tab, destination, inventory, health, and search models.
- `Context-Dock/UI/Settings/Integrations/IntegrationInventoryBuilder.swift` — pure snapshot-to-inventory composition and filtering.
- `Context-Dock/UI/Settings/Integrations/IntegrationsSettingsPage.swift` — Apps/Global workspace, selection, search, and contextual Add menu.
- `Context-Dock/UI/Settings/Integrations/IntegrationBrowserView.swift` — scope picker, search field, and stable selectable list.
- `Context-Dock/UI/Settings/Integrations/AppIntegrationDetailView.swift` — app header and four-tab container.
- `Context-Dock/UI/Settings/Integrations/AppIntegrationOverviewView.swift` — summary, counts, health, and setup warnings.
- `Context-Dock/UI/Settings/Integrations/AppIntegrationActionsView.swift` — app-visible and browser actions.
- `Context-Dock/UI/Settings/Integrations/AppIntegrationResourcesView.swift` — Skills, CLI, MCP, APIs, Shortcuts, and readers.
- `Context-Dock/UI/Settings/Integrations/AppIntegrationAccessView.swift` — permission, consent, trust, and removal controls.
- `Context-Dock/UI/Settings/Integrations/GlobalIntegrationDetailView.swift` — commands, selection actions, global CLI, and global MCP.
- `Context-Dock/UI/Settings/Integrations/IntegrationAddMenu.swift` — context-sensitive creation/import commands.

### Modified production files

- `Context-Dock/UI/Settings/SettingsModels.swift` — add `.integrations`, sidebar grouping, and legacy-route mapping.
- `Context-Dock/UI/Settings/SettingsView.swift` — accept typed integration destinations and preserve selection.
- `Context-Dock/UI/Settings/SettingsDetailView.swift` — route `.integrations` to the new page.
- `Context-Dock/UI/Settings/SettingsSidebar.swift` — replace the Extensions group with one Integrations row.
- `Context-Dock/Automation/AutomationSettingsView.swift` — expose existing editors as internal reusable views/callbacks, then remove only superseded app/global rendering after parity.
- `Context-Dock/UI/GeneralChatStartView.swift` and other `.openSettingsPage` callers found by exhaustive search — migrate app-integration deep links.

### New tests

- `Context-DockTests/IntegrationRouteTests.swift` — legacy destination compatibility.
- `Context-DockTests/IntegrationInventoryTests.swift` — app/global isolation, counts, health, and filtering.
- `Context-DockTests/IntegrationSelectionTests.swift` — deterministic selection recovery and state transitions.
- `Context-DockTests/IntegrationAddMenuTests.swift` — exact actions available for each scope/tab.

---

### Task 1: Typed destination and compatibility routing

**Files:**
- Create: `Context-Dock/UI/Settings/Integrations/IntegrationModels.swift`
- Create: `Context-DockTests/IntegrationRouteTests.swift`
- Modify: `Context-Dock/UI/Settings/SettingsModels.swift:3-174`
- Modify: `Context-Dock/UI/Settings/SettingsView.swift:4-38`
- Modify: `Context-Dock/UI/Settings/SettingsDetailView.swift:3-50`

**Interfaces:**
- Produces: `IntegrationScope`, `IntegrationDetailTab`, `IntegrationDestination`, and `SettingsRouteResolver.destination(for:)`.
- Produces: `SettingsPage.integrations` as the canonical page.
- Preserves: every current `SettingsPage` raw value for legacy notifications during rollout.

- [ ] **Step 1: Write failing route tests**

```swift
import Testing
@testable import Context_Dock

@Suite("Integration settings routing")
struct IntegrationRouteTests {
    @Test(arguments: [
        (SettingsPage.frontmostAppAdapters, IntegrationDestination(scope: .apps)),
        (SettingsPage.extensionsGlobalWithoutSelection, IntegrationDestination(scope: .global, tab: .actions)),
        (SettingsPage.extensionsCLIToolScope, IntegrationDestination(scope: .global, tab: .resources)),
        (SettingsPage.shortcutSheetWorkflows, IntegrationDestination(scope: .global, tab: .actions, focus: .selectionActions)),
    ])
    func legacyPageMapsToIntegration(
        page: SettingsPage,
        expected: IntegrationDestination
    ) {
        #expect(SettingsRouteResolver.destination(for: page) == expected)
    }

    @Test func ordinaryPageDoesNotInventIntegrationRoute() {
        #expect(SettingsRouteResolver.destination(for: .appearance) == nil)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/IntegrationRouteTests`

Expected: compilation fails because the integration routing types do not exist.

- [ ] **Step 3: Add the minimal typed models and resolver**

```swift
enum IntegrationScope: String, CaseIterable, Identifiable, Codable {
    case apps, global
    var id: Self { self }
}

enum IntegrationDetailTab: String, CaseIterable, Identifiable, Codable {
    case overview, actions, resources, access
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum IntegrationFocus: String, Codable, Equatable {
    case selectionActions, commands, cliTools, mcpServers
}

struct IntegrationDestination: Codable, Equatable {
    var scope: IntegrationScope
    var bundleID: String?
    var tab: IntegrationDetailTab
    var focus: IntegrationFocus?

    init(
        scope: IntegrationScope,
        bundleID: String? = nil,
        tab: IntegrationDetailTab = .overview,
        focus: IntegrationFocus? = nil
    ) {
        self.scope = scope
        self.bundleID = bundleID
        self.tab = tab
        self.focus = focus
    }
}

enum SettingsRouteResolver {
    static func destination(for page: SettingsPage) -> IntegrationDestination? {
        switch page {
        case .frontmostAppAdapters: return .init(scope: .apps)
        case .extensionsGlobalWithoutSelection:
            return .init(scope: .global, tab: .actions, focus: .commands)
        case .extensionsCLIToolScope:
            return .init(scope: .global, tab: .resources, focus: .cliTools)
        case .shortcutSheetWorkflows:
            return .init(scope: .global, tab: .actions, focus: .selectionActions)
        default: return nil
        }
    }
}
```

Add `.integrations` to `SettingsPage`, with title `Integrations`, subtitle `Apps and global capabilities.`, icon `app.connected.to.app.below.fill`, and orange color. In `SettingsView`, resolve a legacy page before assigning selection and store the resulting `IntegrationDestination` in `@State` for `IntegrationsSettingsPage`.

- [ ] **Step 4: Run verification**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/IntegrationRouteTests
git diff --check
./scripts/dev-run.sh
```

Expected: route tests pass; the app relaunches from `.build/XcodeDerivedData`; current Settings pages still open.

- [ ] **Step 5: Commit only Task 1 files**

```bash
git add Context-Dock/UI/Settings/Integrations/IntegrationModels.swift Context-Dock/UI/Settings/SettingsModels.swift Context-Dock/UI/Settings/SettingsView.swift Context-Dock/UI/Settings/SettingsDetailView.swift Context-DockTests/IntegrationRouteTests.swift
git commit -m "feat(settings): add typed integrations routes"
```

Stop for user verification.

---

### Task 2: Pure integration inventory and search

**Files:**
- Create: `Context-Dock/UI/Settings/Integrations/IntegrationInventoryBuilder.swift`
- Create: `Context-DockTests/IntegrationInventoryTests.swift`
- Modify: `Context-Dock/UI/Settings/Integrations/IntegrationModels.swift`

**Interfaces:**
- Consumes: existing value types `AppAdapter`, `AdapterSkill`, `TerminalPackage`, `MCPServerConfig`, `APIConnection`, `ILExtension`, `AXTriggerRule`, and `SystemCommand`.
- Produces: `IntegrationInventorySnapshot`, `AppIntegrationSummary`, `GlobalIntegrationSummary`, `IntegrationResourceCounts`, `IntegrationHealth`, and `IntegrationInventoryBuilder.build(from:)`.
- Produces: `IntegrationInventoryBuilder.filter(_:query:)` with deterministic case-insensitive matching.

- [ ] **Step 1: Write failing scope and count tests**

```swift
import Testing
@testable import Context_Dock

@Suite("Integration inventory")
struct IntegrationInventoryTests {
    @Test func appAndGlobalCapabilitiesStaySeparated() {
        let snapshot = IntegrationInventorySnapshot.fixture(
            adapters: [.fixture(bundleID: "com.example.editor", actions: [.fixture(name: "Format")])],
            skills: [.fixture(bundleID: "com.example.editor", name: "Editing Guide")],
            packages: [
                .fixture(command: "fmt", bundleIDs: ["com.example.editor"]),
                .fixture(command: "rg", bundleIDs: ["cli://rg"]),
            ],
            mcpServers: [.fixture(name: "Docs", bundleIDs: ["com.example.editor"])],
            commands: [.fixture(name: "Lock Screen")]
        )

        let result = IntegrationInventoryBuilder.build(from: snapshot)
        let app = try #require(result.apps.first)
        #expect(app.bundleID == "com.example.editor")
        #expect(app.counts.actions == 1)
        #expect(app.counts.skills == 1)
        #expect(app.counts.cliTools == 1)
        #expect(app.counts.mcpServers == 1)
        #expect(result.global.commands.count == 1)
        #expect(result.global.cliTools.map(\.command) == ["rg"])
        #expect(!result.global.cliTools.contains { $0.command == "fmt" })
    }

    @Test func searchMatchesNameBundleIDCapabilityAndType() {
        let inventory = IntegrationInventory.fixture()
        #expect(IntegrationInventoryBuilder.filter(inventory.apps, query: "editor").count == 1)
        #expect(IntegrationInventoryBuilder.filter(inventory.apps, query: "com.example").count == 1)
        #expect(IntegrationInventoryBuilder.filter(inventory.apps, query: "mcp").count == 1)
    }
}
```

Test fixtures live in the test file and call real initializers; they must not write to singleton stores.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/IntegrationInventoryTests`

Expected: compilation fails because inventory types and builder do not exist.

- [ ] **Step 3: Implement value-only composition**

```swift
struct IntegrationResourceCounts: Equatable {
    let actions: Int
    let skills: Int
    let cliTools: Int
    let mcpServers: Int
    let apiConnections: Int
    let shortcuts: Int
    let contextReaders: Int

    var resources: Int {
        skills + cliTools + mcpServers + apiConnections + shortcuts + contextReaders
    }
}

enum IntegrationHealth: Equatable {
    case healthy
    case needsAttention([String])
}

struct IntegrationInventorySnapshot {
    let adapters: [AppAdapter]
    let skills: [AdapterSkill]
    let packages: [TerminalPackage]
    let mcpServers: [MCPServerConfig]
    let apiConnections: [APIConnection]
    let extensions: [ILExtension]
    let selectionRules: [AXTriggerRule]
    let commands: [SystemCommand]
}

enum IntegrationInventoryBuilder {
    static func build(from snapshot: IntegrationInventorySnapshot) -> IntegrationInventory
    static func filter(_ apps: [AppIntegrationSummary], query: String) -> [AppIntegrationSummary]
}
```

Build app rows from real adapters plus bundle IDs deliberately linked by enabled CLI packages. Exclude `cli://` synthetic identities from Apps. Classify a package as Global only with the same deliberate-scope rule currently represented by `TerminalPackageManager.isUserAddedGlobalScope`; pass preclassified global package IDs into the snapshot if calling the manager would make the builder impure. Selection extensions are `layer == .l2_context && category == "shortcutSheet"`; keep legacy selection rules in the same Global subsection without merging their model types.

- [ ] **Step 4: Run verification**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/IntegrationInventoryTests
git diff --check
./scripts/dev-run.sh
```

Expected: inventory tests pass; existing runtime data files are unchanged; app and global fixtures never cross scopes.

- [ ] **Step 5: Commit only Task 2 files**

```bash
git add Context-Dock/UI/Settings/Integrations/IntegrationModels.swift Context-Dock/UI/Settings/Integrations/IntegrationInventoryBuilder.swift Context-DockTests/IntegrationInventoryTests.swift
git commit -m "feat(settings): compose integration inventory"
```

Stop for user verification.

---

### Task 3: Integrations workspace shell and deterministic selection

**Files:**
- Create: `Context-Dock/UI/Settings/Integrations/IntegrationsSettingsPage.swift`
- Create: `Context-Dock/UI/Settings/Integrations/IntegrationBrowserView.swift`
- Create: `Context-DockTests/IntegrationSelectionTests.swift`
- Modify: `Context-Dock/UI/Settings/SettingsDetailView.swift`

**Interfaces:**
- Consumes: `IntegrationDestination` and inventory models from Tasks 1–2.
- Produces: `IntegrationSelectionState.reconcile(availableAppIDs:)`.
- Produces: a three-column Integrations page with stable scope, query, selected app, and tab.

- [ ] **Step 1: Write failing selection-state tests**

```swift
import Testing
@testable import Context_Dock

@Suite("Integration selection")
struct IntegrationSelectionTests {
    @Test func removedSelectionFallsForwardThenBack() {
        var state = IntegrationSelectionState(scope: .apps, selectedAppID: "b")
        state.reconcile(availableAppIDs: ["a", "b", "c"])
        state.reconcile(availableAppIDs: ["a", "c"])
        #expect(state.selectedAppID == "c")
        state.reconcile(availableAppIDs: ["a"])
        #expect(state.selectedAppID == "a")
    }

    @Test func emptyAppsClearsSelectionWithoutChangingScope() {
        var state = IntegrationSelectionState(scope: .apps, selectedAppID: "a")
        state.reconcile(availableAppIDs: [])
        #expect(state.scope == .apps)
        #expect(state.selectedAppID == nil)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/IntegrationSelectionTests`

Expected: compilation fails because `IntegrationSelectionState` does not exist.

- [ ] **Step 3: Implement deterministic state and workspace shell**

```swift
struct IntegrationSelectionState: Equatable {
    var scope: IntegrationScope = .apps
    var selectedAppID: String?
    var tab: IntegrationDetailTab = .overview
    var focus: IntegrationFocus?
    private var previousOrder: [String] = []

    mutating func reconcile(availableAppIDs: [String]) {
        defer { previousOrder = availableAppIDs }
        guard !availableAppIDs.isEmpty else { selectedAppID = nil; return }
        guard let selectedAppID else { self.selectedAppID = availableAppIDs.first; return }
        guard !availableAppIDs.contains(selectedAppID) else { return }
        let oldIndex = previousOrder.firstIndex(of: selectedAppID) ?? 0
        self.selectedAppID = availableAppIDs[min(oldIndex, availableAppIDs.count - 1)]
    }
}
```

`IntegrationsSettingsPage` observes the existing managers, creates an `IntegrationInventorySnapshot` in one computed property, applies search through the pure builder, and feeds `IntegrationBrowserView`. Use standard `Picker(.segmented)`, `searchable`, `List(selection:)`, dividers, and system materials. Do not add custom window or sidebar containers.

- [ ] **Step 4: Route Settings to the new page**

In `SettingsDetailView.pageContent`, render `IntegrationsSettingsPage(destination:)` for `.integrations`. Do not remove legacy cases yet. The page owns its header because its three-column workspace needs the integration browser flush beneath it; avoid rendering two headers.

- [ ] **Step 5: Run verification**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/IntegrationSelectionTests
git diff --check
./scripts/dev-run.sh
```

Expected: the Integrations page opens; Apps/Global switching and search work; removing fixture/state items cannot leave stale detail; legacy Settings pages still render.

- [ ] **Step 6: Commit only Task 3 files**

```bash
git add Context-Dock/UI/Settings/Integrations/IntegrationsSettingsPage.swift Context-Dock/UI/Settings/Integrations/IntegrationBrowserView.swift Context-Dock/UI/Settings/Integrations/IntegrationModels.swift Context-Dock/UI/Settings/SettingsDetailView.swift Context-DockTests/IntegrationSelectionTests.swift
git commit -m "feat(settings): add integrations workspace"
```

Stop for user verification.

---

### Task 4: App Overview and Actions parity

**Files:**
- Create: `Context-Dock/UI/Settings/Integrations/AppIntegrationDetailView.swift`
- Create: `Context-Dock/UI/Settings/Integrations/AppIntegrationOverviewView.swift`
- Create: `Context-Dock/UI/Settings/Integrations/AppIntegrationActionsView.swift`
- Modify: `Context-Dock/Automation/AutomationSettingsView.swift:3330-4440` and the existing action-editor declarations it calls
- Modify: `Context-DockTests/IntegrationInventoryTests.swift`

**Interfaces:**
- Consumes: `AppIntegrationSummary`, `AppAdapterManager`, and existing action editor/import flows.
- Produces: a tabbed app detail container and reusable internal action editor presentation.
- Preserves: separation between frontmost-app actions and browser-extension actions.

- [ ] **Step 1: Extend inventory tests for action grouping and health**

```swift
@Test func actionsPreserveExecutionSurfaceGroups() throws {
    let adapter = AppAdapter.fixture(actions: [
        .fixture(name: "Open Project", type: .menuItem),
        .fixture(name: "Read Page", type: .pageJS),
    ])
    let app = try #require(
        IntegrationInventoryBuilder.build(from: .fixture(adapters: [adapter])).apps.first
    )
    #expect(app.appActions.map(\.name) == ["Open Project"])
    #expect(app.browserActions.map(\.name) == ["Read Page"])
}
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/IntegrationInventoryTests`

Expected: failure because summaries do not yet expose the two action groups.

- [ ] **Step 3: Implement Overview and tab container**

```swift
struct AppIntegrationDetailView: View {
    let summary: AppIntegrationSummary
    @Binding var selectedTab: IntegrationDetailTab

    var body: some View {
        VStack(spacing: 0) {
            IntegrationHeader(summary: summary)
            Picker("Section", selection: $selectedTab) {
                ForEach(IntegrationDetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            tabContent
        }
    }
}
```

Overview shows Enabled/Disabled, Actions, and Resources cards; description; health; and setup warnings. Counts come only from `AppIntegrationSummary`, never by querying singletons again inside child views.

- [ ] **Step 4: Extract and reuse action UI**

Move only the named action-list and editor presentation needed by the new page out of `AutomationAdapterDetailView`. Give `AppIntegrationActionsView` explicit inputs:

```swift
struct AppIntegrationActionsView: View {
    let bundleID: String
    let appActions: [AdapterAction]
    let browserActions: [AdapterAction]
    let onAdd: () -> Void
    let onEdit: (AdapterAction) -> Void
    let onRemove: (AdapterAction) -> Void
}
```

Do not duplicate mutations. Wire callbacks to the existing `AppAdapterManager` and existing confirmation/editor flows. Keep old `AutomationAdapterDetailView` compiling and reachable for parity checks.

- [ ] **Step 5: Run verification**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/IntegrationInventoryTests
git diff --check
./scripts/dev-run.sh
```

Expected: Overview counts equal the old App Adapters overview; both action groups contain the same rows; add/edit/enable/remove behave identically.

- [ ] **Step 6: Commit only Task 4 files**

```bash
git add Context-Dock/UI/Settings/Integrations/AppIntegrationDetailView.swift Context-Dock/UI/Settings/Integrations/AppIntegrationOverviewView.swift Context-Dock/UI/Settings/Integrations/AppIntegrationActionsView.swift Context-Dock/UI/Settings/Integrations/IntegrationModels.swift Context-Dock/UI/Settings/Integrations/IntegrationInventoryBuilder.swift Context-Dock/Automation/AutomationSettingsView.swift Context-DockTests/IntegrationInventoryTests.swift
git commit -m "feat(settings): add integration overview and actions"
```

Stop for user verification.

---

### Task 5: Resources and Access parity

**Files:**
- Create: `Context-Dock/UI/Settings/Integrations/AppIntegrationResourcesView.swift`
- Create: `Context-Dock/UI/Settings/Integrations/AppIntegrationAccessView.swift`
- Modify: `Context-Dock/UI/Settings/Integrations/AppIntegrationDetailView.swift`
- Modify: `Context-Dock/Automation/AutomationSettingsView.swift:3343-4350`
- Modify: `Context-DockTests/IntegrationInventoryTests.swift`

**Interfaces:**
- Consumes: resource arrays and access summaries already composed by the inventory.
- Produces: six resource groups and one access page without adding persistence.
- Preserves: Skills steer only; they are not represented as executable permissions.

- [ ] **Step 1: Add failing resource and access summary tests**

```swift
@Test func resourcesCountIndependentlyAndSkillsAreNonExecutable() throws {
    let app = try #require(
        IntegrationInventoryBuilder.build(from: .fixture(
            adapters: [.fixture(bundleID: "com.example.app")],
            skills: [.fixture(name: "Guide")],
            packages: [.fixture(command: "codex")],
            mcpServers: [.fixture(name: "Files")],
            apiConnections: [.fixture(name: "Service")]
        )).apps.first
    )
    #expect(app.counts.skills == 1)
    #expect(app.counts.cliTools == 1)
    #expect(app.counts.mcpServers == 1)
    #expect(app.counts.apiConnections == 1)
    #expect(app.skills.allSatisfy { !$0.grantsExecutionAuthority })
}

@Test func brokenResourceOnlyMarksItsIntegrationNeedsAttention() throws {
    let inventory = IntegrationInventoryBuilder.build(from: .twoAppHealthFixture())
    #expect(inventory.apps[0].health == .needsAttention(["CLI tool is not installed"]))
    #expect(inventory.apps[1].health == .healthy)
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/IntegrationInventoryTests`

Expected: tests fail until resource display models and health derivation exist.

- [ ] **Step 3: Implement Resources with reusable groups**

```swift
struct IntegrationResourceSection<Item: Identifiable, Row: View>: View {
    let title: String
    let count: Int
    let emptyMessage: String
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row
}
```

Render Skills, CLI Tools, MCP Servers, API Connections, Shortcuts, and Context Readers in that order. Empty groups start collapsed and show one contextual Add action when expanded. Move existing row/editor presentation from `AutomationAdapterDetailView` behind explicit inputs and callbacks; do not fork store logic.

- [ ] **Step 4: Implement Access**

Access reads the existing permission status, `AdapterActionConsentStore.revision`, CLI trust, API Keychain implications, and declared resource scopes. It provides existing revoke flows and a destructive Remove Integration confirmation. Resolve a removal preview before presenting:

```swift
struct IntegrationRemovalPreview: Equatable {
    let removedActionCount: Int
    let unlinkedSkillCount: Int
    let unlinkedCLIToolCount: Int
    let unlinkedMCPCount: Int
    let removedAPIConnectionCount: Int
    let retainedSharedResourceNames: [String]
}
```

The confirmation must distinguish deleted app-owned records from shared resources that are merely unlinked or retained.

- [ ] **Step 5: Run verification**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/IntegrationInventoryTests
git diff --check
./scripts/dev-run.sh
```

Expected: every resource count and row matches the old Tools view; toggles and editors persist through existing stores; revoking access updates immediately; one broken resource does not mark sibling integrations unhealthy.

- [ ] **Step 6: Commit only Task 5 files**

```bash
git add Context-Dock/UI/Settings/Integrations/AppIntegrationResourcesView.swift Context-Dock/UI/Settings/Integrations/AppIntegrationAccessView.swift Context-Dock/UI/Settings/Integrations/AppIntegrationDetailView.swift Context-Dock/UI/Settings/Integrations/IntegrationModels.swift Context-Dock/UI/Settings/Integrations/IntegrationInventoryBuilder.swift Context-Dock/Automation/AutomationSettingsView.swift Context-DockTests/IntegrationInventoryTests.swift
git commit -m "feat(settings): add integration resources and access"
```

Stop for user verification.

---

### Task 6: Global workspace and contextual Add menu

**Files:**
- Create: `Context-Dock/UI/Settings/Integrations/GlobalIntegrationDetailView.swift`
- Create: `Context-Dock/UI/Settings/Integrations/IntegrationAddMenu.swift`
- Create: `Context-DockTests/IntegrationAddMenuTests.swift`
- Modify: `Context-Dock/UI/Settings/Integrations/IntegrationsSettingsPage.swift`
- Modify: `Context-Dock/Automation/AutomationSettingsView.swift:511-915,973-1024,1151-1215,1451-1745`

**Interfaces:**
- Consumes: `GlobalIntegrationSummary` and existing command, selection, CLI, MCP, and import editors.
- Produces: `IntegrationAddAction.available(scope:tab:)` and `IntegrationAddMenu`.
- Preserves: selection-aware extensions and legacy AX rules as separately typed rows.

- [ ] **Step 1: Write failing Add-menu tests**

```swift
import Testing
@testable import Context_Dock

@Suite("Integration Add menu")
struct IntegrationAddMenuTests {
    @Test func appResourcesOfferOnlyAppResourceActions() {
        #expect(IntegrationAddAction.available(scope: .apps, tab: .resources) == [
            .addSkill, .addCLITool, .addMCPServer, .connectAPI, .linkShortcut,
        ])
    }

    @Test func globalActionsOfferCommandsAndSelectionActions() {
        #expect(IntegrationAddAction.available(scope: .global, tab: .actions) == [
            .addCommand, .addSelectionAction,
        ])
    }

    @Test func globalResourcesDoNotOfferAppOnlyAPIOrSkill() {
        let actions = IntegrationAddAction.available(scope: .global, tab: .resources)
        #expect(actions == [.addCLITool, .addMCPServer])
    }
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `./scripts/test.sh -only-testing:Context-DockTests/IntegrationAddMenuTests`

Expected: compilation fails because `IntegrationAddAction` does not exist.

- [ ] **Step 3: Implement deterministic Add actions**

```swift
enum IntegrationAddAction: String, CaseIterable, Equatable {
    case chooseApp, importIntegration, addAction, addSkill, addCLITool
    case addMCPServer, connectAPI, linkShortcut, addCommand, addSelectionAction

    static func available(
        scope: IntegrationScope,
        tab: IntegrationDetailTab
    ) -> [IntegrationAddAction] {
        switch (scope, tab) {
        case (.apps, .actions): return [.addAction, .importIntegration]
        case (.apps, .resources):
            return [.addSkill, .addCLITool, .addMCPServer, .connectAPI, .linkShortcut]
        case (.apps, _): return [.chooseApp, .importIntegration]
        case (.global, .actions): return [.addCommand, .addSelectionAction]
        case (.global, .resources): return [.addCLITool, .addMCPServer]
        case (.global, _): return [.addCommand, .addSelectionAction, .addCLITool, .addMCPServer]
        }
    }
}
```

- [ ] **Step 4: Implement Global detail by reusing existing editors**

Present Global Actions and Resources with the same section and status grammar as Apps. Commands and selection actions remain separate subsections. Global CLI uses `TerminalPackageManager.isUserAddedGlobalScope`; do not expose all PATH-discovered binaries. Global MCP includes only servers intentionally configured for global use according to the existing representation; if no global MCP representation exists, show the empty state and preserve Add MCP behind the existing supported storage contract rather than inventing one inside the view.

- [ ] **Step 5: Wire the Add menu to existing flows**

`IntegrationAddMenu` receives `[IntegrationAddAction]` plus one callback:

```swift
struct IntegrationAddMenu: View {
    let actions: [IntegrationAddAction]
    let perform: (IntegrationAddAction) -> Void
}
```

Map each action to the current chooser, editor, or importer. Rename visible `Import Adapter…` copy to `Import Integration…`; the file picker/preview may identify the selected artifact as an adapter pack.

- [ ] **Step 6: Run verification**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/IntegrationAddMenuTests
./scripts/test.sh -only-testing:Context-DockTests/IntegrationInventoryTests
git diff --check
./scripts/dev-run.sh
```

Expected: the Add menu changes predictably with scope/tab; every old creation flow remains reachable; Global contains only deliberately granted capabilities.

- [ ] **Step 7: Commit only Task 6 files**

```bash
git add Context-Dock/UI/Settings/Integrations/GlobalIntegrationDetailView.swift Context-Dock/UI/Settings/Integrations/IntegrationAddMenu.swift Context-Dock/UI/Settings/Integrations/IntegrationsSettingsPage.swift Context-Dock/UI/Settings/Integrations/IntegrationModels.swift Context-Dock/Automation/AutomationSettingsView.swift Context-DockTests/IntegrationAddMenuTests.swift
git commit -m "feat(settings): consolidate global integrations"
```

Stop for user verification.

---

### Task 7: Sidebar cutover, deep links, accessibility, and cleanup

**Files:**
- Modify: `Context-Dock/UI/Settings/SettingsModels.swift:3-174`
- Modify: `Context-Dock/UI/Settings/SettingsSidebar.swift:3-62`
- Modify: `Context-Dock/UI/Settings/SettingsView.swift:4-38`
- Modify: `Context-Dock/UI/GeneralChatStartView.swift:245-254`
- Modify: every additional `.openSettingsPage` caller returned by `graft grep "openSettingsPage"` or, if Graft remains unavailable, `rg -n "openSettingsPage" Context-Dock Context-DockTests`
- Modify: integration views created in Tasks 3–6
- Modify: `Context-DockTests/IntegrationRouteTests.swift`

**Interfaces:**
- Consumes: typed routes and parity-complete Integrations workspace.
- Produces: one visible Integrations sidebar row and compatible hidden legacy routes.
- Preserves: raw legacy enum cases until exhaustive caller migration proves they are unused.

- [ ] **Step 1: Extend route tests for typed payloads and legacy raw values**

```swift
@Test func appDeepLinkPreservesBundleAndTab() {
    let route = IntegrationDestination(
        scope: .apps,
        bundleID: "com.openai.codex",
        tab: .resources,
        focus: .mcpServers
    )
    let payload = SettingsRouteResolver.notificationPayload(for: route)
    #expect(SettingsRouteResolver.destination(from: payload) == route)
}

@Test func legacyRawValueStillResolves() {
    let payload: [AnyHashable: Any] = ["page": SettingsPage.frontmostAppAdapters.rawValue]
    #expect(SettingsRouteResolver.destination(from: payload)?.scope == .apps)
}
```

- [ ] **Step 2: Run tests and verify the typed-payload test fails**

Run: `./scripts/test.sh -only-testing:Context-DockTests/IntegrationRouteTests`

Expected: failure because typed notification payload encode/decode is absent.

- [ ] **Step 3: Centralize notification payload compatibility**

Add stable keys and encode the destination as primitive user-info values:

```swift
static func notificationPayload(for destination: IntegrationDestination) -> [AnyHashable: Any] {
    var payload: [AnyHashable: Any] = [
        "page": SettingsPage.integrations.rawValue,
        "integrationScope": destination.scope.rawValue,
        "integrationTab": destination.tab.rawValue,
    ]
    payload["bundleID"] = destination.bundleID
    payload["integrationFocus"] = destination.focus?.rawValue
    return payload
}
```

`SettingsView` is the only decoder. It selects `.integrations` and updates the destination atomically.

- [ ] **Step 4: Cut over the sidebar and callers**

Replace the Extensions section with one Integrations row. Keep the old `SettingsPage` cases out of `SettingsSidebarSection.all`, but retain their enum raw values for compatibility. Migrate every known caller to the typed payload helper. Use exhaustive search, because ranked graph queries are not sufficient for every caller.

- [ ] **Step 5: Complete accessibility and responsive behavior**

Add accessibility labels/values for scope, app status, counts, health, toggles, and destructive controls. Verify focus order: Settings sidebar → scope → search → integration list → tabs → content. At narrow width, collapse the integration browser with `NavigationSplitView` behavior and keep an explicit Back route; do not hide it by clipping.

- [ ] **Step 6: Remove only superseded rendering**

After manual parity, remove the old app/global page switch branches and private view fragments from `AutomationSettingsView.swift`. Retain unrelated automation categories, editors, models, and runtime code. Do not delete a helper until `rg` proves it has no remaining callers and focused tests pass.

- [ ] **Step 7: Run verification**

Run:

```bash
./scripts/test.sh -only-testing:Context-DockTests/IntegrationRouteTests
./scripts/test.sh -only-testing:Context-DockTests/IntegrationInventoryTests
./scripts/test.sh -only-testing:Context-DockTests/IntegrationSelectionTests
./scripts/test.sh -only-testing:Context-DockTests/IntegrationAddMenuTests
git diff --check
./scripts/dev-run.sh
```

Manual checks:

- Open every former sidebar destination through its old deep link.
- Navigate the entire page with keyboard only.
- Read status/count/toggle rows with VoiceOver.
- Check increased contrast and reduced motion.
- Check light/dark appearance at narrow and wide window sizes.
- Verify one populated app, empty app, partially broken app, empty Global, and populated Global.

- [ ] **Step 8: Commit only Task 7 files**

```bash
git add Context-Dock/UI/Settings/SettingsModels.swift Context-Dock/UI/Settings/SettingsSidebar.swift Context-Dock/UI/Settings/SettingsView.swift Context-Dock/UI/Settings/Integrations/IntegrationModels.swift Context-Dock/UI/Settings/Integrations/IntegrationsSettingsPage.swift Context-Dock/UI/Settings/Integrations/IntegrationBrowserView.swift Context-Dock/UI/Settings/Integrations/AppIntegrationDetailView.swift Context-Dock/UI/Settings/Integrations/AppIntegrationOverviewView.swift Context-Dock/UI/Settings/Integrations/AppIntegrationActionsView.swift Context-Dock/UI/Settings/Integrations/AppIntegrationResourcesView.swift Context-Dock/UI/Settings/Integrations/AppIntegrationAccessView.swift Context-Dock/UI/Settings/Integrations/GlobalIntegrationDetailView.swift Context-Dock/UI/Settings/Integrations/IntegrationAddMenu.swift Context-Dock/UI/GeneralChatStartView.swift Context-Dock/Automation/AutomationSettingsView.swift Context-DockTests/IntegrationRouteTests.swift
git commit -m "refactor(settings): cut over to integrations workspace"
```

Before committing, inspect `git diff --cached --name-only`; every staged path must be one of
the explicit Task 7 paths or another deep-link caller named by that task's exhaustive search.

Stop for user verification.

---

### Task 8: Full regression proof and graph refresh

**Files:**
- Modify only files required by failures directly caused by Tasks 1–7.
- Update: `graphify-out/` via the repository command; dirty graph outputs are expected.

**Interfaces:**
- Consumes: completed workspace and all focused test suites.
- Produces: final build/test/manual evidence without expanding feature scope.

- [ ] **Step 1: Run the complete offline suite**

Run: `./scripts/test.sh`

Expected: all tests pass. If an unrelated baseline failure exists, record its exact test and prove it also fails on the pre-task commit before classifying it as unrelated.

- [ ] **Step 2: Run static diff checks**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only intentional task paths plus pre-existing user changes appear.

- [ ] **Step 3: Refresh repository graphs**

Run:

```bash
graphify update .
graft build
```

If the `graft` executable is still unavailable, record that limitation and do not substitute invented graph evidence. Graphify update must still complete.

- [ ] **Step 4: Perform the final required build and relaunch**

Run: `./scripts/dev-run.sh`

Expected: Debug build succeeds in `.build/XcodeDerivedData` and that exact app relaunches.

- [ ] **Step 5: Perform final manual acceptance**

Verify:

- a new user can find all capabilities for ChatGPT from Integrations → Apps → ChatGPT;
- app/global scope never mixes authority;
- every resource is reachable within two selections after Integrations;
- missing CLI, disconnected MCP, invalid API, and missing permission statuses are local to their resource;
- creation/import, editing, toggling, and removal preserve existing behavior;
- no Settings route opens Media Dock, chat, or Developer Inspector content.

- [ ] **Step 6: Resolve failures through their owning task**

Do not create a catch-all verification commit. If verification exposes a regression, return
to the task that owns the affected file, repeat that task's focused red/green cycle, and use
its explicit staging list. When no fixes are required, report test counts, build result,
manual scenarios, Graphify/Graft results, and remaining pre-existing working-tree changes.
