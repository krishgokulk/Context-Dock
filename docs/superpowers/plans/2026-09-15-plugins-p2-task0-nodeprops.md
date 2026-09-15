# Phase 2 Task 0 — `PluginNode.nodeProps` (closes #27) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. One task, TDD, commit at the end.

**Goal:** make node-valued props first-class on `PluginNode`, so the schema validates inside a list's `row` template and the renderer reads it as a lookup instead of a JSON round-trip.

**Architecture:** one stored property, one predicate that lives in `PluginComponentCatalog` (already the single list of component names), `children` semantics untouched. `flattened` gains the node-prop subtrees, so every existing schema rule reaches row contents with no new walk.

**Spec:** `docs/superpowers/specs/2026-09-15-plugins-design.md` §6, §7. Issue: #27. Runs before Task 1 of `docs/superpowers/plans/2026-09-15-plugins-p2-renderer.md`.

## Global constraints

- Swift 5.0, macOS 26.1, Foundation only. Tests swift-testing, `@MainActor` suite, flat in `Context-DockTests/`.
- Work in the worktree; `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins &&` on every command. Stage explicit paths. Never `git add -A`.
- `./scripts/test.sh -only-testing:Context-DockTests/<Suite>` while iterating, whole suite once before committing. Two known pre-existing failures (`PriorityAdapterContractTests/priorityTypedCapabilitiesDeclareTheExpectedRisk`, `AppChatPromptTests/anIdlePromptShrinksToTheAppIcon`); a third means stop.
- `scripts/test.sh` refuses while Context-Dock.app runs. If it does, STOP and report NEEDS_CONTEXT — never quit or launch an app, another person is using it.

## The two shapes, and why the obvious predicate is wrong

A node-valued prop appears in manifests in **two** spellings, and an earlier reading of this issue
only saw the first:

```jsonc
// 1. the value is itself a node — a single-key object whose key names a component
"detail": { "markdown": "{{item.body}}" }

// 2. the PROP KEY names the component and the value is that component's props
"row": { "title": "{{item.title}}", "subtitle": "{{item.subtitle}}", "action": "rowAction" }
```

Shape 2 is what `PluginMigration` emits for every converted `provider:custom` list
(`PluginMigration.swift`, the `row` dictionary) and what the Phase 2 plan's examples use, so a
predicate that only recognises shape 1 would miss every real row template and silently change
nothing. Both must be recognised.

A prop that is an object but matches neither shape — `{ "markdown": "x", "metadata": [] }`, two
keys, neither naming this prop's component — stays an ordinary `PluginValue` prop. That is the
data contract for a list item's `detail`, not a view node, and promoting it would be wrong.

---

### Task 0: `nodeProps`

