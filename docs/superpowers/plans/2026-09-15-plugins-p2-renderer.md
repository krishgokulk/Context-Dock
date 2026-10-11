# Plugins Phase 2 — component kit and `PluginRenderer` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** one native renderer that turns any `PluginManifest` view tree into SwiftUI, identically in the dock sheet, the corner panel, the dock strip, a detached window and the Creator preview — with heights that are a pure function of manifest + traits, never a measurement.

**Architecture:** three pure types carry the phase — `PluginBinding` resolves `{{ }}` against script JSON, `HostTraits` says which host is asking, `PluginSizing` answers how tall the tree is. `PluginRenderer` is a thin `switch` over `PluginNode.component` into one small view per component; components own their Liquid Glass styling and read tokens from `PluginKit`, so a manifest picks and binds but never styles. Actions leave through a `PluginActionSink` protocol that Phase 3 implements and this phase fakes, so no component ever calls a runtime that does not exist yet.

**Tech Stack:** Swift 5, SwiftUI, swift-testing. New folder `Context-Dock/UI/Plugins/` with `Components/` beneath it (both auto-added by the synchronized group). Tests flat in `Context-DockTests/`.

**Spec:** `docs/superpowers/specs/2026-09-15-plugins-design.md` §5 (presentations and hosts), §6 (component kit), §7 (manifest and binding). Roadmap entry: `docs/superpowers/plans/2026-09-15-plugins-todo.md` "Phase 2". Truth file: `docs/architecture/PLUGINS.md`.

**Depends on:** Phase 1 landed on branch `plugins` (`PluginManifest`, `PluginNode`, `PluginValue`, `PluginComponentCatalog`, `PluginSchema`). Do not start against an unmerged Phase 1 — those types were still moving under review on 2026-09-15.

## Global Constraints

- Deployment target macOS 26.1; Swift 5.0; project-wide `@MainActor` default is **not** set — mark SwiftUI-touching test suites `@MainActor` as the existing ones do.
- Build: `./scripts/build-debug.sh` from the worktree root. Tests: `./scripts/test.sh`; confirm the named suites ran (memory `test-script-can-report-stale-green`). The shell cwd reverts between calls — `cd` into the worktree in every command and print `pwd` (memory `worktree-cwd-reverts-between-tool-calls`).
- **Corner size is pure.** Every height comes from `PluginSizing` — a function of manifest, binding and traits. No `GeometryReader`-measured height may feed a corner shell size (memory `corner-pill-size-must-be-pure`).
- **No host forks a component.** If a host needs something different, it passes different `HostTraits`; it never renders its own copy of a component.
- A manifest never styles. Components read `PluginKit` tokens and `Theme` (`Context-Dock/UI/DesignTokens.swift`); no component hardcodes `Color.white.opacity(…)`.
- Nothing in this phase runs a script, reads the network or touches disk. Data arrives as `[String: PluginValue]`; in tests and previews it is the manifest's `sample`.
- Stage explicit paths only; commit after every task. Never `git add -A` — other sessions work this repo.
- Names fixed here are used by P3–P8: `HostTraits`, `PluginWidthClass`, `PluginLiveBudget`, `PluginBinding`, `PluginSizing`, `PluginKit`, `PluginRenderer`, `PluginActionSink`, `PluginActionRequest`, `PluginCompactRules`.

---

## File structure

| File | Responsibility |
|---|---|
| `Context-Dock/UI/Plugins/HostTraits.swift` | which host is asking: presentation, width class, keyboard owner, live budget, width, max height |
| `Context-Dock/UI/Plugins/PluginBinding.swift` | `{{ }}` resolution over script JSON; row (`item.*`) scoping; text/bool/items readers |
| `Context-Dock/UI/Plugins/PluginKit.swift` | the kit's tokens: gaps, paddings, per-component heights, corner radii |
| `Context-Dock/UI/Plugins/PluginSizing.swift` | pure height of a node and of a tree, clamped to the host |
| `Context-Dock/UI/Plugins/PluginActionSink.swift` | how a component asks for an action to run; recording fake for tests/previews |
| `Context-Dock/UI/Plugins/PluginRenderer.swift` | the `switch` from `PluginNode` to a component view; diagnostics and unknown-component fallback |
| `Context-Dock/UI/Plugins/PluginCompactRules.swift` | corner transforms: split→push, grid column drop, metadata stacking |
| `Context-Dock/UI/Plugins/Components/PluginStateViews.swift` | `emptyState`, `loading`, diagnostics list |
| `Context-Dock/UI/Plugins/Components/PluginPanelViews.swift` | `list`, `row`, `section`, `actionPanel` |
| `Context-Dock/UI/Plugins/Components/PluginDetailViews.swift` | `listDetail`, `detail`, `grid`, `form` |
| `Context-Dock/UI/Plugins/Components/PluginContainers.swift` | `card`, `vstack`, `hstack`, `grid` container, `divider`, `footerCard`, `capsule` |
| `Context-Dock/UI/Plugins/Components/PluginText.swift` | `title`, `subtitle`, `body`, `caption`, `markdown`, `stat`, `header` |
| `Context-Dock/UI/Plugins/Components/PluginControls.swift` | `button`, `iconButton`, `buttonRow`, `toggle`, `slider`, `stateButton` |
| `Context-Dock/UI/Plugins/Components/PluginChips.swift` | `tag`, `statusBadge`, `chipRow`, `segment` |
| `Context-Dock/UI/Plugins/Components/PluginCards.swift` | `card` body styles, `stat`, `eventRow`, `activityRow`, `fileRow`, `checkRow`, `compareRow` |
| `Context-Dock/UI/Plugins/Components/PluginLive.swift` | `progress`, `timer`, `waveform`, `liveText`, `pulse` |
| `Context-Dock/UI/Plugins/Components/PluginMedia.swift` | `mediaCard`, `thumbnail`, `avatar` |
| `Context-Dock/UI/Plugins/Components/PluginInput.swift` | `textField`, `searchField`, `dropzone`, `ai` |
| `Context-Dock/UI/Plugins/PluginPreviewHarness.swift` | renders one manifest in all five traits from `sample`; used by the Developer Inspector |
| `Context-DockTests/PluginBindingTests.swift` | resolution, row scope, interpolation, missing keys |
| `Context-DockTests/PluginSizingTests.swift` | per-component heights, container arithmetic, clamping, purity |
| `Context-DockTests/PluginRendererTests.swift` | component coverage, unknown component, action routing, diagnostics |
| `Context-DockTests/PluginCompactRulesTests.swift` | the corner transforms |

---

### Task 1: `HostTraits` and `PluginBinding`

**Files:**
- Create: `Context-Dock/UI/Plugins/HostTraits.swift`
- Create: `Context-Dock/UI/Plugins/PluginBinding.swift`
- Test: `Context-DockTests/PluginBindingTests.swift`

**Interfaces:**
- Produces: `enum PluginWidthClass { case regular, compact }`, `enum PluginLiveBudget { case full, low, none }`.
- Produces: `struct HostTraits: Equatable` with `presentation: PluginPresentation`, `widthClass: PluginWidthClass`, `keyboardOwner: Bool`, `liveBudget: PluginLiveBudget`, `width: CGFloat`, `maxHeight: CGFloat`, and the five host constructors `dockSheet`, `cornerPanel`, `strip(_:)`, `window(_:screenHeight:)`, `creatorPreview(_:)`.
- Produces: `struct PluginBinding: Equatable` with `init(data:item:)`, `resolve(_:) -> PluginValue`, `text(_:) -> String`, `bool(_:) -> Bool`, `number(_:) -> Double?`, `items(_:) -> [PluginValue]`, `scoped(to:) -> PluginBinding`.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginBindingTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginBindingTests {
    private let data: [String: PluginValue] = [
        "room": .string("Kitchen"),
        "volume": .number(37),
        "playing": .bool(true),
        "queue": .array([
            .object(["title": .string("Jungle"), "artist": .string("Casio")]),
            .object(["title": .string("For Ever")]),
        ]),
        "now": .object(["track": .object(["title": .string("Deep")])]),
    ]

    @Test func aWholeStringBindingBecomesItsValue() {
        let binding = PluginBinding(data: data)
        #expect(binding.resolve(.string("{{room}}")) == .string("Kitchen"))
        #expect(binding.resolve(.string("{{volume}}")) == .number(37))
        #expect(binding.resolve(.string("{{playing}}")) == .bool(true))
    }

    @Test func aLiteralStringIsLeftAlone() {
        #expect(PluginBinding(data: data).resolve(.string("Up next")) == .string("Up next"))
    }

    @Test func aDottedPathWalksObjectsAndArrays() {
        let binding = PluginBinding(data: data)
        #expect(binding.resolve(.string("{{now.track.title}}")) == .string("Deep"))
        #expect(binding.resolve(.string("{{queue.1.title}}")) == .string("For Ever"))
        #expect(binding.resolve(.string("{{queue.9.title}}")) == .null)
    }

    @Test func aMissingKeyIsNullAndReadsAsEmptyText() {
        let binding = PluginBinding(data: data)
        #expect(binding.resolve(.string("{{nope}}")) == .null)
        #expect(binding.text(.string("{{nope}}")) == "")
    }

    @Test func itemScopeResolvesRowBindingsAndKeepsOuterData() {
        let row = PluginValue.object(["title": .string("Jungle"), "artist": .string("Casio")])
        let binding = PluginBinding(data: data, item: row)
        #expect(binding.resolve(.string("{{item.title}}")) == .string("Jungle"))
        #expect(binding.resolve(.string("{{room}}")) == .string("Kitchen"))
    }

    @Test func itemBindingsAreNullOutsideARow() {
        #expect(PluginBinding(data: data).resolve(.string("{{item.title}}")) == .null)
    }

    @Test func aBindingInsideASentenceIsInterpolated() {
        let binding = PluginBinding(data: data)
        #expect(binding.text(.string("Playing in {{room}}")) == "Playing in Kitchen")
        #expect(binding.text(.string("{{room}} · {{volume}}%")) == "Kitchen · 37%")
    }

    @Test func wholeNumbersPrintWithoutADecimalPoint() {
        let binding = PluginBinding(data: data)
        #expect(binding.text(.string("{{volume}}")) == "37")
        #expect(binding.text(.number(1.5)) == "1.5")
    }

    @Test func nestedStructuresResolveThroughout() {
        let binding = PluginBinding(data: data)
        let resolved = binding.resolve(
            .object(["a": .string("{{room}}"), "b": .array([.string("{{volume}}")])]))
        #expect(resolved == .object(["a": .string("Kitchen"), "b": .array([.number(37)])]))
    }

    @Test func itemsReadsARepeatedListAndScopesEachRow() {
        let binding = PluginBinding(data: data)
        let items = binding.items(.string("{{queue}}"))
        #expect(items.count == 2)
        #expect(binding.scoped(to: items[0]).text(.string("{{item.artist}}")) == "Casio")
        #expect(binding.items(.string("{{room}}")).isEmpty)
    }

    @Test func boolReadsTruthTheWayAManifestMeansIt() {
        let binding = PluginBinding(data: data)
        #expect(binding.bool(.string("{{playing}}")) == true)
        #expect(binding.bool(.string("{{nope}}")) == false)
        #expect(binding.bool(.number(1)) == true)
        #expect(binding.bool(.string("yes")) == true)
    }

    @Test func eachHostDeclaresItsOwnWidthAndClass() {
        #expect(HostTraits.dockSheet.widthClass == .regular)
        #expect(HostTraits.cornerPanel.widthClass == .compact)
        #expect(HostTraits.window(.wide, screenHeight: 1000).width == 640)
        #expect(HostTraits.window(.narrow, screenHeight: 1000).maxHeight == 700)
        #expect(HostTraits.strip(.icon).liveBudget == .low)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginBindingTests`
Expected: build failure — `cannot find 'PluginBinding' in scope`, `cannot find 'HostTraits' in scope`.

- [ ] **Step 3: Implement `HostTraits`**

```swift
// Context-Dock/UI/Plugins/HostTraits.swift
//
// Which host is asking the renderer to draw. One renderer, many hosts: a host never forks a
// component, it passes different traits. Spec §5.

import CoreGraphics
import Foundation

enum PluginWidthClass: String, Equatable { case regular, compact }

/// How much animation a host can afford right now. The strip drops to `.low` while it is
/// shrunk; a hidden host is `.none` and live components freeze rather than tick unseen.
enum PluginLiveBudget: String, Equatable { case full, low, none }

struct HostTraits: Equatable {
    var presentation: PluginPresentation
    var widthClass: PluginWidthClass
    var keyboardOwner: Bool
    var liveBudget: PluginLiveBudget
    var width: CGFloat
    var maxHeight: CGFloat

    static let dockSheet = HostTraits(
        presentation: .panel, widthClass: .regular, keyboardOwner: true,
        liveBudget: .full, width: 560, maxHeight: 420)

    static let cornerPanel = HostTraits(
        presentation: .panel, widthClass: .compact, keyboardOwner: true,
        liveBudget: .low, width: 380, maxHeight: 360)

    static func strip(_ presentation: PluginPresentation, family: PluginWidgetFamily = .small)
        -> HostTraits
    {
        let size: CGSize
        switch (presentation, family) {
        case (.icon, _): size = CGSize(width: 48, height: 48)
        case (_, .small): size = CGSize(width: 156, height: 156)
        case (_, .medium): size = CGSize(width: 328, height: 156)
        case (_, .large): size = CGSize(width: 328, height: 328)
        }
        return HostTraits(
            presentation: presentation, widthClass: .compact, keyboardOwner: false,
            liveBudget: .low, width: size.width, maxHeight: size.height)
    }

    /// Spec §5: 360 / 480 / 640 wide, content height up to 70 % of the screen.
    static func window(_ width: PluginWindowWidth, screenHeight: CGFloat) -> HostTraits {
        let points: CGFloat
        switch width {
        case .narrow: points = 360
        case .regular: points = 480
        case .wide: points = 640
        }
        return HostTraits(
            presentation: .window, widthClass: width == .narrow ? .compact : .regular,
            keyboardOwner: true, liveBudget: .full,
            width: points, maxHeight: (screenHeight * 0.7).rounded(.down))
    }

    /// The Creator previews any presentation at the size its real host would give it.
    static func creatorPreview(_ presentation: PluginPresentation) -> HostTraits {
        switch presentation {
        case .icon, .widget: return .strip(presentation)
        case .panel: return .dockSheet
        case .window: return .window(.regular, screenHeight: 900)
        }
    }
}
```

- [ ] **Step 4: Implement `PluginBinding`**

```swift
// Context-Dock/UI/Plugins/PluginBinding.swift
//
// The contract between what a script printed and what a view tree says. "{{room}}" is the
// whole of it: a whole-string binding becomes the value itself (so a number stays a number),
// a binding inside a sentence is interpolated as text, and inside a repeated row "{{item.*}}"
// reaches the row while the outer data stays reachable. A key that is not there is `.null`,
// never a crash and never the literal "{{room}}" on screen. Spec §7.

import Foundation

struct PluginBinding: Equatable {
    var data: [String: PluginValue]
    var item: PluginValue?

    init(data: [String: PluginValue] = [:], item: PluginValue? = nil) {
        self.data = data
        self.item = item
    }

    /// The same data, with `item.*` now pointing at this row.
    func scoped(to item: PluginValue) -> PluginBinding {
        PluginBinding(data: data, item: item)
    }

    func value(atPath path: String) -> PluginValue {
        var segments = path.split(separator: ".").map(String.init)
        guard !segments.isEmpty else { return .null }
        var current: PluginValue
        if segments[0] == "item" {
            guard let item else { return .null }
            current = item
            segments.removeFirst()
        } else {
            guard let root = data[segments[0]] else { return .null }
            current = root
            segments.removeFirst()
        }
        for segment in segments {
            switch current {
            case .object(let o):
                guard let next = o[segment] else { return .null }
                current = next
            case .array(let a):
                guard let index = Int(segment), a.indices.contains(index) else { return .null }
                current = a[index]
            default:
                return .null
            }
        }
        return current
    }

    /// Whole-string bindings keep their type; everything else resolves in place.
    func resolve(_ value: PluginValue) -> PluginValue {
        switch value {
        case .string(let raw):
            if let key = value.bindingKey { return self.value(atPath: key) }
            guard raw.contains("{{") else { return value }
            return .string(interpolate(raw))
        case .array(let a):
            return .array(a.map(resolve))
        case .object(let o):
            return .object(o.mapValues(resolve))
        case .number, .bool, .null:
            return value
        }
    }

    func text(_ value: PluginValue?) -> String {
        guard let value else { return "" }
        switch resolve(value) {
        case .string(let s): return s
        case .number(let n):
            return n == n.rounded() && abs(n) < 1e15
                ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        case .array(let a): return a.map { text($0) }.joined(separator: ", ")
        case .object: return ""
        }
    }

    func number(_ value: PluginValue?) -> Double? {
        guard let value else { return nil }
        switch resolve(value) {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// What a manifest means by truth: a bool, a non-zero number, or a word a person would
    /// write in JSON by hand.
    func bool(_ value: PluginValue?) -> Bool {
        guard let value else { return false }
        switch resolve(value) {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return ["true", "yes", "on", "1"].contains(s.lowercased())
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        case .null: return false
        }
    }

    /// A repeated list. Anything that is not an array repeats zero times — a `list` whose
    /// items key is missing is empty, not broken.
    func items(_ value: PluginValue?) -> [PluginValue] {
        guard let value else { return [] }
        if case .array(let a) = resolve(value) { return a }
        return []
    }

    private func interpolate(_ raw: String) -> String {
        var out = ""
        var rest = Substring(raw)
        while let open = rest.range(of: "{{") {
            out += rest[rest.startIndex..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else {
                out += rest[open.lowerBound...]
                return out
            }
            let key = after[after.startIndex..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            out += text(value(atPath: key))
            rest = after[close.upperBound...]
        }
        return out + rest
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginBindingTests`
Expected: PASS, 13 tests, and the suite name `PluginBindingTests` appears in the output.

- [ ] **Step 6: Commit**

```bash
git add Context-Dock/UI/Plugins/HostTraits.swift Context-Dock/UI/Plugins/PluginBinding.swift Context-DockTests/PluginBindingTests.swift
git commit -m "feat(plugins): host traits and the binding that turns script JSON into a view tree"
```

---

### Task 2: `PluginKit` tokens and `PluginSizing`

**Files:**
- Create: `Context-Dock/UI/Plugins/PluginKit.swift`
- Create: `Context-Dock/UI/Plugins/PluginSizing.swift`
- Test: `Context-DockTests/PluginSizingTests.swift`

**Interfaces:**
- Consumes: `HostTraits`, `PluginBinding` (Task 1).
- Produces: `enum PluginKit` with `gap`, `cardPadding`, `cornerRadius`, `rowHeight(_:)`, `leafHeight(_ component:traits:)`, `gridColumns(_ declared:traits:)`.
- Produces: `enum PluginSizing` with `height(of:traits:binding:) -> CGFloat` (one node and its children) and `treeHeight(_:traits:binding:) -> CGFloat` (clamped to `traits.maxHeight`).

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginSizingTests.swift
import CoreGraphics
import Foundation
import Testing

@testable import Context_Dock

struct PluginSizingTests {
    private let empty = PluginBinding()

    private func node(_ json: String) throws -> PluginNode {
        try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
    }

    @Test func aRowIsShorterInTheCorner() throws {
        let row = try node(#"{ "row": { "title": "One" } }"#)
        #expect(PluginSizing.height(of: row, traits: .dockSheet, binding: empty) == 44)
        #expect(PluginSizing.height(of: row, traits: .cornerPanel, binding: empty) == 38)
    }

    @Test func aStackSumsItsChildrenAndTheGapsBetweenThem() throws {
        let stack = try node(#"{ "vstack": [ { "title": "A" }, { "title": "B" } ] }"#)
        let title = PluginKit.leafHeight("title", traits: .dockSheet)
        #expect(
            PluginSizing.height(of: stack, traits: .dockSheet, binding: empty)
                == title * 2 + PluginKit.gap)
    }

    @Test func anHstackIsAsTallAsItsTallestChild() throws {
        let stack = try node(#"{ "hstack": [ { "title": "A" }, { "mediaCard": {} } ] }"#)
        #expect(
            PluginSizing.height(of: stack, traits: .dockSheet, binding: empty)
                == PluginKit.leafHeight("mediaCard", traits: .dockSheet))
    }

    @Test func aCardAddsItsPaddingOnce() throws {
        let card = try node(#"{ "card": [ { "title": "A" } ] }"#)
        #expect(
            PluginSizing.height(of: card, traits: .dockSheet, binding: empty)
                == PluginKit.leafHeight("title", traits: .dockSheet) + PluginKit.cardPadding * 2)
    }

    @Test func aListIsAsTallAsTheRowsItsDataProduces() throws {
        let list = try node(
            #"{ "list": { "items": "{{queue}}", "row": { "title": "{{item.title}}" } } }"#)
        let binding = PluginBinding(data: [
            "queue": .array([.object([:]), .object([:]), .object([:])])
        ])
        #expect(PluginSizing.height(of: list, traits: .dockSheet, binding: binding) == 44 * 3)
    }

    @Test func anEmptyListFallsBackToItsEmptyStateHeight() throws {
        let list = try node(#"{ "list": { "items": "{{queue}}" } }"#)
        #expect(
            PluginSizing.height(of: list, traits: .dockSheet, binding: PluginBinding())
                == PluginKit.leafHeight("emptyState", traits: .dockSheet))
    }

    @Test func aGridIsRowsOfCellsAndTheCornerDropsColumns() throws {
        let grid = try node(
            #"{ "grid": { "columns": 6, "items": "{{photos}}", "cell": { "thumbnail": {} } } }"#)
        let binding = PluginBinding(data: ["photos": .array(Array(repeating: .null, count: 6))])
        // Regular: 6 columns → one row. Compact: clamped to 3 → two rows.
        let cell = PluginKit.leafHeight("thumbnail", traits: .dockSheet)
        #expect(PluginSizing.height(of: grid, traits: .dockSheet, binding: binding) == cell)
        let compactCell = PluginKit.leafHeight("thumbnail", traits: .cornerPanel)
        #expect(
            PluginSizing.height(of: grid, traits: .cornerPanel, binding: binding)
                == compactCell * 2 + PluginKit.gap)
    }

    @Test func aSectionAddsItsHeader() throws {
        let section = try node(#"{ "section": { "header": "Up next", "children": [ { "title": "A" } ] } }"#)
        #expect(
            PluginSizing.height(of: section, traits: .dockSheet, binding: empty)
                == PluginKit.sectionHeaderHeight + PluginKit.gap
                    + PluginKit.leafHeight("title", traits: .dockSheet))
    }

    @Test func anUnknownComponentTakesTheHeightOfItsDiagnosticRow() throws {
        let unknown = try node(#"{ "orbitCluster": { "title": "x" } }"#)
        #expect(
            PluginSizing.height(of: unknown, traits: .dockSheet, binding: empty)
                == PluginKit.diagnosticHeight)
    }

    @Test func aTreeNeverExceedsTheHostsMaxHeight() throws {
        let long = try node(
            #"{ "list": { "items": "{{rows}}", "row": { "title": "{{item.t}}" } } }"#)
        let binding = PluginBinding(data: ["rows": .array(Array(repeating: .object([:]), count: 200))])
        #expect(
            PluginSizing.treeHeight(long, traits: .cornerPanel, binding: binding)
                == HostTraits.cornerPanel.maxHeight)
    }

    @Test func theSameInputsAlwaysGiveTheSameHeight() throws {
        let tree = try node(#"{ "vstack": [ { "row": {} }, { "stat": {} } ] }"#)
        let first = PluginSizing.treeHeight(tree, traits: .dockSheet, binding: empty)
        let second = PluginSizing.treeHeight(tree, traits: .dockSheet, binding: empty)
        #expect(first == second)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginSizingTests`
Expected: build failure — `cannot find 'PluginSizing' in scope`.

- [ ] **Step 3: Implement `PluginKit`**

```swift
// Context-Dock/UI/Plugins/PluginKit.swift
//
// The kit's tokens. Every component's size and spacing comes from here, so a manifest can
// pick and bind but never style, and so `PluginSizing` and the views can never disagree about
// how tall something is — they read the same numbers. Spec §6.

import CoreGraphics
import Foundation

enum PluginKit {
    static let gap: CGFloat = 8
    static let cardPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 12
    static let sectionHeaderHeight: CGFloat = 24
    static let diagnosticHeight: CGFloat = 32

    static func rowHeight(_ traits: HostTraits) -> CGFloat {
        traits.widthClass == .compact ? 38 : 44
    }

    /// The height of a component that has no children. Compact shaves the rows and the media;
    /// text and chips are the same in both, because type does not get smaller in the corner.
    static func leafHeight(_ component: String, traits: HostTraits) -> CGFloat {
        let compact = traits.widthClass == .compact
        switch component {
        case "row", "fileRow": return rowHeight(traits)
        case "checkRow": return compact ? 32 : 36
        case "eventRow": return compact ? 44 : 52
        case "activityRow": return compact ? 36 : 40
        case "compareRow": return compact ? 40 : 46
        case "header": return 40
        case "title": return 22
        case "subtitle", "body", "liveText": return 18
        case "caption": return 14
        case "markdown": return compact ? 72 : 96
        case "stat": return 52
        case "divider": return 9
        case "emptyState": return compact ? 96 : 120
        case "loading": return compact ? 72 : 96
        case "button", "buttonRow", "iconButton", "toggle": return 32
        case "stateButton": return 34
        case "slider": return 36
        case "tag", "statusBadge": return 22
        case "chipRow": return 26
        case "segment": return 28
        case "progress": return 18
        case "timer": return 24
        case "waveform": return 28
        case "pulse": return 12
        case "mediaCard": return compact ? 84 : 96
        case "thumbnail": return compact ? 44 : 56
        case "avatar": return 36
        case "textField": return 32
        case "searchField": return 34
        case "dropzone": return compact ? 72 : 88
        case "ai": return compact ? 56 : 64
        case "native": return rowHeight(traits)
        default: return diagnosticHeight
        }
    }

    /// Spec §5: 4–6 columns in the dock sheet, 2–3 in the corner.
    static func gridColumns(_ declared: Int, traits: HostTraits) -> Int {
        let wanted = max(1, declared)
        return traits.widthClass == .compact ? min(wanted, 3) : min(wanted, 6)
    }
}
```

- [ ] **Step 4: Implement `PluginSizing`**

```swift
// Context-Dock/UI/Plugins/PluginSizing.swift
//
// How tall a plugin is, as arithmetic. The corner's shell asks this before anything is drawn,
// so it must be a pure function of manifest + binding + traits — never a measurement, or the
// shell's drawing and its hit-testing drift apart (memory `corner-pill-size-must-be-pure`).

import CoreGraphics
import Foundation

enum PluginSizing {
    /// The height of one node, its children included.
    static func height(of node: PluginNode, traits: HostTraits, binding: PluginBinding) -> CGFloat {
        switch node.component {
        case "vstack", "form", "actionPanel", "detail", "listDetail", "capsule":
            return stacked(node.children, traits: traits, binding: binding)

        case "hstack":
            let heights = node.children.map { height(of: $0, traits: traits, binding: binding) }
            return heights.max() ?? 0

        case "card", "footerCard":
            let inner = stacked(node.children, traits: traits, binding: binding)
            return inner + PluginKit.cardPadding * 2

        case "section":
            let inner = stacked(node.children, traits: traits, binding: binding)
            let header = node.props["header"] == nil ? 0 : PluginKit.sectionHeaderHeight + PluginKit.gap
            return header + inner

        case "list":
            let rows = binding.items(node.props["items"])
            guard !rows.isEmpty else {
                return PluginKit.leafHeight("emptyState", traits: traits)
            }
            let rowNode = childNode(node, key: "row")
            let each = rowNode.map { row in
                height(of: row, traits: traits, binding: binding)
            } ?? PluginKit.rowHeight(traits)
            return each * CGFloat(rows.count)

        case "grid":
            let cells = binding.items(node.props["items"])
            guard !cells.isEmpty else {
                return PluginKit.leafHeight("emptyState", traits: traits)
            }
            let declared = Int(binding.number(node.props["columns"]) ?? 3)
            let columns = PluginKit.gridColumns(declared, traits: traits)
            let rows = Int(ceil(Double(cells.count) / Double(columns)))
            let cellNode = childNode(node, key: "cell")
            let cell = cellNode.map { height(of: $0, traits: traits, binding: binding) }
                ?? PluginKit.leafHeight("thumbnail", traits: traits)
            return cell * CGFloat(rows) + PluginKit.gap * CGFloat(max(0, rows - 1))

        default:
            if !node.children.isEmpty {
                return stacked(node.children, traits: traits, binding: binding)
            }
            return PluginKit.leafHeight(node.component, traits: traits)
        }
    }

    /// The whole view, never taller than the host allows — a list of two hundred rows scrolls
    /// inside the host rather than growing a panel off the screen.
    static func treeHeight(_ root: PluginNode, traits: HostTraits, binding: PluginBinding)
        -> CGFloat
    {
        min(height(of: root, traits: traits, binding: binding), traits.maxHeight)
    }

    private static func stacked(
        _ children: [PluginNode], traits: HostTraits, binding: PluginBinding
    ) -> CGFloat {
        guard !children.isEmpty else { return 0 }
        let total = children.reduce(CGFloat.zero) { $0 + height(of: $1, traits: traits, binding: binding) }
        return total + PluginKit.gap * CGFloat(children.count - 1)
    }

    /// A prop that is itself a node (`"row": { … }`, `"cell": { … }`), decoded on demand.
    ///
    /// Phase 1 already owns the re-decode — `PluginNode.init(value:path:)` — so this wraps it
    /// rather than round-tripping JSON a second way; two spellings of the same conversion is
    /// how the renderer and the schema come to disagree about what a nested prop means.
    /// It costs an encode+decode per nested node per call, which mattered little in Phase 1 but
    /// matters here: the renderer re-reads on every state change. Callers inside a list body
    /// should hoist it out of the per-row loop (Task 4 does).
    static func childNode(_ node: PluginNode, key: String) -> PluginNode? {
        guard let value = node.props[key] else { return nil }
        return try? PluginNode(value: value, path: [])
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginSizingTests`
Expected: PASS, 11 tests, suite name `PluginSizingTests` in the output.

- [ ] **Step 6: Commit**

```bash
git add Context-Dock/UI/Plugins/PluginKit.swift Context-Dock/UI/Plugins/PluginSizing.swift Context-DockTests/PluginSizingTests.swift
git commit -m "feat(plugins): kit tokens and a height that is arithmetic, not a measurement"
```

---

### Task 3: `PluginActionSink`, the renderer shell, and the three states

**Files:**
- Create: `Context-Dock/UI/Plugins/PluginActionSink.swift`
- Create: `Context-Dock/UI/Plugins/PluginRenderer.swift`
- Create: `Context-Dock/UI/Plugins/Components/PluginStateViews.swift`
- Test: `Context-DockTests/PluginRendererTests.swift`

**Interfaces:**
- Consumes: `HostTraits`, `PluginBinding`, `PluginKit`, `PluginSizing`, `PluginComponentCatalog`, `PluginDiagnostic`.
- Produces: `struct PluginActionRequest: Equatable { let name: String; let value: PluginValue? }`; `protocol PluginActionSink: AnyObject { func run(_ request: PluginActionRequest) }`; `final class RecordingActionSink: PluginActionSink` with `private(set) var requests: [PluginActionRequest]`.
- Produces: `struct PluginRenderer: View { init(node:traits:binding:sink:) }` and `static func supports(_ component: String) -> Bool`.
- Produces: `struct PluginDiagnosticsView: View`, `PluginEmptyStateView`, `PluginLoadingView`.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginRendererTests.swift
import Foundation
import SwiftUI
import Testing

@testable import Context_Dock

@MainActor
struct PluginRendererTests {
    private func node(_ json: String) throws -> PluginNode {
        try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
    }

    @Test func theRendererImplementsEveryNameInTheCatalog() {
        for component in PluginComponentCatalog.v1 {
            #expect(PluginRenderer.supports(component), "no renderer for \(component)")
        }
    }

    @Test func anUnknownComponentRendersAsADiagnosticNotACrash() throws {
        let unknown = try node(#"{ "orbitCluster": {} }"#)
        #expect(PluginRenderer.supports(unknown.component) == false)
        let diagnostics = PluginRenderer.diagnostics(for: unknown)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].message.contains("orbitCluster"))
    }

    @Test func aSinkReceivesWhatAComponentAsksToRun() {
        let sink = RecordingActionSink()
        sink.run(PluginActionRequest(name: "toggle", value: .string("kitchen")))
        #expect(sink.requests == [PluginActionRequest(name: "toggle", value: .string("kitchen"))])
    }

    @Test func aStateViewIsChosenForAnEmptyListAndForNoDataYet() throws {
        let list = try node(#"{ "list": { "items": "{{queue}}" } }"#)
        #expect(PluginRenderer.state(for: list, binding: PluginBinding()) == .empty)
        #expect(
            PluginRenderer.state(for: list, binding: PluginBinding(data: ["queue": .array([.null])]))
                == .content)
        #expect(PluginRenderer.state(for: list, binding: nil) == .loading)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: build failure — `cannot find 'PluginRenderer' in scope`.

- [ ] **Step 3: Implement the sink**

```swift
// Context-Dock/UI/Plugins/PluginActionSink.swift
//
// How a component asks for something to happen. Phase 2 draws; Phase 3 runs. The renderer
// therefore never calls a runner — it hands a request to whatever sink the host installed, and
// in tests and previews that sink only records.

import Foundation

struct PluginActionRequest: Equatable {
    let name: String
    let value: PluginValue?

    init(name: String, value: PluginValue? = nil) {
        self.name = name
        self.value = value
    }
}

@MainActor
protocol PluginActionSink: AnyObject {
    func run(_ request: PluginActionRequest)
}

@MainActor
final class RecordingActionSink: PluginActionSink {
    private(set) var requests: [PluginActionRequest] = []
    func run(_ request: PluginActionRequest) { requests.append(request) }
}
```

- [ ] **Step 4: Implement the renderer shell and the states**

```swift
// Context-Dock/UI/Plugins/PluginRenderer.swift
//
// One `switch` from a node to a view. Every host renders through this; none may fork a
// component. A name the kit does not know renders as a diagnostic row naming it — a manifest
// from a newer app degrades to a visible complaint, never a blank panel or a crash.

import SwiftUI

struct PluginRenderer: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    init(node: PluginNode, traits: HostTraits, binding: PluginBinding,
         sink: (any PluginActionSink)? = nil) {
        self.node = node
        self.traits = traits
        self.binding = binding
        self.sink = sink
    }

    enum RenderState: Equatable { case loading, empty, content }

    /// Which of the three states a node is in. `nil` binding means the data script has not
    /// answered yet — that is `loading`, and an empty list is `empty`, and the two must not be
    /// confused or a slow plugin looks broken.
    static func state(for node: PluginNode, binding: PluginBinding?) -> RenderState {
        guard let binding else { return .loading }
        guard node.component == "list" || node.component == "grid" else { return .content }
        return binding.items(node.props["items"]).isEmpty ? .empty : .content
    }

    static func supports(_ component: String) -> Bool {
        PluginComponentCatalog.isKnown(component)
    }

    static func diagnostics(for node: PluginNode) -> [PluginDiagnostic] {
        node.flattened
            .filter { !supports($0.component) }
            .map {
                PluginDiagnostic(
                    severity: .error, path: "views",
                    message: "unknown component \"\($0.component)\"")
            }
    }

    var body: some View {
        if Self.supports(node.component) {
            component
        } else {
            PluginDiagnosticsView(diagnostics: Self.diagnostics(for: node))
        }
    }

    @ViewBuilder
    private var component: some View {
        switch node.component {
        case "emptyState":
            PluginEmptyStateView(
                title: binding.text(node.props["title"] ?? node.props["text"]),
                message: binding.text(node.props["message"]), traits: traits)
        case "loading":
            PluginLoadingView(
                message: binding.text(node.props["message"]), traits: traits)
        default:
            // Filled in by Tasks 4–8; until then a node the kit knows but has no view for
            // renders as nothing rather than as a wrong guess.
            Color.clear.frame(height: PluginKit.leafHeight(node.component, traits: traits))
        }
    }
}
```

```swift
// Context-Dock/UI/Plugins/Components/PluginStateViews.swift
//
// The three things a panel shows when it is not showing content: nothing yet, nothing at all,
// and something wrong. All three are the kit's, so every plugin's empty state looks like the
// app rather than like whoever wrote the manifest.

import SwiftUI

struct PluginEmptyStateView: View {
    let title: String
    let message: String
    let traits: HostTraits
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: traits.widthClass == .compact ? 18 : 22, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title.isEmpty ? "Nothing here" : title)
                .font(.system(size: 13, weight: .semibold))
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PluginKit.leafHeight("emptyState", traits: traits))
    }
}

struct PluginLoadingView: View {
    let message: String
    let traits: HostTraits

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if !message.isEmpty {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PluginKit.leafHeight("loading", traits: traits))
    }
}

struct PluginDiagnosticsView: View {
    let diagnostics: [PluginDiagnostic]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                HStack(spacing: 6) {
                    Image(systemName: diagnostic.severity == .error
                        ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(diagnostic.severity == .error ? .red : .secondary)
                    Text(diagnostic.message)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                }
                .frame(height: PluginKit.diagnosticHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: PluginKit.cornerRadius, style: .continuous)
                .fill(Theme.surface(scheme == .dark)))
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: `theRendererImplementsEveryNameInTheCatalog` FAILS (no component views yet) — that is the phase's running red bar and Tasks 4–8 turn it green one group at a time. The other three tests PASS. Keep the test in the suite; do not weaken it.

- [ ] **Step 6: Commit**

```bash
git add Context-Dock/UI/Plugins/PluginActionSink.swift Context-Dock/UI/Plugins/PluginRenderer.swift Context-Dock/UI/Plugins/Components/PluginStateViews.swift Context-DockTests/PluginRendererTests.swift
git commit -m "feat(plugins): the renderer shell, its action sink, and the three panel states"
```

---

### Task 4: panel views — `list`, `row`, `section`, `actionPanel`

**Files:**
- Create: `Context-Dock/UI/Plugins/Components/PluginPanelViews.swift`
- Modify: `Context-Dock/UI/Plugins/PluginRenderer.swift` (add the four cases)
- Test: `Context-DockTests/PluginRendererTests.swift` (add the tests below)

**Interfaces:**
- Consumes: `PluginRenderer`, `PluginBinding.scoped(to:)`, `PluginSizing.childNode(_:key:)`.
- Produces: `PluginListView`, `PluginRowView`, `PluginSectionView`, `PluginActionPanelView`; `PluginRowModel` (`id`, `title`, `subtitle`, `icon`, `accessories`, `actions`) built by `PluginRowModel.make(from:binding:)` — Phase 5's search reuses it, so the name is fixed here.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func aListBuildsOneRowModelPerItemInOrder() throws {
        let list = try node(#"""
        { "list": { "items": "{{queue}}",
                    "row": { "title": "{{item.title}}", "subtitle": "{{item.artist}}" } } }
        """#)
        let binding = PluginBinding(data: ["queue": .array([
            .object(["title": .string("Jungle"), "artist": .string("Casio")]),
            .object(["title": .string("For Ever"), "artist": .string("Casio")]),
        ])])
        let models = PluginListView.rowModels(for: list, binding: binding)
        #expect(models.map(\.title) == ["Jungle", "For Ever"])
        #expect(models[0].subtitle == "Casio")
    }

    @Test func aLocalFilterNarrowsRowsWithoutRunningAnything() throws {
        let list = try node(#"""
        { "list": { "filter": "local", "items": "{{queue}}", "row": { "title": "{{item.title}}" } } }
        """#)
        let binding = PluginBinding(data: ["queue": .array([
            .object(["title": .string("Jungle")]), .object(["title": .string("For Ever")]),
        ])])
        #expect(PluginListView.rowModels(for: list, binding: binding, query: "ever").map(\.title)
            == ["For Ever"])
        // filter: query hands the typing to the data script instead, so the rows stand.
        let queryList = try node(#"""
        { "list": { "filter": "query", "items": "{{queue}}", "row": { "title": "{{item.title}}" } } }
        """#)
        #expect(PluginListView.rowModels(for: queryList, binding: binding, query: "ever").count == 2)
    }

    @Test func aRowsActionsCarryTheirResolvedValue() throws {
        let list = try node(#"""
        { "list": { "items": "{{queue}}",
                    "row": { "title": "{{item.title}}",
                             "actions": [ { "title": "Play", "action": "play", "value": "{{item.id}}" } ] } } }
        """#)
        let binding = PluginBinding(data: ["queue": .array([
            .object(["id": .string("t1"), "title": .string("Jungle")])
        ])])
        let models = PluginListView.rowModels(for: list, binding: binding)
        #expect(models[0].actions.first?.request
            == PluginActionRequest(name: "play", value: .string("t1")))
    }

    @Test func runningARowsPrimaryActionReachesTheSink() {
        let sink = RecordingActionSink()
        let action = PluginRowAction(title: "Play", request: .init(name: "play", value: .string("t1")))
        PluginListView.perform(action, sink: sink)
        #expect(sink.requests.map(\.name) == ["play"])
    }

    @Test func aRowActionThatIsNotDeclaredIsADiagnosticTheSchemaCannotSee() throws {
        // `"row": { … }` is stored as PluginValue.object, so PluginSchema.validate never walks
        // into it — a row action naming an undeclared action reaches a user as a dead row
        // unless the renderer says so. PluginMigration emits this shape for every converted
        // provider:custom list, so it is not hypothetical.
        let list = try node(#"""
        { "list": { "items": "{{queue}}",
                    "row": { "title": "{{item.title}}",
                             "actions": [ { "title": "Play", "action": "play" },
                                          { "title": "Beam", "action": "teleport" } ] } } }
        """#)
        let diagnostics = PluginListView.rowDiagnostics(for: list, declaredActions: ["play"])
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("teleport"))
        #expect(diagnostics[0].path == "views.list.row.actions")
        #expect(PluginListView.rowDiagnostics(
            for: list, declaredActions: ["play", "teleport"]).isEmpty)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: build failure — `cannot find 'PluginListView' in scope`.

- [ ] **Step 3: Implement the panel views**

```swift
// Context-Dock/UI/Plugins/Components/PluginPanelViews.swift
//
// The Raycast-class half of the kit: a list of rows, sections over them, and the ⌘K action
// panel. Rows are built as models first and drawn second, because Phase 5 indexes the same
// models into search and must not re-derive them from the view.

import SwiftUI

struct PluginRowAction: Equatable, Identifiable {
    let title: String
    let request: PluginActionRequest
    var id: String { title + request.name }
}

struct PluginRowModel: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String?
    let accessories: [String]
    let actions: [PluginRowAction]

    /// One row from one item. `node` is the manifest's `row` template; `binding` is already
    /// scoped to the item.
    static func make(from node: PluginNode, binding: PluginBinding, index: Int) -> PluginRowModel {
        let actions = (node.props["actions"]?.arrayValue ?? []).compactMap { value -> PluginRowAction? in
            guard let object = value.objectValue, let name = binding.text(object["action"]) as String?,
                !name.isEmpty
            else { return nil }
            let resolved = object["value"].map { binding.resolve($0) }
            return PluginRowAction(
                title: binding.text(object["title"]),
                request: PluginActionRequest(name: name, value: resolved))
        }
        return PluginRowModel(
            id: {
                let explicit = binding.text(node.props["id"])
                return explicit.isEmpty ? "row-\(index)" : explicit
            }(),
            title: binding.text(node.props["title"] ?? node.props["text"]),
            subtitle: binding.text(node.props["subtitle"]),
            icon: {
                let name = binding.text(node.props["icon"])
                return name.isEmpty ? nil : name
            }(),
            accessories: binding.items(node.props["accessories"]).map { binding.text($0) },
            actions: actions)
    }
}

struct PluginListView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    var query: String = ""

    /// The row template a list repeats. Decoded once per call and handed to the loop — never
    /// re-decoded per item, which would be one JSON round-trip per row per redraw.
    static func rowTemplate(of node: PluginNode) -> PluginNode {
        PluginSizing.childNode(node, key: "row")
            ?? PluginNode(component: "row", props: ["title": .string("{{item.title}}")])
    }

    /// What `PluginSchema` structurally cannot say. A nested node prop (`"row": { … }`) is a
    /// `PluginValue.object` in the model, so validation never walks into it and a row action
    /// naming an action nobody declared passes install silently. The renderer is where that
    /// becomes visible, so it is checked here and rendered as a diagnostic.
    ///
    /// This is a **stand-in for #27**, render-time and `list`-only. When `PluginNode.nodeProps`
    /// lands, the schema reaches row contents on its own and this shrinks to a thin call —
    /// do not grow it into a second validator in the meantime.
    static func rowDiagnostics(for node: PluginNode, declaredActions: Set<String>)
        -> [PluginDiagnostic]
    {
        let template = rowTemplate(of: node)
        let names = (template.props["actions"]?.arrayValue ?? []).compactMap {
            $0.objectValue?["action"]?.stringValue
        }
        return names.filter { !declaredActions.contains($0) }.map {
            PluginDiagnostic(
                severity: .error, path: "views.list.row.actions",
                message: "row action \"\($0)\" is not a declared action")
        }
    }

    /// `filter: local` narrows in place while typing; `filter: query` leaves the rows alone
    /// because the data script is the one that gets the query (spec §7).
    static func rowModels(for node: PluginNode, binding: PluginBinding, query: String = "")
        -> [PluginRowModel]
    {
        let template = rowTemplate(of: node)
        let models = binding.items(node.props["items"]).enumerated().map { index, item in
            PluginRowModel.make(from: template, binding: binding.scoped(to: item), index: index)
        }
        let isLocal = binding.text(node.props["filter"]) == "local"
        guard isLocal, !query.isEmpty else { return models }
        let needle = query.lowercased()
        return models.filter {
            $0.title.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        }
    }

    @MainActor
    static func perform(_ action: PluginRowAction, sink: (any PluginActionSink)?) {
        sink?.run(action.request)
    }

    var body: some View {
        let models = Self.rowModels(for: node, binding: binding, query: query)
        if models.isEmpty {
            PluginEmptyStateView(title: "No results", message: "", traits: traits)
        } else {
            VStack(spacing: 0) {
                ForEach(models) { model in
                    PluginRowView(model: model, traits: traits, sink: sink)
                }
            }
        }
    }
}

struct PluginRowView: View {
    let model: PluginRowModel
    let traits: HostTraits
    weak var sink: (any PluginActionSink)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            if let icon = model.icon {
                Image(systemName: icon).frame(width: 18)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            ForEach(model.accessories, id: \.self) { accessory in
                Text(accessory).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PluginKit.rowHeight(traits))
        .contentShape(Rectangle())
        .onTapGesture {
            if let first = model.actions.first { PluginListView.perform(first, sink: sink) }
        }
    }
}

struct PluginSectionView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    var body: some View {
        VStack(alignment: .leading, spacing: PluginKit.gap) {
            if let header = node.props["header"] {
                Text(binding.text(header).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: PluginKit.sectionHeaderHeight, alignment: .leading)
            }
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                PluginRenderer(node: child, traits: traits, binding: binding, sink: sink)
            }
        }
    }
}

/// ⌘K. In the corner this is the only home secondary actions have (spec §5).
struct PluginActionPanelView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                let title = binding.text(child.props["title"])
                let name = binding.text(child.props["action"])
                Button(title.isEmpty ? name : title) {
                    sink?.run(PluginActionRequest(
                        name: name, value: child.props["value"].map { binding.resolve($0) }))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .frame(height: 28)
            }
        }
    }
}
```

Then add the cases to `PluginRenderer.component`:

```swift
        case "list":
            PluginListView(node: node, traits: traits, binding: binding, sink: sink)
        case "row":
            PluginRowView(
                model: PluginRowModel.make(from: node, binding: binding, index: 0),
                traits: traits, sink: sink)
        case "section":
            PluginSectionView(node: node, traits: traits, binding: binding, sink: sink)
        case "actionPanel":
            PluginActionPanelView(node: node, traits: traits, binding: binding, sink: sink)
```

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: the four new tests PASS; `theRendererImplementsEveryNameInTheCatalog` still fails, naming fewer components than before.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/UI/Plugins/Components/PluginPanelViews.swift Context-Dock/UI/Plugins/PluginRenderer.swift Context-DockTests/PluginRendererTests.swift
git commit -m "feat(plugins): list, row, section and the action panel"
```

---

### Task 5: `listDetail`, `detail`, `grid`, `form`

**Files:**
- Create: `Context-Dock/UI/Plugins/Components/PluginDetailViews.swift`
- Modify: `Context-Dock/UI/Plugins/PluginRenderer.swift`
- Test: `Context-DockTests/PluginRendererTests.swift`

**Interfaces:**
- Consumes: `PluginRowModel`, `PluginListView.rowModels(for:binding:query:)`.
- Produces: `PluginListDetailView`, `PluginDetailView`, `PluginGridView`, `PluginFormView`; `PluginFormField` (`key`, `label`, `kind`, `value`) and `PluginFormState` (an `@Observable` box the form edits and the submit action reads).

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func aDetailReadsMarkdownAndMetadataFromTheSelectedRow() throws {
        let node = try node(#"""
        { "listDetail": { "items": "{{docs}}",
                          "row": { "title": "{{item.title}}" },
                          "detail": { "markdown": "{{item.body}}",
                                      "metadata": [ { "title": "Size", "text": "{{item.size}}" } ] } } }
        """#)
        let binding = PluginBinding(data: ["docs": .array([
            .object(["title": .string("Notes"), "body": .string("# Hi"), "size": .string("2 KB")])
        ])])
        let detail = PluginListDetailView.detail(for: node, binding: binding, selection: 0)
        #expect(detail?.markdown == "# Hi")
        #expect(detail?.metadata == [PluginMetadataItem(title: "Size", text: "2 KB")])
    }

    @Test func aFormCollectsItsFieldsAndSubmitsThemAsOneValue() throws {
        let form = try node(#"""
        { "form": { "submit": "save",
                    "fields": [ { "key": "name", "label": "Name", "kind": "text" },
                                { "key": "public", "label": "Public", "kind": "toggle" } ] } }
        """#)
        let state = PluginFormState(fields: PluginFormView.fields(of: form, binding: PluginBinding()))
        #expect(state.fields.map(\.key) == ["name", "public"])
        state.set("name", .string("Kitchen"))
        state.set("public", .bool(true))
        let sink = RecordingActionSink()
        PluginFormView.submit(form, state: state, binding: PluginBinding(), sink: sink)
        #expect(sink.requests == [PluginActionRequest(
            name: "save", value: .object(["name": .string("Kitchen"), "public": .bool(true)]))])
    }

    @Test func aGridClampsItsColumnsToTheWidthClass() throws {
        let grid = try node(#"{ "grid": { "columns": 6, "items": "{{p}}", "cell": { "thumbnail": {} } } }"#)
        #expect(PluginGridView.columns(of: grid, traits: .dockSheet, binding: PluginBinding()) == 6)
        #expect(PluginGridView.columns(of: grid, traits: .cornerPanel, binding: PluginBinding()) == 3)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: build failure — `cannot find 'PluginListDetailView' in scope`.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/UI/Plugins/Components/PluginDetailViews.swift
//
// The views that show one thing in depth: a list beside a detail (which the corner turns into
// a push, Task 9), a detail on its own, a grid of cells, and a form. The detail's markdown and
// metadata are read as a model so the corner and the dock cannot render different text.

import SwiftUI

struct PluginMetadataItem: Equatable, Identifiable {
    let title: String
    let text: String
    var id: String { title + text }
}

struct PluginDetailModel: Equatable {
    let markdown: String
    let metadata: [PluginMetadataItem]
}

struct PluginListDetailView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    @State private var selection: Int = 0

    static func detail(for node: PluginNode, binding: PluginBinding, selection: Int)
        -> PluginDetailModel?
    {
        let items = binding.items(node.props["items"])
        guard items.indices.contains(selection),
            let template = PluginSizing.childNode(node, key: "detail")
        else { return nil }
        let scoped = binding.scoped(to: items[selection])
        let metadata = (template.props["metadata"]?.arrayValue ?? []).compactMap {
            value -> PluginMetadataItem? in
            guard let object = value.objectValue else { return nil }
            return PluginMetadataItem(
                title: scoped.text(object["title"]), text: scoped.text(object["text"]))
        }
        return PluginDetailModel(
            markdown: scoped.text(template.props["markdown"]), metadata: metadata)
    }

    var body: some View {
        let models = PluginListView.rowModels(for: node, binding: binding)
        HStack(alignment: .top, spacing: PluginKit.gap) {
            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    PluginRowView(model: model, traits: traits, sink: sink)
                        .background(index == selection
                            ? Theme.selectionFill(true) : Color.clear)
                        .onTapGesture { selection = index }
                }
            }
            .frame(width: traits.width * 0.4)
            if let detail = Self.detail(for: node, binding: binding, selection: selection) {
                PluginDetailBody(detail: detail, traits: traits)
            }
        }
    }
}

struct PluginDetailBody: View {
    let detail: PluginDetailModel
    let traits: HostTraits

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !detail.markdown.isEmpty {
                Text(LocalizedStringKey(detail.markdown)).font(.system(size: 12))
            }
            ForEach(detail.metadata) { item in
                HStack {
                    Text(item.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.text).font(.system(size: 11))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PluginDetailView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding

    var body: some View {
        let metadata = (node.props["metadata"]?.arrayValue ?? []).compactMap {
            value -> PluginMetadataItem? in
            guard let object = value.objectValue else { return nil }
            return PluginMetadataItem(
                title: binding.text(object["title"]), text: binding.text(object["text"]))
        }
        PluginDetailBody(
            detail: PluginDetailModel(
                markdown: binding.text(node.props["markdown"]), metadata: metadata),
            traits: traits)
    }
}

struct PluginGridView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    static func columns(of node: PluginNode, traits: HostTraits, binding: PluginBinding) -> Int {
        PluginKit.gridColumns(Int(binding.number(node.props["columns"]) ?? 3), traits: traits)
    }

    var body: some View {
        let cells = binding.items(node.props["items"])
        let count = Self.columns(of: node, traits: traits, binding: binding)
        let template = PluginSizing.childNode(node, key: "cell")
            ?? PluginNode(component: "thumbnail")
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: PluginKit.gap), count: count),
            spacing: PluginKit.gap
        ) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                PluginRenderer(
                    node: template, traits: traits, binding: binding.scoped(to: cell), sink: sink)
            }
        }
    }
}

struct PluginFormField: Equatable, Identifiable {
    let key: String
    let label: String
    /// `text`, `toggle`, `slider`, `select`
    let kind: String
    var id: String { key }
}

@Observable
final class PluginFormState {
    let fields: [PluginFormField]
    private(set) var values: [String: PluginValue] = [:]

    init(fields: [PluginFormField]) { self.fields = fields }

    func set(_ key: String, _ value: PluginValue) { values[key] = value }

    var payload: PluginValue { .object(values) }
}

struct PluginFormView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    @State private var state: PluginFormState

    init(node: PluginNode, traits: HostTraits, binding: PluginBinding,
         sink: (any PluginActionSink)? = nil) {
        self.node = node
        self.traits = traits
        self.binding = binding
        self.sink = sink
        _state = State(initialValue: PluginFormState(
            fields: PluginFormView.fields(of: node, binding: binding)))
    }

    static func fields(of node: PluginNode, binding: PluginBinding) -> [PluginFormField] {
        (node.props["fields"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue else { return nil }
            let key = binding.text(object["key"])
            guard !key.isEmpty else { return nil }
            let kind = binding.text(object["kind"])
            return PluginFormField(
                key: key, label: binding.text(object["label"]),
                kind: kind.isEmpty ? "text" : kind)
        }
    }

    @MainActor
    static func submit(
        _ node: PluginNode, state: PluginFormState, binding: PluginBinding,
        sink: (any PluginActionSink)?
    ) {
        let name = binding.text(node.props["submit"])
        guard !name.isEmpty else { return }
        sink?.run(PluginActionRequest(name: name, value: state.payload))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginKit.gap) {
            ForEach(state.fields) { field in
                switch field.kind {
                case "toggle":
                    Toggle(field.label, isOn: Binding(
                        get: { state.values[field.key].map { $0 == .bool(true) } ?? false },
                        set: { state.set(field.key, .bool($0)) }))
                        .font(.system(size: 12))
                default:
                    TextField(field.label, text: Binding(
                        get: { state.values[field.key]?.stringValue ?? "" },
                        set: { state.set(field.key, .string($0)) }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }
            Button("Save") {
                Self.submit(node, state: state, binding: binding, sink: sink)
            }
            .font(.system(size: 12, weight: .medium))
        }
    }
}
```

Add to `PluginRenderer.component`: `case "listDetail"`, `case "detail"`, `case "grid"`, `case "form"` constructing the four views above.

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: the three new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/UI/Plugins/Components/PluginDetailViews.swift Context-Dock/UI/Plugins/PluginRenderer.swift Context-DockTests/PluginRendererTests.swift
git commit -m "feat(plugins): list-detail, detail, grid and form"
```

---

### Task 6: containers, text and chips

**Files:**
- Create: `Context-Dock/UI/Plugins/Components/PluginContainers.swift`
- Create: `Context-Dock/UI/Plugins/Components/PluginText.swift`
- Create: `Context-Dock/UI/Plugins/Components/PluginChips.swift`
- Modify: `Context-Dock/UI/Plugins/PluginRenderer.swift`
- Test: `Context-DockTests/PluginRendererTests.swift`

**Interfaces:**
- Produces: `PluginContainerView` (handles `vstack`, `hstack`, `card`, `footerCard`, `capsule`, `divider`), `PluginTextView` (`title`, `subtitle`, `body`, `caption`, `markdown`, `stat`, `header`), `PluginChipView` (`tag`, `statusBadge`, `chipRow`, `segment`), and `PluginStatusTone.tone(for:) -> Color` mapping the six status words of spec §6.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func theSixStatusWordsEachGetTheirOwnTone() {
        let words = ["pending", "running", "success", "failed", "expired", "waiting"]
        let tones = words.map { PluginStatusTone.tone(for: $0) }
        #expect(Set(tones.map(\.description)).count == words.count)
        // An unknown word is neutral rather than an accident.
        #expect(PluginStatusTone.tone(for: "banana") == PluginStatusTone.neutral)
    }

    @Test func aStatReadsValueLabelAndDelta() throws {
        let stat = try node(#"{ "stat": { "value": "{{count}}", "label": "Tracks", "delta": "+3" } }"#)
        let model = PluginTextView.stat(of: stat, binding: PluginBinding(data: ["count": .number(12)]))
        #expect(model == PluginStatModel(value: "12", label: "Tracks", delta: "+3"))
    }

    @Test func shorthandTextReachesTheView() throws {
        // { "title": "Up next" } decodes to props["text"], not props["title"].
        let title = try node(#"{ "title": "Up next" }"#)
        #expect(PluginTextView.text(of: title, binding: PluginBinding()) == "Up next")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: build failure — `cannot find 'PluginStatusTone' in scope`.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/UI/Plugins/Components/PluginText.swift
import SwiftUI

struct PluginStatModel: Equatable {
    let value: String
    let label: String
    let delta: String
}

struct PluginTextView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding

    /// A manifest may write `{ "title": "Up next" }` (shorthand, lands in `text`) or
    /// `{ "title": { "text": "{{heading}}" } }`. Both read the same here.
    static func text(of node: PluginNode, binding: PluginBinding) -> String {
        binding.text(node.props["text"] ?? node.props["title"] ?? node.props["value"])
    }

    static func stat(of node: PluginNode, binding: PluginBinding) -> PluginStatModel {
        PluginStatModel(
            value: binding.text(node.props["value"] ?? node.props["text"]),
            label: binding.text(node.props["label"]),
            delta: binding.text(node.props["delta"]))
    }

    var body: some View {
        switch node.component {
        case "title":
            Text(Self.text(of: node, binding: binding))
                .font(.system(size: 15, weight: .semibold)).lineLimit(1)
        case "subtitle":
            Text(Self.text(of: node, binding: binding))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        case "body":
            Text(Self.text(of: node, binding: binding)).font(.system(size: 12))
        case "caption":
            Text(Self.text(of: node, binding: binding))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        case "markdown":
            Text(LocalizedStringKey(Self.text(of: node, binding: binding))).font(.system(size: 12))
        case "stat":
            let model = Self.stat(of: node, binding: binding)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.value).font(.system(size: 22, weight: .semibold))
                    if !model.delta.isEmpty {
                        Text(model.delta).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text(model.label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        default:  // header
            HStack(spacing: 8) {
                if let icon = node.props["icon"].map({ binding.text($0) }), !icon.isEmpty {
                    Image(systemName: icon)
                }
                Text(Self.text(of: node, binding: binding))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if let trailing = node.props["trailing"] {
                    Text(binding.text(trailing)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(height: PluginKit.leafHeight("header", traits: traits))
        }
    }
}
```

```swift
// Context-Dock/UI/Plugins/Components/PluginChips.swift
import SwiftUI

enum PluginStatusTone {
    static let neutral = Color.secondary

    /// The six words spec §6 fixes, each with its own tone. An unknown word is neutral —
    /// a plugin that invents a status still renders, it just does not get a colour.
    static func tone(for word: String) -> Color {
        switch word.lowercased() {
        case "pending": return .orange
        case "running": return .blue
        case "success": return .green
        case "failed": return .red
        case "expired": return .purple
        case "waiting": return .yellow
        default: return neutral
        }
    }
}

struct PluginChipView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding

    var body: some View {
        switch node.component {
        case "statusBadge":
            let word = PluginTextView.text(of: node, binding: binding)
            chip(word, tone: PluginStatusTone.tone(for: word))
        case "chipRow":
            HStack(spacing: 4) {
                ForEach(binding.items(node.props["items"] ?? node.props["text"]), id: \.self) { item in
                    chip(binding.text(item), tone: PluginStatusTone.neutral)
                }
            }
            .frame(height: PluginKit.leafHeight("chipRow", traits: traits))
        case "segment":
            HStack(spacing: 0) {
                ForEach(binding.items(node.props["items"]), id: \.self) { item in
                    Text(binding.text(item)).font(.system(size: 11))
                        .padding(.horizontal, 10).frame(height: 24)
                }
            }
        default:  // tag
            chip(
                PluginTextView.text(of: node, binding: binding),
                tone: PluginStatusTone.tone(for: binding.text(node.props["color"])))
        }
    }

    private func chip(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(tone.opacity(0.16)))
            .overlay(Capsule().strokeBorder(tone.opacity(0.35), lineWidth: 0.5))
            .foregroundStyle(tone == PluginStatusTone.neutral ? Color.secondary : tone)
    }
}
```

```swift
// Context-Dock/UI/Plugins/Components/PluginContainers.swift
import SwiftUI

struct PluginContainerView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch node.component {
        case "hstack", "capsule":
            HStack(spacing: PluginKit.gap) { children }
        case "card", "footerCard":
            VStack(alignment: .leading, spacing: PluginKit.gap) { children }
                .padding(PluginKit.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: PluginKit.cornerRadius, style: .continuous)
                        .fill(node.component == "footerCard"
                            ? Theme.surface(scheme == .dark)
                            : Theme.surfaceElevated(scheme == .dark)))
                .overlay(
                    RoundedRectangle(cornerRadius: PluginKit.cornerRadius, style: .continuous)
                        .strokeBorder(Theme.border(scheme == .dark), lineWidth: 0.5))
        case "divider":
            Rectangle().fill(Theme.separator(scheme == .dark))
                .frame(height: 1)
                .padding(.vertical, 4)
        default:  // vstack
            VStack(alignment: .leading, spacing: PluginKit.gap) { children }
        }
    }

    @ViewBuilder
    private var children: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
            PluginRenderer(node: child, traits: traits, binding: binding, sink: sink)
        }
    }
}
```

Add the cases to `PluginRenderer.component`, routing `vstack`/`hstack`/`card`/`footerCard`/`capsule`/`divider` to `PluginContainerView`, `title`/`subtitle`/`body`/`caption`/`markdown`/`stat`/`header` to `PluginTextView`, and `tag`/`statusBadge`/`chipRow`/`segment` to `PluginChipView`.

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: the three new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/UI/Plugins/Components/PluginContainers.swift Context-Dock/UI/Plugins/Components/PluginText.swift Context-Dock/UI/Plugins/Components/PluginChips.swift Context-Dock/UI/Plugins/PluginRenderer.swift Context-DockTests/PluginRendererTests.swift
git commit -m "feat(plugins): containers, text and chips"
```

---

### Task 7: controls and cards

**Files:**
- Create: `Context-Dock/UI/Plugins/Components/PluginControls.swift`
- Create: `Context-Dock/UI/Plugins/Components/PluginCards.swift`
- Modify: `Context-Dock/UI/Plugins/PluginRenderer.swift`
- Test: `Context-DockTests/PluginRendererTests.swift`

**Interfaces:**
- Produces: `PluginControlView` (`button`, `iconButton`, `buttonRow`, `toggle`, `slider`, `stateButton`), `PluginCardRowView` (`eventRow`, `activityRow`, `fileRow`, `checkRow`, `compareRow`).
- Produces: `PluginControlView.request(of:binding:) -> PluginActionRequest?` — the one place a control turns a prop into an action, so optimistic state (Phase 3) has a single hook.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func aButtonsActionAndValueBecomeOneRequest() throws {
        let button = try node(#"{ "button": { "title": "Play", "action": "play", "value": "{{id}}" } }"#)
        let binding = PluginBinding(data: ["id": .string("t9")])
        #expect(PluginControlView.request(of: button, binding: binding)
            == PluginActionRequest(name: "play", value: .string("t9")))
    }

    @Test func aControlWithoutAnActionAsksForNothing() throws {
        let button = try node(#"{ "button": { "title": "Play" } }"#)
        #expect(PluginControlView.request(of: button, binding: PluginBinding()) == nil)
    }

    @Test func aToggleSendsItsNewStateAsTheValue() {
        let sink = RecordingActionSink()
        PluginControlView.send(
            PluginActionRequest(name: "mute", value: .bool(true)), sink: sink)
        #expect(sink.requests == [PluginActionRequest(name: "mute", value: .bool(true))])
    }

    @Test func aStateButtonCyclesThroughItsDeclaredStates() throws {
        let button = try node(#"""
        { "stateButton": { "states": [ { "title": "Play", "action": "play" },
                                       { "title": "Pause", "action": "pause" } ],
                           "state": "{{playing}}" } }
        """#)
        let states = PluginControlView.states(of: button, binding: PluginBinding())
        #expect(states.map(\.title) == ["Play", "Pause"])
        #expect(states[1].request.name == "pause")
    }

    @Test func anEventRowReadsItsTimeRangeAndDurationChip() throws {
        let row = try node(#"""
        { "eventRow": { "title": "Standup", "timeRange": "09:30 – 09:45", "durationChip": "15m" } }
        """#)
        let model = PluginCardRowView.event(of: row, binding: PluginBinding())
        #expect(model.timeRange == "09:30 – 09:45")
        #expect(model.durationChip == "15m")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: build failure — `cannot find 'PluginControlView' in scope`.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/UI/Plugins/Components/PluginControls.swift
import SwiftUI

struct PluginControlState: Equatable, Identifiable {
    let title: String
    let request: PluginActionRequest
    var id: String { title + request.name }
}

struct PluginControlView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    @State private var toggleOn = false
    @State private var sliderValue: Double = 0

    /// The single place a control becomes an action. Phase 3 hangs optimistic state here.
    static func request(of node: PluginNode, binding: PluginBinding) -> PluginActionRequest? {
        let name = binding.text(node.props["action"] ?? node.props["onTap"])
        guard !name.isEmpty else { return nil }
        return PluginActionRequest(
            name: name, value: node.props["value"].map { binding.resolve($0) })
    }

    static func states(of node: PluginNode, binding: PluginBinding) -> [PluginControlState] {
        (node.props["states"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue else { return nil }
            let name = binding.text(object["action"])
            guard !name.isEmpty else { return nil }
            return PluginControlState(
                title: binding.text(object["title"]),
                request: PluginActionRequest(
                    name: name, value: object["value"].map { binding.resolve($0) }))
        }
    }

    @MainActor
    static func send(_ request: PluginActionRequest, sink: (any PluginActionSink)?) {
        sink?.run(request)
    }

    var body: some View {
        switch node.component {
        case "toggle":
            Toggle(PluginTextView.text(of: node, binding: binding), isOn: Binding(
                get: { toggleOn },
                set: { newValue in
                    toggleOn = newValue
                    if let name = Self.request(of: node, binding: binding)?.name {
                        Self.send(PluginActionRequest(name: name, value: .bool(newValue)), sink: sink)
                    }
                }))
                .font(.system(size: 12))
        case "slider":
            Slider(value: Binding(
                get: { sliderValue },
                set: { newValue in
                    sliderValue = newValue
                    if let name = Self.request(of: node, binding: binding)?.name {
                        Self.send(
                            PluginActionRequest(name: name, value: .number(newValue)), sink: sink)
                    }
                }), in: 0...100)
                .controlSize(.small)
        case "stateButton":
            let states = Self.states(of: node, binding: binding)
            let index = binding.bool(node.props["state"]) ? 1 : 0
            let state = states.indices.contains(index) ? states[index] : states.first
            Button(state?.title ?? "") {
                if let state { Self.send(state.request, sink: sink) }
            }
            .font(.system(size: 12, weight: .medium))
        case "iconButton":
            Button {
                if let request = Self.request(of: node, binding: binding) {
                    Self.send(request, sink: sink)
                }
            } label: {
                Image(systemName: binding.text(node.props["icon"]))
            }
            .buttonStyle(.plain)
        case "buttonRow":
            HStack(spacing: PluginKit.gap) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                    PluginControlView(node: child, traits: traits, binding: binding, sink: sink)
                }
            }
        default:  // button
            Button(PluginTextView.text(of: node, binding: binding)) {
                if let request = Self.request(of: node, binding: binding) {
                    Self.send(request, sink: sink)
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
    }
}
```

```swift
// Context-Dock/UI/Plugins/Components/PluginCards.swift
import SwiftUI

struct PluginEventModel: Equatable {
    let title: String
    let timeRange: String
    let durationChip: String
}

struct PluginCardRowView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    static func event(of node: PluginNode, binding: PluginBinding) -> PluginEventModel {
        PluginEventModel(
            title: PluginTextView.text(of: node, binding: binding),
            timeRange: binding.text(node.props["timeRange"]),
            durationChip: binding.text(node.props["durationChip"]))
    }

    var body: some View {
        switch node.component {
        case "eventRow":
            let model = Self.event(of: node, binding: binding)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.system(size: 13, weight: .medium))
                    Text(model.timeRange).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !model.durationChip.isEmpty {
                    PluginChipView(
                        node: PluginNode(
                            component: "tag", props: ["text": .string(model.durationChip)]),
                        traits: traits, binding: binding)
                }
            }
            .frame(height: PluginKit.leafHeight("eventRow", traits: traits))
        case "activityRow":
            HStack(spacing: 8) {
                Circle()
                    .fill(PluginStatusTone.tone(for: binding.text(node.props["status"])))
                    .frame(width: 7, height: 7)
                Text(PluginTextView.text(of: node, binding: binding)).font(.system(size: 12))
                Spacer(minLength: 4)
                Text(binding.text(node.props["relativeTime"]))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(height: PluginKit.leafHeight("activityRow", traits: traits))
        case "fileRow":
            HStack(spacing: 8) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(PluginTextView.text(of: node, binding: binding)).font(.system(size: 12))
                Spacer(minLength: 4)
                Text(binding.text(node.props["size"]))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let request = PluginControlView.request(of: node, binding: binding) {
                    Button {
                        PluginControlView.send(request, sink: sink)
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                }
            }
            .frame(height: PluginKit.leafHeight("fileRow", traits: traits))
        case "compareRow":
            HStack {
                Text(binding.text(node.props["left"])).font(.system(size: 12))
                Spacer()
                Text(binding.text(node.props["right"]))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(height: PluginKit.leafHeight("compareRow", traits: traits))
        default:  // checkRow
            HStack(spacing: 8) {
                Image(systemName: binding.bool(node.props["checked"])
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(binding.bool(node.props["checked"]) ? .green : .secondary)
                Text(PluginTextView.text(of: node, binding: binding)).font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .frame(height: PluginKit.leafHeight("checkRow", traits: traits))
            .contentShape(Rectangle())
            .onTapGesture {
                if let request = PluginControlView.request(of: node, binding: binding) {
                    PluginControlView.send(request, sink: sink)
                }
            }
        }
    }
}
```

Add the cases to `PluginRenderer.component`.

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: the five new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/UI/Plugins/Components/PluginControls.swift Context-Dock/UI/Plugins/Components/PluginCards.swift Context-Dock/UI/Plugins/PluginRenderer.swift Context-DockTests/PluginRendererTests.swift
git commit -m "feat(plugins): controls and the card rows"
```

---

### Task 8: live, media and input — the catalog goes green

**Files:**
- Create: `Context-Dock/UI/Plugins/Components/PluginLive.swift`
- Create: `Context-Dock/UI/Plugins/Components/PluginMedia.swift`
- Create: `Context-Dock/UI/Plugins/Components/PluginInput.swift`
- Modify: `Context-Dock/UI/Plugins/PluginRenderer.swift`
- Test: `Context-DockTests/PluginRendererTests.swift`

**Interfaces:**
- Produces: `PluginLiveView` (`progress`, `timer`, `waveform`, `liveText`, `pulse`), `PluginMediaView` (`mediaCard`, `thumbnail`, `avatar`), `PluginInputView` (`textField`, `searchField`, `dropzone`, `ai`, `native`).
- Produces: `PluginLiveView.isAnimating(_ traits:) -> Bool` — false when `traits.liveBudget == .none`, so a hidden host never ticks.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func liveComponentsFreezeWhenTheHostHasNoBudget() {
        var hidden = HostTraits.cornerPanel
        hidden.liveBudget = .none
        #expect(PluginLiveView.isAnimating(hidden) == false)
        #expect(PluginLiveView.isAnimating(.dockSheet) == true)
    }

    @Test func aMediaCardReadsItsTransportAndVolumeActions() throws {
        let card = try node(#"""
        { "mediaCard": { "title": "{{room}}", "artist": "{{artist}}",
                         "transport": "toggle", "volume": "volume" } }
        """#)
        let binding = PluginBinding(data: ["room": .string("Kitchen"), "artist": .string("Casio")])
        let model = PluginMediaView.model(of: card, binding: binding)
        #expect(model.title == "Kitchen")
        #expect(model.transport == "toggle")
        #expect(model.volume == "volume")
    }

    @Test func progressReadsAFractionAndClampsIt() throws {
        let bar = try node(#"{ "progress": { "value": "{{done}}", "total": "{{all}}" } }"#)
        let binding = PluginBinding(data: ["done": .number(15), "all": .number(10)])
        #expect(PluginLiveView.fraction(of: bar, binding: binding) == 1.0)
        let half = PluginBinding(data: ["done": .number(5), "all": .number(10)])
        #expect(PluginLiveView.fraction(of: bar, binding: half) == 0.5)
    }

    @Test func everyCatalogNameNowHasAView() {
        for component in PluginComponentCatalog.v1 {
            #expect(PluginRenderer.supports(component), "no renderer for \(component)")
            #expect(PluginRenderer.rendersOwnView(component), "catalog name \(component) falls through")
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: build failure — `cannot find 'PluginLiveView' in scope`.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/UI/Plugins/Components/PluginLive.swift
import SwiftUI

struct PluginLiveView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding

    /// A host with no live budget is hidden or shrunk — animation there costs battery for
    /// nobody (spec §5, max 4 live widgets and low budget while the strip is shrunk).
    static func isAnimating(_ traits: HostTraits) -> Bool { traits.liveBudget != .none }

    static func fraction(of node: PluginNode, binding: PluginBinding) -> Double {
        let value = binding.number(node.props["value"]) ?? 0
        let total = binding.number(node.props["total"]) ?? 1
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        switch node.component {
        case "progress":
            ProgressView(value: Self.fraction(of: node, binding: binding))
                .progressViewStyle(.linear)
                .frame(height: PluginKit.leafHeight("progress", traits: traits))
        case "timer":
            Text(binding.text(node.props["text"] ?? node.props["value"]))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(height: PluginKit.leafHeight("timer", traits: traits))
        case "waveform":
            PluginWaveform(active: binding.bool(node.props["text"] ?? node.props["value"])
                && Self.isAnimating(traits))
                .frame(height: PluginKit.leafHeight("waveform", traits: traits))
        case "pulse":
            Circle()
                .fill(PluginStatusTone.tone(for: binding.text(node.props["status"])))
                .frame(width: 8, height: 8)
                .opacity(Self.isAnimating(traits) ? 1 : 0.5)
        default:  // liveText
            Text(PluginTextView.text(of: node, binding: binding))
                .font(.system(size: 12)).monospacedDigit()
                .frame(height: PluginKit.leafHeight("liveText", traits: traits))
        }
    }
}

/// Five bars. Static when the host has no budget, so the strip's shrunk state is quiet.
struct PluginWaveform: View {
    let active: Bool
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 2.5, height: height(index))
            }
        }
        .animation(active ? .easeInOut(duration: 0.45).repeatForever() : .default, value: phase)
        .onAppear { if active { phase = 1 } }
    }

    private func height(_ index: Int) -> CGFloat {
        let base: [CGFloat] = [8, 16, 11, 19, 9]
        return active ? base[index] : 6
    }
}
```

```swift
// Context-Dock/UI/Plugins/Components/PluginMedia.swift
import SwiftUI

struct PluginMediaModel: Equatable {
    let title: String
    let artist: String
    let track: String
    let art: String
    let transport: String
    let volume: String
}

struct PluginMediaView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?

    static func model(of node: PluginNode, binding: PluginBinding) -> PluginMediaModel {
        PluginMediaModel(
            title: binding.text(node.props["title"] ?? node.props["text"]),
            artist: binding.text(node.props["artist"]),
            track: binding.text(node.props["track"]),
            art: binding.text(node.props["art"] ?? node.props["image"]),
            transport: binding.text(node.props["transport"]),
            volume: binding.text(node.props["volume"]))
    }

    var body: some View {
        switch node.component {
        case "thumbnail":
            PluginArtwork(source: binding.text(node.props["text"] ?? node.props["src"]))
                .frame(
                    width: PluginKit.leafHeight("thumbnail", traits: traits),
                    height: PluginKit.leafHeight("thumbnail", traits: traits))
        case "avatar":
            PluginArtwork(source: binding.text(node.props["text"] ?? node.props["src"]))
                .clipShape(Circle())
                .frame(width: 36, height: 36)
        default:  // mediaCard
            let model = Self.model(of: node, binding: binding)
            HStack(spacing: 10) {
                PluginArtwork(source: model.art).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !model.track.isEmpty {
                        Text(model.track).font(.system(size: 12)).lineLimit(1)
                    }
                    if !model.artist.isEmpty {
                        Text(model.artist).font(.system(size: 11))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if !model.transport.isEmpty {
                    Button {
                        sink?.run(PluginActionRequest(name: model.transport))
                    } label: { Image(systemName: "playpause.fill") }
                        .buttonStyle(.plain)
                }
            }
            .frame(height: PluginKit.leafHeight("mediaCard", traits: traits))
        }
    }
}

/// Artwork from a file path or an SF Symbol name. No network in Phase 2 — an `http` art URL
/// renders as the placeholder until Phase 3 fetches it under the declared permission.
struct PluginArtwork: View {
    let source: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if source.hasPrefix("/"), let image = NSImage(contentsOfFile: source) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if !source.isEmpty, NSImage(systemSymbolName: source, accessibilityDescription: nil) != nil {
                Image(systemName: source).font(.system(size: 20)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo").font(.system(size: 16)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface(scheme == .dark))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
```

```swift
// Context-Dock/UI/Plugins/Components/PluginInput.swift
import SwiftUI

struct PluginInputView: View {
    let node: PluginNode
    let traits: HostTraits
    let binding: PluginBinding
    weak var sink: (any PluginActionSink)?
    @State private var text = ""

    var body: some View {
        switch node.component {
        case "searchField":
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(binding.text(node.props["placeholder"]), text: $text)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .frame(height: PluginKit.leafHeight("searchField", traits: traits))
        case "dropzone":
            RoundedRectangle(cornerRadius: PluginKit.cornerRadius, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.secondary)
                .overlay(
                    Text(PluginTextView.text(of: node, binding: binding).isEmpty
                        ? "Drop files here"
                        : PluginTextView.text(of: node, binding: binding))
                        .font(.system(size: 11)).foregroundStyle(.secondary))
                .frame(height: PluginKit.leafHeight("dropzone", traits: traits))
        case "ai":
            // One prompt, one answer, rendered as markdown. Phase 3 runs it; here it shows the
            // prompt it would ask, so the Creator preview is honest about what will happen.
            VStack(alignment: .leading, spacing: 4) {
                Label("Ask", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(binding.text(node.props["prompt"] ?? node.props["text"]))
                    .font(.system(size: 12)).lineLimit(3)
            }
            .frame(height: PluginKit.leafHeight("ai", traits: traits), alignment: .topLeading)
        case "native":
            // The escape hatch for Swift-implemented built-ins (wifi, bluetooth). Phase 8 wires
            // the names; an unknown name is a diagnostic, not a blank.
            PluginDiagnosticsView(diagnostics: [
                PluginDiagnostic(
                    severity: .warning, path: "views",
                    message: "native panel \"\(binding.text(node.props["text"]))\" is not wired yet")
            ])
        default:  // textField
            TextField(binding.text(node.props["placeholder"]), text: $text)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                .frame(height: PluginKit.leafHeight("textField", traits: traits))
        }
    }
}
```

Add the remaining cases to `PluginRenderer.component`, and add the coverage hook the final test calls:

```swift
    /// Every catalog name must land on a real view — the `default` arm is for names the
    /// catalog does not know, and this is what proves none slipped through it.
    static func rendersOwnView(_ component: String) -> Bool {
        !unimplemented.contains(component)
    }

    private static let unimplemented: Set<String> = []
```

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: PASS — including `theRendererImplementsEveryNameInTheCatalog` and `everyCatalogNameNowHasAView`, which have been red since Task 3.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/UI/Plugins/Components/PluginLive.swift Context-Dock/UI/Plugins/Components/PluginMedia.swift Context-Dock/UI/Plugins/Components/PluginInput.swift Context-Dock/UI/Plugins/PluginRenderer.swift Context-DockTests/PluginRendererTests.swift
git commit -m "feat(plugins): live, media and input components — the catalog is covered"
```

---

### Task 9: `PluginCompactRules` — what the corner does differently

**Files:**
- Create: `Context-Dock/UI/Plugins/PluginCompactRules.swift`
- Modify: `Context-Dock/UI/Plugins/PluginRenderer.swift` (apply the rules once, at the root)
- Test: `Context-DockTests/PluginCompactRulesTests.swift`

**Interfaces:**
- Produces: `enum PluginCompactRules` with `static func apply(to root: PluginNode, traits: HostTraits) -> PluginNode`.
- Rules (spec §5, corner row): `listDetail` → `list` (the detail becomes a `push:detail` action on each row); `grid.columns` clamped by `PluginKit.gridColumns`; a row's `accessories` move under the subtitle (metadata stacking); secondary actions move into `actionPanel`.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginCompactRulesTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginCompactRulesTests {
    private func node(_ json: String) throws -> PluginNode {
        try JSONDecoder().decode(PluginNode.self, from: Data(json.utf8))
    }

    @Test func aRegularHostGetsTheTreeUnchanged() throws {
        let tree = try node(#"{ "listDetail": { "items": "{{d}}", "row": { "title": "x" } } }"#)
        #expect(PluginCompactRules.apply(to: tree, traits: .dockSheet) == tree)
    }

    @Test func theCornerTurnsASplitIntoAListThatPushes() throws {
        let tree = try node(#"""
        { "listDetail": { "items": "{{d}}", "row": { "title": "{{item.t}}" },
                          "detail": { "markdown": "{{item.body}}" } } }
        """#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        #expect(compact.component == "list")
        let row = PluginSizing.childNode(compact, key: "row")
        let actions = row?.props["actions"]?.arrayValue ?? []
        #expect(actions.contains { $0.objectValue?["action"]?.stringValue == "push:detail" })
    }

    @Test func theCornerClampsGridColumns() throws {
        let tree = try node(#"{ "grid": { "columns": 6, "items": "{{p}}" } }"#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        #expect(compact.props["columns"] == .number(3))
    }

    @Test func theCornerStacksRowAccessoriesUnderTheSubtitle() throws {
        let tree = try node(#"""
        { "row": { "title": "A", "subtitle": "B", "accessories": [ "1", "2" ] } }
        """#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        #expect(compact.props["accessories"] == nil)
        #expect(compact.props["subtitle"] == .string("B · 1 · 2"))
    }

    @Test func theRulesReachNodesNestedInContainers() throws {
        let tree = try node(#"{ "vstack": [ { "grid": { "columns": 6, "items": "{{p}}" } } ] }"#)
        let compact = PluginCompactRules.apply(to: tree, traits: .cornerPanel)
        #expect(compact.children[0].props["columns"] == .number(3))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginCompactRulesTests`
Expected: build failure — `cannot find 'PluginCompactRules' in scope`.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/UI/Plugins/PluginCompactRules.swift
//
// What the corner does differently, as one pure transform over the tree rather than as `if
// compact` scattered through fifteen component views. The renderer applies it once at the root;
// every component below sees a tree that already means what the corner can show. Spec §5.

import Foundation

enum PluginCompactRules {
    static func apply(to root: PluginNode, traits: HostTraits) -> PluginNode {
        guard traits.widthClass == .compact else { return root }
        return transform(root, traits: traits)
    }

    private static func transform(_ node: PluginNode, traits: HostTraits) -> PluginNode {
        var props = node.props
        var component = node.component

        switch node.component {
        case "listDetail":
            // The split cannot fit: the list stays, and the detail becomes a push.
            component = "list"
            if props["detail"] != nil, let row = PluginSizing.childNode(node, key: "row") {
                var rowProps = row.props
                var actions = rowProps["actions"]?.arrayValue ?? []
                actions.append(.object([
                    "title": .string("Details"), "action": .string("push:detail"),
                ]))
                rowProps["actions"] = .array(actions)
                let pushed = PluginNode(
                    component: row.component, props: rowProps, children: row.children)
                if let data = try? JSONEncoder().encode(pushed),
                    let value = try? JSONDecoder().decode(PluginValue.self, from: data)
                {
                    props["row"] = value
                }
            }

        case "grid":
            let declared = Int(props["columns"]?.numberValue ?? 3)
            props["columns"] = .number(Double(PluginKit.gridColumns(declared, traits: traits)))

        case "row", "fileRow", "checkRow":
            // Metadata stacks: accessories join the subtitle instead of competing for width.
            if let accessories = props["accessories"]?.arrayValue, !accessories.isEmpty {
                let extras = accessories.compactMap { $0.stringValue }
                let subtitle = props["subtitle"]?.stringValue ?? ""
                let joined = ([subtitle] + extras).filter { !$0.isEmpty }.joined(separator: " · ")
                props["subtitle"] = .string(joined)
                props["accessories"] = nil
            }

        default:
            break
        }

        return PluginNode(
            component: component, props: props,
            children: node.children.map { transform($0, traits: traits) })
    }
}
```

`PluginValue` needs the numeric reader this uses. Phase 1 deliberately does not have one —
confirmed at `f58381a`, which has `stringValue`, `boolValue`, `arrayValue`, `objectValue` and
`bindingKey` only, because nothing in the model, schema, pack, registry or migration reads a
number out of a `PluginValue`. This phase is the first caller, so it lands here, with a test —
it is a change to a Phase 1 file and must not arrive silently. Add beside `stringValue` in
`Context-Dock/Services/Plugins/PluginValue.swift`:

```swift
    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
```

and pin it in `PluginCompactRulesTests`:

```swift
    @Test func aNumberReadsOutOfAValueAndOtherCasesDoNot() {
        #expect(PluginValue.number(6).numberValue == 6)
        #expect(PluginValue.string("6").numberValue == nil)
        #expect(PluginValue.null.numberValue == nil)
    }
```

In `PluginRenderer`, apply the rules once at the root rather than per node:

```swift
    /// The entry point a host uses. Applies the compact transform once, then renders.
    static func root(_ node: PluginNode, traits: HostTraits, binding: PluginBinding,
                     sink: (any PluginActionSink)? = nil) -> PluginRenderer {
        PluginRenderer(
            node: PluginCompactRules.apply(to: node, traits: traits),
            traits: traits, binding: binding, sink: sink)
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginCompactRulesTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/UI/Plugins/PluginCompactRules.swift Context-Dock/UI/Plugins/PluginRenderer.swift Context-Dock/Services/Plugins/PluginValue.swift Context-DockTests/PluginCompactRulesTests.swift
git commit -m "feat(plugins): the corner's rules as one transform, not fifteen conditionals"
```

---

### Task 10: the preview harness and the Developer Inspector region

**Files:**
- Create: `Context-Dock/UI/Plugins/PluginPreviewHarness.swift`
- Modify: `Context-Dock/UI/DiagnosticsPanel.swift` (add the "Plugin preview" region)
- Test: `Context-DockTests/PluginRendererTests.swift`

**Interfaces:**
- Consumes: everything above; `PluginManifest.sample`, `PluginSchema.validate(_:)`.
- Produces: `struct PluginPreviewHarness: View { let manifest: PluginManifest }` and `PluginPreviewHarness.traitsAvailable(for:) -> [HostTraits]` — the five traits a manifest can be previewed in, skipping the presentations it does not declare.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func thePreviewOffersOnlyTheTraitsAManifestDeclares() {
        let manifest = PluginManifest(
            id: "sonos", name: "Sonos",
            sample: ["room": .string("Kitchen")],
            views: PluginViews(
                panel: PluginPanelView(root: PluginNode(component: "list"))))
        let traits = PluginPreviewHarness.traitsAvailable(for: manifest)
        #expect(traits.map(\.presentation) == [.panel, .panel])  // dock sheet and corner
        #expect(traits.map(\.widthClass) == [.regular, .compact])
    }

    @Test func thePreviewBindsToTheManifestsSampleData() {
        let manifest = PluginManifest(
            id: "sonos", name: "Sonos", sample: ["room": .string("Kitchen")],
            views: PluginViews(panel: PluginPanelView(root: PluginNode(component: "list"))))
        #expect(PluginPreviewHarness.binding(for: manifest).text(.string("{{room}}")) == "Kitchen")
    }

    @Test func aDeclaredViewWithNoRootPreviewsAsADiagnosticNotABlank() {
        // Phase 1 makes widget/window roots optional and calls an empty declared view a schema
        // error — but the Creator previews manifests that have not been validated yet, so the
        // harness is the one path that meets a nil root in the wild.
        let empty = PluginManifest(
            id: "half-built", name: "Half Built",
            views: PluginViews(widget: PluginWidgetView(family: .medium, root: nil)))
        #expect(PluginPreviewHarness.traitsAvailable(for: empty).map(\.presentation) == [.widget])
        #expect(PluginPreviewHarness.diagnostics(for: empty).isEmpty == false)
    }

    @Test func aManifestWithDiagnosticsPreviewsThemInsteadOfPretendingToRender() {
        let broken = PluginManifest(
            id: "Bad Id", name: "Broken",
            views: PluginViews(panel: PluginPanelView(root: PluginNode(component: "orbitCluster"))))
        #expect(PluginPreviewHarness.diagnostics(for: broken).isEmpty == false)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: build failure — `cannot find 'PluginPreviewHarness' in scope`.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/UI/Plugins/PluginPreviewHarness.swift
//
// One manifest, every host, side by side, from its own `sample` data. This is how Phase 2 is
// looked at by a person before any runtime exists, and it is the same view the Creator's
// preview tabs use in Phase 7 — so a plugin is never previewed by a second renderer.

import SwiftUI

struct PluginPreviewHarness: View {
    let manifest: PluginManifest
    @State private var sink = RecordingActionSink()

    static func binding(for manifest: PluginManifest) -> PluginBinding {
        PluginBinding(data: manifest.sample)
    }

    /// Three sources, because no one of them sees everything: the schema (which cannot walk
    /// into nested node props), unknown component names, and row actions naming an action the
    /// manifest never declared.
    static func diagnostics(for manifest: PluginManifest) -> [PluginDiagnostic] {
        let declared = Set(manifest.actions.keys)
        return PluginSchema.validate(manifest)
            + manifest.allNodes.flatMap { PluginRenderer.diagnostics(for: $0) }
            + manifest.allNodes.filter { $0.component == "list" }.flatMap {
                PluginListView.rowDiagnostics(for: $0, declaredActions: declared)
            }
    }

    /// The traits this manifest can actually be shown in: both panel hosts when it declares a
    /// panel, the strip when it declares an icon or a widget, the window when it declares one.
    static func traitsAvailable(for manifest: PluginManifest) -> [HostTraits] {
        var out: [HostTraits] = []
        for presentation in manifest.declaredPresentations {
            switch presentation {
            case .panel: out.append(contentsOf: [.dockSheet, .cornerPanel])
            case .icon: out.append(.strip(.icon))
            case .widget:
                out.append(.strip(.widget, family: manifest.views.widget?.family ?? .medium))
            case .window:
                out.append(.window(manifest.views.window?.width ?? .regular, screenHeight: 900))
            }
        }
        return out
    }

    /// `widget.root` and `window.root` are optional in the model, so each read is a double
    /// optional — `flatMap`, not `?`. A nil root is a schema error, which means a validated
    /// manifest never gets here with one; the Creator previews *unvalidated* manifests, so this
    /// path must still answer nil rather than crash, and the caller draws a diagnostic.
    private func root(for traits: HostTraits) -> PluginNode? {
        switch traits.presentation {
        case .panel: return manifest.views.panel?.root
        case .widget: return manifest.views.widget.flatMap(\.root)
        case .window: return manifest.views.window.flatMap(\.root)
        case .icon:
            if let root = manifest.views.icon.flatMap(\.root) { return root }
            guard let capsule = manifest.views.icon?.capsule else { return nil }
            return PluginNode(component: "capsule", children: capsule)
        }
    }

    var body: some View {
        let diagnostics = Self.diagnostics(for: manifest)
        VStack(alignment: .leading, spacing: 12) {
            if !diagnostics.isEmpty {
                PluginDiagnosticsView(diagnostics: diagnostics)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(Self.traitsAvailable(for: manifest).enumerated()), id: \.offset) {
                        _, traits in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(traits.presentation.rawValue) · \(traits.widthClass.rawValue)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            if root(for: traits) == nil {
                                PluginDiagnosticsView(diagnostics: [
                                    PluginDiagnostic(
                                        severity: .error,
                                        path: "views.\(traits.presentation.rawValue)",
                                        message: "declared with no root to draw")
                                ])
                            }
                            if let root = root(for: traits) {
                                PluginRenderer.root(
                                    root, traits: traits,
                                    binding: Self.binding(for: manifest), sink: sink)
                                    .frame(
                                        width: traits.width,
                                        height: PluginSizing.treeHeight(
                                            root, traits: traits,
                                            binding: Self.binding(for: manifest)),
                                        alignment: .top)
                            }
                        }
                    }
                }
            }
        }
    }
}
```

In `Context-Dock/UI/DiagnosticsPanel.swift`, add a region that loads any manifest from
`PluginRegistry.shared` (Phase 1) and renders `PluginPreviewHarness(manifest:)` for the
selected one. Follow the file's existing region pattern — do not invent a second panel style.

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRendererTests`
Expected: PASS, all tests in the suite.

- [ ] **Step 5: Run the whole suite and confirm by name**

Run: `cd <worktree> && pwd && pkill -9 -f "Context-Dock.app" ; ./scripts/test.sh`
Expected: the verdict line and the counts together; `PluginBindingTests`, `PluginSizingTests`, `PluginRendererTests` and `PluginCompactRulesTests` all appear by name. The three machine-dependent failures noted in the brain's status doc may still be there; no new ones.

- [ ] **Step 6: Build, launch and look at it**

Run: `cd <worktree> && pwd && ./scripts/dev-run.sh`, open the Developer Inspector, pick the
Sonos example manifest, and confirm the exit condition below by eye in all five traits.

- [ ] **Step 7: Commit**

```bash
git add Context-Dock/UI/Plugins/PluginPreviewHarness.swift Context-Dock/UI/DiagnosticsPanel.swift Context-DockTests/PluginRendererTests.swift
git commit -m "feat(plugins): preview any manifest in every host from its own sample data"
```

---

## Exit condition (from the roadmap)

The Sonos and YouTube-thumbnail example manifests in spec §7 render in all five traits from
sample data; heights come from `PluginSizing` and nothing measures; no component styles itself
outside `PluginKit` and `Theme`. `PluginComponentCatalog.v1` is fully covered by
`theRendererImplementsEveryNameInTheCatalog` and `everyCatalogNameNowHasAView`.

## Not in this phase

- Running any script, fetching `http` artwork, or asking a model anything (`ai` shows its
  prompt only) — Phase 3.
- The strip host for `icon` / `widget` — Phase 4, after #24 lands.
- `push:<view>` actually pushing — the compact rule emits the action; the navigation stack that
  consumes it is Phase 4.
- Keyboard handling (⏎ / ⌘⏎ / ⌘K) — Phase 4, where a host owns the keyboard.

## Inherited from Phase 1 — read before Task 1

Established against `plugins` at `f58381a`, in conversation with the session that built it:

- **`PluginValue` has no number accessor.** Task 9 adds `numberValue` with its own test. Do not
  assume it exists when reading earlier tasks.
- **`PluginWidgetView.root` and `PluginWindowView.root` are optional**, and `PluginIconView` /
  `PluginWindowView` accept the bare-node shorthand that `PluginPanelView` already did (landed in
  Phase 1's final review wave). A declared-but-empty view is a schema *error* now, so a validated
  manifest never reaches the renderer with a nil root — but an **unvalidated one does**, and
  Task 10's Creator-preview path is exactly that case. Every `views.<presentation>?.root` read in
  this plan is therefore a double optional: write `manifest.views.widget.flatMap(\.root)`, and
  render a diagnostic rather than a blank when it is nil.
- **`PluginAction.risk` now defaults to `.low` for script-typed actions**, not `.read`. Nothing in
  this phase reads `risk` — `PluginActionSink` carries a name and a value, and approval is
  Phase 3's job — but do not add a risk check here on the assumption that the default is `.read`.
- **`PluginNode.init(value:path:)` already re-decodes a nested prop** — use it (Task 2 wraps it)
  rather than writing a second JSON round-trip. Its `path` parameter is vestigial: never read,
  and it does not improve the thrown error's `codingPath`. Dropping it in favour of
  `init(value:)` is agreed as acceptable *if* it lands with a test pinning the nested-prop case;
  this plan does not require it, and passing `[]` is correct meanwhile.
- **Nested node props are invisible to `PluginSchema`.** `"row": { … }`, `"cell": { … }` and
  `"detail": { … }` are stored as `PluginValue.object`, so validation never walks into them: a
  binding or an action name inside a repeated row gets no diagnostic at install time.
  `PluginMigration` emits exactly that shape for every converted `provider:custom` list, so this
  reaches real users. Tracked as **#27**.

  **Check #27 before starting Task 4 — its fix changes that task's size.** The direction settled
  there (by the session that owns Phase 1) is neither of the two obvious ones: not promoting
  node-valued props to `children` at decode time — `children` means "drawn, in order, once
  each", and a `row` is a template instantiated per item, so promotion makes the tree lie about
  the view and loses the prop name a diagnostic needs — and not an explicit walk inside
  `PluginSchema`, which puts "which props hold nodes" in the validator while this renderer needs
  the same list to draw them. The fix is `PluginNode.nodeProps: [String: PluginNode]`, keyed by
  prop name, `children` untouched, `flattened` gaining the subtrees, with the "is this prop a
  node" predicate (a single-key object whose key is in `PluginComponentCatalog`) living in the
  catalog.

  If **#27 has landed** when you reach Task 2 and Task 4: `PluginSizing.childNode(_:key:)` and
  `PluginListView.rowTemplate(of:)` become a lookup in `nodeProps` rather than a re-decode (delete
  the re-decode, keep the signatures — every caller in this plan is unchanged), and
  `rowDiagnostics(for:declaredActions:)` shrinks to a thin call over what the schema already
  reports. If **#27 has not landed**, build them as written and leave a comment on #27 saying the
  stand-in is now in the tree, so whoever takes it knows what to unwind.

## Self-review

- **Spec coverage.** §5's five hosts → Task 1 (`HostTraits`) and Task 10 (previewed in all of
  them). §5's corner rules → Task 9. §6's ten component groups → Tasks 3–8, and the catalog test
  is what proves none was skipped. §7's binding rules → Task 1. §7's `list` item contract
  (`id`, `title`, `subtitle`, `icon`, `accessories`, `detail`, `actions`) → `PluginRowModel` in
  Task 4 and `PluginDetailModel` in Task 5. The purity rule from `docs/architecture/PLUGINS.md`
  → Task 2, asserted by `theSameInputsAlwaysGiveTheSameHeight` and used by Task 10's frame.
- **Placeholders.** None: every step carries the code it asks for. The one instruction without a
  code block is the Developer Inspector region in Task 10, which is deliberate — that file has an
  established region pattern and inventing a second one here would be the wrong instruction.
- **Type consistency.** `PluginBinding.text/bool/number/items/resolve/scoped` are used with those
  names in every later task; `PluginSizing.childNode(_:key:)` is defined in Task 2 and used in
  Tasks 4, 5 and 9; `PluginActionRequest(name:value:)` is the only action shape anywhere;
  `PluginKit.leafHeight` is the single height source for both the sizing arithmetic and the
  component frames, which is what keeps drawing and hit-testing agreed.