**Files:**
- Modify: `Context-Dock/Services/Plugins/PluginComponentCatalog.swift` (add `cell`; add the predicate)
- Modify: `Context-Dock/Services/Plugins/PluginNode.swift` (the stored property, decode, encode, `flattened`)
- Modify: `docs/architecture/PLUGINS.md` (the catalog's role — see below)
- Test: `Context-DockTests/PluginNodePropsTests.swift` (new)
- Test: `Context-DockTests/PluginSchemaTests.swift` (append two)

**Documentation change, and it is not cosmetic.** `PLUGINS.md` currently calls the catalog "the
single list of component names". After this task the catalog decides which props are view nodes,
so **whatever the predicate cannot see, the schema cannot validate** — a template component
missing from the catalog is a template nobody checks. Change that line to say so, in the Rules
section beside "One renderer, many hosts":

> **The catalog is load-bearing for validation, not just for naming.** `PluginComponentCatalog`
> decides which props hold view nodes (`row`, `cell`, `detail`), and the schema only validates
> what it can see — a component missing from the catalog is a template nobody checks. Adding a
> component means adding it to the catalog first.

**Interfaces produced** (Phase 2 tasks are written against these):

```swift
extension PluginComponentCatalog {
    /// A prop is node-valued when the prop key names a component and the value is an object
    /// (`"row": { … }`), or when the value is itself a node (`"detail": { "markdown": … }`).
    /// Returns the node it denotes, or nil when the prop is ordinary data.
    static func nodeProp(key: String, value: PluginValue) -> PluginNode?
}

extension PluginNode {
    /// View nodes held in props rather than in `children`: a list's `row`, a grid's `cell`,
    /// a listDetail's `detail`. They are templates — instantiated per item, never drawn once —
    /// so they are deliberately NOT children. Keyed by the prop name so a diagnostic can say
    /// `row` rather than an index.
    var nodeProps: [String: PluginNode] { get }
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginNodePropsTests.swift
// A list's `row` is a template: instantiated per item, never drawn once. It lives in props,
// not children — but the schema still has to see inside it, which is #27. These pin both
// spellings a manifest uses for such a prop, and pin that `children` is unchanged.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Plugin node props")
@MainActor
struct PluginNodePropsTests {

    private func node(_ json: String) throws -> PluginNode {
        try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
    }

    @Test("A prop whose key names a component is that component with those props")
    func propKeyNamesTheComponent() throws {
        let n = try node(#"{ "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}", "action": "open" } } }"#)
        let row = try #require(n.nodeProps["row"])
        #expect(row.component == "row")
        #expect(row.props["title"] == .string("{{item.title}}"))
        #expect(row.props["action"] == .string("open"))
    }

    @Test("A prop whose value is itself a node is that node")
    func propValueIsANode() throws {
        let n = try node(#"{ "listDetail": { "detail": { "markdown": "{{item.body}}" } } }"#)
        let detail = try #require(n.nodeProps["detail"])
        #expect(detail.component == "markdown")
        #expect(detail.props["text"] == nil)
        #expect(detail.props["markdown"] == nil || detail.component == "markdown")
    }

    @Test("An object prop that is neither shape stays ordinary data")
    func ordinaryObjectPropIsNotANode() throws {
        let n = try node(#"{ "row": { "trailing": { "kind": "chip", "label": "4k" } } }"#)
        #expect(n.nodeProps["trailing"] == nil)
        #expect(n.props["trailing"]?.objectValue?["label"] == .string("4k"))
    }

    @Test("A string prop is never a node")
    func stringPropIsNotANode() throws {
        let n = try node(#"{ "list": { "filter": "local", "items": "{{lines}}" } }"#)
        #expect(n.nodeProps.isEmpty)
    }

    @Test("children keeps its exact meaning: a node with only node-props has no children")
    func childrenUnchanged() throws {
        let n = try node(#"{ "list": { "row": { "title": "a" } } }"#)
        #expect(n.children.isEmpty)
        let stack = try node(#"{ "vstack": [ { "title": "a" }, { "divider": {} } ] }"#)
        #expect(stack.children.map(\.component) == ["title", "divider"])
        #expect(stack.nodeProps.isEmpty)
    }

    @Test("flattened walks node props as well as children, so the schema reaches them")
    func flattenedIncludesNodeProps() throws {
        let n = try node(#"{ "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}" } } }"#)
        #expect(n.flattened.map(\.component).sorted() == ["list", "row"])
    }

    @Test("A node prop round-trips through encode")
    func roundTrip() throws {
        let n = try node(#"{ "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}" } } }"#)
        let again = try JSONDecoder().decode(PluginNode.self, from: JSONEncoder().encode(n))
        #expect(again == n)
        #expect(again.nodeProps["row"]?.props["title"] == .string("{{item.title}}"))
    }

    @Test("A migrated custom-list manifest exposes its row template")
    func migratedListExposesItsRow() throws {
        let command = SystemCommand(
            name: "Ports", icon: "network", keywords: ["ports", "provider:custom", "refresh:3"],
            scriptType: "bash", script: "echo '{}'",
            undoScriptType: "bash", undoScript: "kill $CD_ROW_ID")
        let manifest = PluginMigration.manifest(from: command)
        let list = try #require(manifest.views.panel?.root)
        let row = try #require(list.nodeProps["row"])
        #expect(row.props["action"] == .string("rowAction"))
    }
}
```

Append to `Context-DockTests/PluginSchemaTests.swift`, inside the existing `@Suite("Plugin schema")` struct — these are the point of the whole task:

```swift
    @Test("A row action that is not declared is an error the schema now sees")
    func rowActionMustBeDeclared() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "list": { "items": "{{lines}}", "row": { "title": "{{item.title}}", "action": "nope" } } } } }"#)
        #expect(errors(m).contains { $0.contains("action \"nope\" is not declared") })
    }

    @Test("An unknown component inside a row template is an error")
    func unknownComponentInsideARow() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "list": { "items": "{{lines}}", "row": { "hologram": {} } } } } }"#)
        #expect(errors(m).contains { $0.contains("unknown component \"hologram\"") })
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginNodePropsTests`
Expected: compile failure — `nodeProps` undefined.

- [ ] **Step 3: Add `cell` and the predicate to the catalog**

`cell` joins the leaves beside `row`: a grid draws one per item exactly as a list draws a row, and the predicate's first shape is keyed on the catalog, so a template component that is missing from the catalog is a template the schema cannot see.

```swift
// in PluginComponentCatalog, alongside the existing leaves
        "row", "cell", "checkRow", "eventRow", "activityRow", "fileRow", "compareRow",
```

```swift
extension PluginComponentCatalog {
    /// A prop is node-valued in one of two spellings:
    ///   "row":    { "title": … }        the prop key names the component
    ///   "detail": { "markdown": … }     the value is itself a node
    /// Anything else — a string, an array, an object matching neither — is ordinary data and
    /// stays a PluginValue. The data contract for a list item's `detail`
    /// ({ "markdown": …, "metadata": [ … ] }) matches neither and must not be promoted.
    static func nodeProp(key: String, value: PluginValue) -> PluginNode? {
        guard let object = value.objectValue else { return nil }
        if isKnown(key) {
            return PluginNode(component: key, props: object)
        }
        if object.count == 1, let inner = object.first, isKnown(inner.key),
           let innerObject = inner.value.objectValue {
            return PluginNode(component: inner.key, props: innerObject)
        }
        return nil
    }
}
```

- [ ] **Step 4: Add `nodeProps` to `PluginNode`**

Store it at decode time beside `props`. **Leave `props` intact** — a node prop stays readable as
raw data too, so nothing existing breaks and `encode` needs no special case. Add it to the
memberwise `init` with a default of `[:]`, computed from `props` when not supplied, so
`PluginNode(component:props:)` callers (the migration, the tests) get node props for free.

```swift
    let nodeProps: [String: PluginNode]

    init(component: String, props: [String: PluginValue] = [:], children: [PluginNode] = []) {
        self.component = component
        self.props = props
        self.children = children
        self.nodeProps = Self.nodeProps(from: props)
    }

    private static func nodeProps(from props: [String: PluginValue]) -> [String: PluginNode] {
        props.reduce(into: [:]) { out, pair in
            if let node = PluginComponentCatalog.nodeProp(key: pair.key, value: pair.value) {
                out[pair.key] = node
            }
        }
    }
```

In `init(from:)`, set `nodeProps = Self.nodeProps(from: props)` in every branch after `props` is
final (the `.object` branch after `children` is removed, and the shorthand branches where it is
empty). `Equatable` stays synthesized — `nodeProps` is derived from `props`, so it cannot
disagree.

`flattened` gains the node-prop subtrees. Order: self, then children, then node props sorted by
key so the walk is deterministic:

```swift
    /// Every node in the tree, depth first, self included — children and node props alike,
    /// so a validator that walks this reaches a list's row template (#27).
    var flattened: [PluginNode] {
        [self] + children.flatMap(\.flattened)
            + nodeProps.sorted { $0.key < $1.key }.flatMap { $0.value.flattened }
    }
```

- [ ] **Step 5: Run to verify pass**

Run: `cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginNodePropsTests`
Expected: 8 tests pass, named.

Then: `./scripts/test.sh -only-testing:Context-DockTests/PluginSchemaTests` — expect the existing
suite plus the two new tests, all passing.

**If an existing schema test now fails because the schema reaches further than it used to, that
is the task working.** Do not weaken the new reach. Read the failure: if a fixture contained an
undeclared action inside a row, fix the fixture; if a real rule is now firing where it should
not, stop and report which.

- [ ] **Step 6: Whole suite, then commit**

Run: `./scripts/test.sh` — expect the two known pre-existing failures only.

```bash
cd /Users/gokulakannan/Developer/Context-Dock/.claude/worktrees/plugins
git add Context-Dock/Services/Plugins/PluginComponentCatalog.swift Context-Dock/Services/Plugins/PluginNode.swift Context-DockTests/PluginNodePropsTests.swift Context-DockTests/PluginSchemaTests.swift
git commit -m "feat(plugins): node-valued props are first-class, so the schema sees inside a row

A list's row is a template — instantiated per item, never drawn once — so it lives
in props rather than children, and the schema never walked into it: a row action
naming nothing passed install silently. nodeProps exposes both spellings a manifest
uses (the prop key naming the component, or the value being a node), flattened walks
them, and every existing rule reaches row contents with no new walk. children keeps
its exact meaning.

Closes #27.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
