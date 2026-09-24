# Plugins Phase 3 — Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A plugin's data script runs, its output becomes the `PluginBinding` the Phase 2 renderer already draws from, and its actions run under a permission gate.

**Architecture:** Four pure pieces and one impure one. `PluginEnvironment` (inputs → `CD_*`), `PluginOutput` (stdout + format → `PluginValue`), `PluginPermissions` (manifest → what it may do), and `PluginRefreshPolicy` (host + presentation → an interval) are all pure functions with no I/O. `PluginScriptRunner` is the only thing that touches `Process`, the network or the clock. `PluginRuntime` is the actor that wires them together and holds the cache.

**Tech Stack:** Swift 5, swift-testing, Foundation `Process`, `URLSession` (http type only), AppKit for the built-in action types.

**Spec:** `docs/superpowers/specs/2026-09-15-plugins-design.md` §7 (data contract), §8 (inputs), §9 (permissions). Roadmap: `docs/superpowers/plans/2026-09-15-plugins-todo.md` Phase 3.

## How to read the code in this plan

**The reference code below is a sketch to check against the source, not text to transcribe.**
Phases 1 and 2 both ended with the same finding: nearly every defect was in the plan's own
reference code, not in what the implementer wrote (decision `93d5805a` lists six). Two of them
named initialisers and fields that did not exist. So: before using any block here, open the
type it touches and confirm the names. Where this plan and the source disagree, **the source
wins** and the plan is wrong.

## Global Constraints

- Deployment target macOS 26.1; Swift 5.0; tests are swift-testing (`import Testing`, `@Test`), never XCTest.
- Build and run only via `./scripts/dev-run.sh` / `./scripts/build-debug.sh`; tests via `./scripts/test.sh`.
- Pure logic never reaches for a singleton. Anything that runs a process, opens a socket or reads the clock goes behind `PluginScriptRunner` or `PluginRuntime` so the rest stays testable offline.
- The suite is offline. No test may run a network call, and no test may depend on a script that is not in the repo.
- **A script's text is never rewritten.** A migrated command's script keeps working byte-for-byte; formats (`json`, `jsonl`, `lines`, `raw`) exist so the runner adapts to the script rather than the other way round.
- Two pre-existing suite failures are expected and are not yours: `priorityTypedCapabilitiesDeclareTheExpectedRisk` and `anIdlePromptShrinksToTheAppIcon`.

---

### Task 1: `PluginEnvironment` — every `CD_*` variable

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginEnvironment.swift`
- Test: `Context-DockTests/PluginEnvironmentTests.swift`

**Interfaces:**
- Produces: `struct PluginInputs` (`query`, `selectionText`, `selectionFiles: [String]`, `selectionURL`, `selectionImage`, `clipboardText`, `clipboardFiles: [String]`, `clipboardImage`, `clipboardHistoryPath`, `frontmostApp`, `rowID`, `rowTitle`, `rowRaw`, `value: PluginValue?`) — all optional, all defaulting to nil.
- Produces: `enum PluginEnvironment { static func build(inputs: PluginInputs, host: PluginPresentation, widthClass: PluginWidthClass) -> [String: String] }`.

The existing names must not change: `CD_QUERY`, `CD_TEXT`, `CD_URL`, `CD_APP`, `CD_ROW_ID`, `CD_ROW_TITLE`, `CD_ROW` are what today's Global Commands and Global Extensions already read. New: `CD_FILES` (newline-separated), `CD_IMAGE`, `CD_CLIP_TEXT`, `CD_CLIP_FILES`, `CD_CLIP_IMAGE`, `CD_CLIP_HISTORY`, `CD_HOST`, `CD_WIDTH`, `CD_VALUE`.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginEnvironmentTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginEnvironmentTests {
    @Test func theHostAndWidthAreAlwaysPresent() {
        let env = PluginEnvironment.build(
            inputs: PluginInputs(), host: .panel, widthClass: .compact)
        #expect(env["CD_HOST"] == "panel")
        #expect(env["CD_WIDTH"] == "compact")
    }

    @Test func anAbsentInputSetsNoVariableAtAll() {
        // Not "" — a script tests `[ -n "$CD_TEXT" ]`, and an empty string that exists is a
        // different answer from a variable that does not.
        let env = PluginEnvironment.build(inputs: PluginInputs(), host: .panel, widthClass: .regular)
        #expect(env["CD_TEXT"] == nil)
        #expect(env["CD_QUERY"] == nil)
    }

    @Test func theNamesTodaysScriptsReadAreUnchanged() {
        var inputs = PluginInputs()
        inputs.query = "ports"
        inputs.selectionText = "hello"
        inputs.selectionURL = "https://example.com"
        inputs.frontmostApp = "Safari"
        inputs.rowID = "t1"
        inputs.rowTitle = "Jungle"
        inputs.rowRaw = "Jungle | Casio"
        let env = PluginEnvironment.build(inputs: inputs, host: .panel, widthClass: .regular)
        #expect(env["CD_QUERY"] == "ports")
        #expect(env["CD_TEXT"] == "hello")
        #expect(env["CD_URL"] == "https://example.com")
        #expect(env["CD_APP"] == "Safari")
        #expect(env["CD_ROW_ID"] == "t1")
        #expect(env["CD_ROW_TITLE"] == "Jungle")
        #expect(env["CD_ROW"] == "Jungle | Casio")
    }

    @Test func fileListsAreNewlineSeparated() {
        var inputs = PluginInputs()
        inputs.selectionFiles = ["/tmp/a.txt", "/tmp/b.txt"]
        inputs.clipboardFiles = ["/tmp/c.txt"]
        let env = PluginEnvironment.build(inputs: inputs, host: .window, widthClass: .regular)
        #expect(env["CD_FILES"] == "/tmp/a.txt\n/tmp/b.txt")
        #expect(env["CD_CLIP_FILES"] == "/tmp/c.txt")
    }

    @Test func aControlValueBecomesAStringWhateverItsType() {
        var slider = PluginInputs()
        slider.value = .number(35)
        #expect(PluginEnvironment.build(inputs: slider, host: .panel, widthClass: .regular)["CD_VALUE"] == "35")
        var toggle = PluginInputs()
        toggle.value = .bool(true)
        #expect(PluginEnvironment.build(inputs: toggle, host: .panel, widthClass: .regular)["CD_VALUE"] == "true")
        var field = PluginInputs()
        field.value = .string("kitchen")
        #expect(PluginEnvironment.build(inputs: field, host: .panel, widthClass: .regular)["CD_VALUE"] == "kitchen")
    }

    @Test func aWholeNumberValueHasNoDecimalPoint() {
        // `CD_VALUE=35.0` breaks `[ "$CD_VALUE" -gt 30 ]` in every shell script that does arithmetic.
        var inputs = PluginInputs()
        inputs.value = .number(35)
        #expect(PluginEnvironment.build(inputs: inputs, host: .panel, widthClass: .regular)["CD_VALUE"] == "35")
    }

    @Test func theProcessEnvironmentIsNotInHere() {
        // build() returns only the plugin's own variables; merging with the process
        // environment is the runner's job, so this stays a pure function of its inputs.
        let env = PluginEnvironment.build(inputs: PluginInputs(), host: .icon, widthClass: .compact)
        #expect(env["PATH"] == nil)
        #expect(env.keys.allSatisfy { $0.hasPrefix("CD_") })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginEnvironmentTests`
Expected: build failure — `cannot find 'PluginEnvironment' in scope`.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/Services/Plugins/PluginEnvironment.swift
//
// What a plugin's script can see. Pure: inputs in, variables out, no store and no process —
// the runner merges these over the real environment. Spec §8.

import Foundation

struct PluginInputs: Equatable {
    var query: String?
    var selectionText: String?
    var selectionFiles: [String] = []
    var selectionURL: String?
    var selectionImage: String?
    var clipboardText: String?
    var clipboardFiles: [String] = []
    var clipboardImage: String?
    var clipboardHistoryPath: String?
    var frontmostApp: String?
    var rowID: String?
    var rowTitle: String?
    var rowRaw: String?
    var value: PluginValue?

    init() {}
}

enum PluginEnvironment {
    static func build(inputs: PluginInputs, host: PluginPresentation,
                      widthClass: PluginWidthClass) -> [String: String] {
        var env: [String: String] = [
            "CD_HOST": host.rawValue,
            "CD_WIDTH": widthClass.rawValue,
        ]
        // An absent input sets no variable: `[ -n "$CD_TEXT" ]` must be able to tell
        // "nothing was selected" from "empty text was selected".
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            env[key] = value
        }
        func putList(_ key: String, _ paths: [String]) {
            guard !paths.isEmpty else { return }
            env[key] = paths.joined(separator: "\n")
        }
        put("CD_QUERY", inputs.query)
        put("CD_TEXT", inputs.selectionText)
        putList("CD_FILES", inputs.selectionFiles)
        put("CD_URL", inputs.selectionURL)
        put("CD_IMAGE", inputs.selectionImage)
        put("CD_CLIP_TEXT", inputs.clipboardText)
        putList("CD_CLIP_FILES", inputs.clipboardFiles)
        put("CD_CLIP_IMAGE", inputs.clipboardImage)
        put("CD_CLIP_HISTORY", inputs.clipboardHistoryPath)
        put("CD_APP", inputs.frontmostApp)
        put("CD_ROW_ID", inputs.rowID)
        put("CD_ROW_TITLE", inputs.rowTitle)
        put("CD_ROW", inputs.rowRaw)
        put("CD_VALUE", inputs.value.map(string(from:)))
        return env
    }

    /// A number a script can do arithmetic on: `35`, never `35.0`.
    private static func string(from value: PluginValue) -> String {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            return n == n.rounded() ? String(Int(n)) : String(n)
        case .null: return ""
        case .array, .object:
            guard let data = try? JSONEncoder().encode(value) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginEnvironmentTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/Services/Plugins/PluginEnvironment.swift Context-DockTests/PluginEnvironmentTests.swift
git commit -m "feat(plugins): every CD_* variable a script can read, as a pure function"
```

---

### Task 2: `PluginOutput` — stdout becomes bindable data

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginOutput.swift`
- Test: `Context-DockTests/PluginOutputTests.swift`

**Interfaces:**
- Consumes: `PluginDataFormat` (`json`, `jsonl`, `lines`, `raw`), `PluginValue`.
- Produces: `enum PluginOutput { static func decode(_ stdout: String, format: PluginDataFormat) -> Result<PluginValue, PluginDiagnostic> }`.

The four formats exist because a migrated script keeps working unchanged: `lines` is the `"Title | subtitle"` shape Global Extensions print, `jsonl` is one JSON object per line, `raw` is a single value (a volume level), `json` is an object.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginOutputTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginOutputTests {
    private func value(_ text: String, _ format: PluginDataFormat) throws -> PluginValue {
        switch PluginOutput.decode(text, format: format) {
        case .success(let value): return value
        case .failure(let diagnostic): throw PluginOutputTestError(message: diagnostic.message)
        }
    }

    struct PluginOutputTestError: Error { let message: String }

    @Test func jsonBecomesItsObject() throws {
        let out = try value(#"{ "room": "Kitchen", "playing": true }"#, .json)
        #expect(out.objectValue?["room"] == .string("Kitchen"))
        #expect(out.objectValue?["playing"] == .bool(true))
    }

    @Test func brokenJsonIsADiagnosticNamingTheFormat() {
        switch PluginOutput.decode("{ not json", format: .json) {
        case .success: Issue.record("broken JSON decoded")
        case .failure(let diagnostic):
            #expect(diagnostic.severity == .error)
            #expect(diagnostic.message.contains("JSON"))
        }
    }

    @Test func linesBecomeItemsWithTitleAndSubtitle() throws {
        // What every Global Extension prints today: "Title | subtitle", one per line.
        let out = try value("main | origin/main\nfix-91 | \n\n", .lines)
        let items = try #require(out.objectValue?["lines"]?.arrayValue)
        #expect(items.count == 2)
        #expect(items[0].objectValue?["title"] == .string("main"))
        #expect(items[0].objectValue?["subtitle"] == .string("origin/main"))
        #expect(items[1].objectValue?["title"] == .string("fix-91"))
        #expect(items[1].objectValue?["subtitle"] == .string(""))
    }

    @Test func aLineKeepsItsWholeSelfForCD_ROW() throws {
        // The row action is handed `CD_ROW` verbatim, so the raw line has to survive decoding.
        let out = try value("main | origin/main", .lines)
        let items = try #require(out.objectValue?["lines"]?.arrayValue)
        #expect(items[0].objectValue?["raw"] == .string("main | origin/main"))
    }

    @Test func jsonlBecomesOneItemPerLineAndSkipsBlanks() throws {
        let out = try value("{\"title\":\"a\"}\n\n{\"title\":\"b\"}\n", .jsonl)
        let items = try #require(out.objectValue?["lines"]?.arrayValue)
        #expect(items.map { $0.objectValue?["title"] } == [.string("a"), .string("b")])
    }

    @Test func oneBadLineInJsonlDoesNotLoseTheGoodOnes() {
        // A long-running list must not go blank because one row is malformed.
        switch PluginOutput.decode("{\"title\":\"a\"}\nnot json\n", format: .jsonl) {
        case .failure(let diagnostic): Issue.record("lost the whole list: \(diagnostic.message)")
        case .success(let value):
            #expect(value.objectValue?["lines"]?.arrayValue?.count == 1)
        }
    }

    @Test func rawIsTheTrimmedTextUnderValue() throws {
        let out = try value("  42\n", .raw)
        #expect(out.objectValue?["value"] == .string("42"))
    }

    @Test func emptyOutputIsEmptyDataNotAFailure() throws {
        // A list with nothing in it is the empty state, which Phase 2 already draws. It is
        // not an error, and must not be reported as one.
        #expect(try value("", .lines).objectValue?["lines"]?.arrayValue?.isEmpty == true)
        #expect(try value("", .jsonl).objectValue?["lines"]?.arrayValue?.isEmpty == true)
        #expect(try value("", .raw).objectValue?["value"] == .string(""))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginOutputTests`
Expected: build failure — `cannot find 'PluginOutput' in scope`.

- [ ] **Step 3: Implement**

```swift
// Context-Dock/Services/Plugins/PluginOutput.swift
//
// A script's stdout, as data the renderer can bind to. Pure. The four formats exist so a
// migrated script keeps working byte-for-byte: `lines` is the "Title | subtitle" shape every
// Global Extension prints, `raw` is a single value, `jsonl` one object per line.

import Foundation

enum PluginOutput {
    static func decode(_ stdout: String, format: PluginDataFormat)
        -> Result<PluginValue, PluginDiagnostic>
    {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        switch format {
        case .json:
            guard !text.isEmpty else { return .success(.object([:])) }
            guard let data = text.data(using: .utf8),
                let value = try? JSONDecoder().decode(PluginValue.self, from: data)
            else {
                return .failure(PluginDiagnostic(
                    severity: .error, path: "data",
                    message: "the script did not print JSON (format: json)"))
            }
            return .success(value)

        case .jsonl:
            // One bad line never costs the good ones: a list that goes blank because one row
            // is malformed is worse than a list one row short.
            let items = text.split(separator: "\n").compactMap { line -> PluginValue? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(PluginValue.self, from: data)
            }
            return .success(.object(["lines": .array(items)]))

        case .lines:
            let items = text.split(separator: "\n").compactMap { line -> PluginValue? in
                let raw = line.trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty else { return nil }
                let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let title = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? raw
                let subtitle = parts.count > 1
                    ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                return .object([
                    "title": .string(title),
                    "subtitle": .string(subtitle),
                    "raw": .string(raw),
                ])
            }
            return .success(.object(["lines": .array(items)]))

        case .raw:
            return .success(.object(["value": .string(text)]))
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginOutputTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/Services/Plugins/PluginOutput.swift Context-DockTests/PluginOutputTests.swift
git commit -m "feat(plugins): a script's stdout becomes data, in all four formats"
```

---

### Task 3: `PluginPermissions` — what a manifest is allowed to do

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginPermissions.swift`
- Test: `Context-DockTests/PluginPermissionsTests.swift`

**Interfaces:**
- Consumes: `PluginManifest`, `PluginAction`, `PluginRisk`.
- Produces: `struct PluginPermissionSet` (`implied: Set<String>`, `declared: Set<String>`, `undeclared: Set<String>`) and `enum PluginPermissions { static func required(for: PluginManifest) -> PluginPermissionSet; static func needsApproval(_ action: PluginAction) -> Bool; static func allowsHost(_ host: String, manifest: PluginManifest) -> Bool }`.

This is the sharpest edge in the epic: a manifest is a text file that asks to run shell. The rule this task encodes is that **the manifest's own `permissions` list is a claim, not a grant** — what it actually needs is derived from what it contains, and anything it needs but did not declare is reported rather than silently allowed.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginPermissionsTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginPermissionsTests {
    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    @Test func aScriptActionImpliesTheShellPermission() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "actions": { "go": { "type": "bash", "script": "rm -rf /tmp/x" } } }"#)
        #expect(PluginPermissions.required(for: m).implied.contains("shell"))
    }

    @Test func anHttpDataSourceImpliesNetworkForItsHost() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "data": { "type": "http", "script": "https://api.example.com/v1/status" } }"#)
        #expect(PluginPermissions.required(for: m).implied.contains("network:api.example.com"))
    }

    @Test func aPermissionItNeedsButNeverDeclaredIsReported() throws {
        // The manifest's own list is a claim. What it needs comes from what it contains, and
        // the difference is what a person is asked about at install.
        let m = try manifest(#"{ "id": "x", "name": "X", "permissions": [], "actions": { "go": { "type": "bash", "script": "true" } } }"#)
        #expect(PluginPermissions.required(for: m).undeclared.contains("shell"))
    }

    @Test func aDeclaredPermissionItDoesNotNeedIsNotRequired() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "permissions": ["network:local"], "views": { "panel": { "title": "hi" } } }"#)
        let set = PluginPermissions.required(for: m)
        #expect(set.implied.isEmpty)
        #expect(set.undeclared.isEmpty)
    }

    @Test func readIsTheOnlyRiskThatRunsWithoutAsking() {
        #expect(PluginPermissions.needsApproval(PluginAction(type: "bash", script: "ls", risk: .read)) == false)
        #expect(PluginPermissions.needsApproval(PluginAction(type: "bash", script: "rm x", risk: .low)))
        #expect(PluginPermissions.needsApproval(PluginAction(type: "bash", script: "rm x", risk: .medium)))
        #expect(PluginPermissions.needsApproval(PluginAction(type: "bash", script: "rm x", risk: .high)))
    }

    @Test func aHostIsReachableOnlyWhenItWasDeclared() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "permissions": ["network:api.example.com"] }"#)
        #expect(PluginPermissions.allowsHost("api.example.com", manifest: m))
        #expect(PluginPermissions.allowsHost("evil.example.com", manifest: m) == false)
    }

    @Test func networkLocalCoversLoopbackAndNothingElse() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "permissions": ["network:local"] }"#)
        #expect(PluginPermissions.allowsHost("127.0.0.1", manifest: m))
        #expect(PluginPermissions.allowsHost("localhost", manifest: m))
        #expect(PluginPermissions.allowsHost("192.168.1.40", manifest: m))
        #expect(PluginPermissions.allowsHost("example.com", manifest: m) == false)
    }

    @Test func aPluginThatDeclaredNoNetworkReachesNothing() throws {
        let m = try manifest(#"{ "id": "x", "name": "X" }"#)
        #expect(PluginPermissions.allowsHost("example.com", manifest: m) == false)
        #expect(PluginPermissions.allowsHost("127.0.0.1", manifest: m) == false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginPermissionsTests`
Expected: build failure — `cannot find 'PluginPermissions' in scope`.

- [ ] **Step 3: Implement**

Derive `implied` by walking `manifest.data` and every `manifest.actions` value: a script type (`bash`, `applescript`, `jxa`, `scriptFile`) implies `"shell"`, `shortcut` implies `"shortcuts"`, `http` implies `"network:<host of the URL>"`, and the built-ins (`copy`, `paste`, `open`, `reveal`, `push:`) imply nothing. `undeclared` is `implied.subtracting(declared)`. `needsApproval` is `action.risk != .read`. `allowsHost` matches a declared `network:<host>` exactly, and treats `network:local` as loopback plus the RFC1918 ranges (`10.`, `192.168.`, `172.16.`–`172.31.`) — the Sonos case, where the device is on the LAN and has no public name.

Check `PluginAction`'s real initialiser before writing the tests' `PluginAction(type:script:risk:)` calls — if its memberwise init differs, use what the source has and fix the tests, not the source.

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginPermissionsTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/Services/Plugins/PluginPermissions.swift Context-DockTests/PluginPermissionsTests.swift
git commit -m "feat(plugins): what a manifest needs is derived, never simply claimed"
```

---

### Task 4: `PluginRefreshPolicy` — how often, and when never

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginRefreshPolicy.swift`
- Test: `Context-DockTests/PluginRefreshPolicyTests.swift`

**Interfaces:**
- Consumes: `PluginDataSource.refresh` (`[PluginPresentation: Int]`, seconds, `0` meaning never), `HostTraits.liveBudget`.
- Produces: `enum PluginRefreshPolicy { static func interval(for: PluginManifest, host: PluginPresentation, budget: PluginLiveBudget) -> TimeInterval?; static func admits(runningLiveCount: Int) -> Bool }` — `nil` means "do not refresh on a timer".

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginRefreshPolicyTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginRefreshPolicyTests {
    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private let sonos = #"""
    { "id": "s", "name": "S",
      "data": { "type": "bash", "script": "data.sh",
                "refresh": { "icon": 30, "widget": 5, "panel": 0, "window": 1 } } }
    """#

    @Test func eachHostGetsItsOwnInterval() throws {
        let m = try manifest(sonos)
        #expect(PluginRefreshPolicy.interval(for: m, host: .icon, budget: .full) == 30)
        #expect(PluginRefreshPolicy.interval(for: m, host: .widget, budget: .full) == 5)
        #expect(PluginRefreshPolicy.interval(for: m, host: .window, budget: .full) == 1)
    }

    @Test func zeroMeansNeverRatherThanEveryZeroSeconds() throws {
        // A refresh of 0 read as an interval is an infinite loop that runs a shell script.
        #expect(PluginRefreshPolicy.interval(for: try manifest(sonos), host: .panel, budget: .full) == nil)
    }

    @Test func aHostWithNoBudgetNeverTicks() throws {
        let m = try manifest(sonos)
        #expect(PluginRefreshPolicy.interval(for: m, host: .widget, budget: .none) == nil)
    }

    @Test func aLowBudgetSlowsDownRatherThanStopping() throws {
        let m = try manifest(sonos)
        let full = try #require(PluginRefreshPolicy.interval(for: m, host: .widget, budget: .full))
        let low = try #require(PluginRefreshPolicy.interval(for: m, host: .widget, budget: .low))
        #expect(low > full)
    }

    @Test func aManifestWithNoDataSourceNeverTicks() throws {
        let m = try manifest(#"{ "id": "x", "name": "X" }"#)
        #expect(PluginRefreshPolicy.interval(for: m, host: .panel, budget: .full) == nil)
    }

    @Test func noMoreThanFourPluginsTickAtOnce() {
        // Spec §5. The fifth live widget is what turns a dock into a battery complaint.
        #expect(PluginRefreshPolicy.admits(runningLiveCount: 3))
        #expect(PluginRefreshPolicy.admits(runningLiveCount: 4) == false)
    }

    @Test func anIntervalIsNeverFasterThanTheFloor() throws {
        // A manifest asking for 0.1s would run a process ten times a second.
        let greedy = try manifest(#"{ "id": "x", "name": "X", "data": { "type": "bash", "script": "s", "refresh": { "panel": 1 } } }"#)
        let interval = try #require(PluginRefreshPolicy.interval(for: greedy, host: .panel, budget: .full))
        #expect(interval >= 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRefreshPolicyTests`
Expected: build failure — `cannot find 'PluginRefreshPolicy' in scope`.

- [ ] **Step 3: Implement**

`interval` reads `manifest.data?.refresh[host]`, returns `nil` for a missing source, a missing entry or `0`, clamps to a one-second floor, returns `nil` for `.none` budget and multiplies by 4 for `.low`. `admits` is `runningLiveCount < 4`.

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRefreshPolicyTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/Services/Plugins/PluginRefreshPolicy.swift Context-DockTests/PluginRefreshPolicyTests.swift
git commit -m "feat(plugins): a refresh cadence per host, and zero means never"
```

---

### Task 5: `PluginScriptRunner` — the one place a process starts

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginScriptRunner.swift`
- Test: `Context-DockTests/PluginScriptRunnerTests.swift`

**Interfaces:**
- Consumes: `PluginEnvironment`, `PluginOutput`, `PluginPermissions`, `PluginScriptType`.
- Produces: `struct PluginRunResult { let stdout: String; let stderr: String; let exitCode: Int32 }`, `struct PluginRunFailure: Error { let message: String; let kind: Kind }` with `Kind` of `.launch`, `.timeout`, `.exit`, `.blocked`, and `actor PluginScriptRunner` with `func run(type:script:env:timeout:workingDirectory:) async -> Result<PluginRunResult, PluginRunFailure>`.

This replaces `UserExtensionScriptRunner` (in `UserGlobalExtensionStore.swift`) and the runner inside `CustomListProviderService`. Read the existing one first: it uses `/bin/zsh -lc`, `/usr/bin/osascript` (with `-l JavaScript` for jxa), merges over `ProcessInfo.processInfo.environment`, and trims output. **Keep all of that** — a migrated script must behave identically. What it lacks and this one adds: a timeout, `scriptFile` and `http`, and a typed failure.

These tests run real processes, which is allowed — they use `/bin/echo` and `sleep`, touch no network and need no API key.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginScriptRunnerTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginScriptRunnerTests {
    private let runner = PluginScriptRunner()

    @Test func bashPrintsAndTheOutputComesBackTrimmed() async throws {
        let result = await runner.run(
            type: .bash, script: "echo hello", env: [:], timeout: 5, workingDirectory: nil)
        switch result {
        case .failure(let failure): Issue.record("failed: \(failure.message)")
        case .success(let run):
            #expect(run.stdout == "hello")
            #expect(run.exitCode == 0)
        }
    }

    @Test func theEnvironmentReachesTheScript() async throws {
        let result = await runner.run(
            type: .bash, script: "echo \"$CD_QUERY\"", env: ["CD_QUERY": "ports"],
            timeout: 5, workingDirectory: nil)
        #expect(try result.get().stdout == "ports")
    }

    @Test func theProcessEnvironmentSurvivesTheMerge() async throws {
        // A script calls `git`, `jq`, `lsof`. Replacing the environment instead of merging
        // over it empties PATH and every one of those stops resolving.
        let result = await runner.run(
            type: .bash, script: "echo \"$PATH\"", env: ["CD_QUERY": "x"],
            timeout: 5, workingDirectory: nil)
        #expect(try result.get().stdout.isEmpty == false)
    }

    @Test func aNonZeroExitIsAFailureCarryingStderr() async {
        let result = await runner.run(
            type: .bash, script: "echo boom >&2; exit 3", env: [:], timeout: 5,
            workingDirectory: nil)
        switch result {
        case .success: Issue.record("a failing script reported success")
        case .failure(let failure):
            #expect(failure.kind == .exit)
            #expect(failure.message.contains("boom"))
        }
    }

    @Test func aScriptThatHangsIsKilledAtItsTimeout() async {
        let started = Date()
        let result = await runner.run(
            type: .bash, script: "sleep 30", env: [:], timeout: 1, workingDirectory: nil)
        switch result {
        case .success: Issue.record("a hanging script was allowed to finish")
        case .failure(let failure):
            #expect(failure.kind == .timeout)
            // The point of the timeout is that the caller is not held for 30 seconds.
            #expect(Date().timeIntervalSince(started) < 10)
        }
    }

    @Test func anHttpCallToAnUndeclaredHostNeverLeavesTheProcess() async throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self, from: Data(#"{ "id": "x", "name": "X" }"#.utf8))
        let result = await runner.run(
            http: "https://example.com/data.json", manifest: manifest, timeout: 5)
        switch result {
        case .success: Issue.record("an undeclared host was reached")
        case .failure(let failure): #expect(failure.kind == .blocked)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginScriptRunnerTests`
Expected: build failure — `cannot find 'PluginScriptRunner' in scope`.

- [ ] **Step 3: Implement**

An `actor`. `bash` → `/bin/zsh -lc`, `applescript` → `/usr/bin/osascript -e`, `jxa` → `/usr/bin/osascript -l JavaScript -e`, `scriptFile` → the file at that path inside the plugin folder, executed directly. Merge `env` over `ProcessInfo.processInfo.environment` — never replace it. Read stdout and stderr on background queues *before* `waitUntilExit()`; reading after it deadlocks on any script that outfills a pipe buffer (64 KB), which a list of a few hundred rows does. Enforce the timeout with a `Task` that calls `process.terminate()`, and map a terminated process to `.timeout` rather than `.exit`.

`shortcut` does not start a process here: the app already runs Shortcuts through
`Services/ShortcutRunner.swift`, and a second path to the same thing is how two behaviours
appear. Call that service and map its result into `PluginRunResult` — read its real signature
first.

`run(http:manifest:timeout:)` is separate because it is gated: parse the URL, ask `PluginPermissions.allowsHost`, return `.blocked` when the answer is no, and only then use `URLSession` with a GET. No test may reach the network; the only http test is the blocked one.

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginScriptRunnerTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/Services/Plugins/PluginScriptRunner.swift Context-DockTests/PluginScriptRunnerTests.swift
git commit -m "feat(plugins): one runner, with a timeout and a gate on the network"
```

---

### Task 6: `PluginRuntime` — data for a host, cached

**Files:**
- Create: `Context-Dock/Services/Plugins/PluginRuntime.swift`
- Test: `Context-DockTests/PluginRuntimeTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `struct PluginDataKey: Hashable` (`pluginID`, `query`, `inputsHash`), `enum PluginDataState { case loading, ready(PluginBinding), failed(PluginDiagnostic) }`, and `@MainActor final class PluginRuntime: ObservableObject` with `func state(for: PluginManifest, host:, inputs:) -> PluginDataState`, `func refresh(_:host:inputs:) async`, and `func run(_ request: PluginActionRequest, manifest:, inputs:) async -> Result<String, PluginRunFailure>`.

The cache is keyed by plugin, query and a hash of the inputs, which is what makes `filter: local` free: typing changes the *query the view filters by*, not the key, so a local-filter list never re-runs its script on a keystroke.

- [ ] **Step 1: Write the failing tests**

```swift
// Context-DockTests/PluginRuntimeTests.swift
import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct PluginRuntimeTests {
    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private let ports = #"""
    { "id": "ports", "name": "Ports",
      "data": { "type": "bash", "script": "echo 'a | 1'", "format": "lines" },
      "views": { "panel": { "list": { "filter": "local", "items": "{{lines}}",
                                      "row": { "title": "{{item.title}}" } } } } }
    """#

    @Test func aPluginWithNoDataIsReadyImmediately() throws {
        let runtime = PluginRuntime()
        let m = try manifest(#"{ "id": "x", "name": "X", "views": { "panel": { "title": "hi" } } }"#)
        guard case .ready = runtime.state(for: m, host: .panel, inputs: PluginInputs()) else {
            Issue.record("a static plugin was not ready")
            return
        }
    }

    @Test func aPluginWithADataScriptStartsLoading() throws {
        let runtime = PluginRuntime()
        guard case .loading = runtime.state(for: try manifest(ports), host: .panel, inputs: PluginInputs())
        else {
            Issue.record("a plugin with a script did not start in loading")
            return
        }
    }

    @Test func runningTheScriptFillsTheBinding() async throws {
        let runtime = PluginRuntime()
        let m = try manifest(ports)
        await runtime.refresh(m, host: .panel, inputs: PluginInputs())
        guard case .ready(let binding) = runtime.state(for: m, host: .panel, inputs: PluginInputs())
        else {
            Issue.record("never became ready")
            return
        }
        #expect(binding.items(.string("{{lines}}")).count == 1)
    }

    @Test func typingDoesNotChangeTheKeyOfALocalFilterList() throws {
        // `filter: local` narrows rows already in hand; re-running the script per keystroke
        // is what made the old custom lists feel slow.
        let m = try manifest(ports)
        let bare = PluginDataKey(manifest: m, query: "", inputs: PluginInputs())
        let typed = PluginDataKey(manifest: m, query: "ssh", inputs: PluginInputs())
        #expect(bare == typed)
    }

    @Test func aQueryListKeysOnTheQuerySoTheScriptRunsAgain() throws {
        let m = try manifest(#"""
        { "id": "q", "name": "Q", "data": { "type": "bash", "script": "echo hi", "format": "lines" },
          "views": { "panel": { "list": { "filter": "query", "items": "{{lines}}" } } } }
        """#)
        #expect(PluginDataKey(manifest: m, query: "", inputs: PluginInputs())
            != PluginDataKey(manifest: m, query: "ssh", inputs: PluginInputs()))
    }

    @Test func aFailingScriptEndsAsADiagnosticNotAnEmptyPanel() async throws {
        let runtime = PluginRuntime()
        let m = try manifest(#"""
        { "id": "bad", "name": "Bad", "data": { "type": "bash", "script": "exit 7", "format": "lines" },
          "views": { "panel": { "list": { "items": "{{lines}}" } } } }
        """#)
        await runtime.refresh(m, host: .panel, inputs: PluginInputs())
        guard case .failed(let diagnostic) = runtime.state(for: m, host: .panel, inputs: PluginInputs())
        else {
            Issue.record("a failing script did not report a diagnostic")
            return
        }
        #expect(diagnostic.severity == .error)
    }

    @Test func anActionThatIsNotDeclaredIsNeverRun() async throws {
        let runtime = PluginRuntime()
        let m = try manifest(ports)
        let result = await runtime.run(
            PluginActionRequest(name: "teleport"), manifest: m, inputs: PluginInputs())
        switch result {
        case .success: Issue.record("an undeclared action ran")
        case .failure(let failure): #expect(failure.kind == .blocked)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRuntimeTests`
Expected: build failure — `cannot find 'PluginRuntime' in scope`.

- [ ] **Step 3: Implement**

`PluginDataKey(manifest:query:inputs:)` takes the query into the key **only** when the manifest's list declares `filter: query` (walk `manifest.allNodes` for a `list` whose `filter` prop is `query`); otherwise the query is dropped, which is what makes local filtering free. `inputsHash` is a hash of the built environment dictionary — the same inputs must produce the same key.

`state(for:host:inputs:)` returns `.ready(PluginBinding(data: manifest.sample))` for a manifest with no `data`, a cached state when one exists, and `.loading` otherwise. `refresh` runs the script through `PluginScriptRunner`, decodes with `PluginOutput`, and stores `.ready` or `.failed`. `run(_:manifest:inputs:)` looks the action up in `manifest.actions`, returns `.blocked` when it is not there, and otherwise runs it — built-in types (`copy`, `paste`, `open`, `reveal`) act through AppKit rather than a process.

`PluginRuntime` also owns the **timer**, because it owns the cache the timer refills:
`startTicking(for:host:budget:)` asks `PluginRefreshPolicy.interval` and, when it gets one,
runs a `Task` that sleeps and calls `refresh` until it is cancelled; `stopTicking(pluginID:)`
cancels it. A host that disappears must stop its own ticker — a timer nobody can see is the
battery complaint `PluginRefreshPolicy.admits` exists to prevent, and the policy cannot enforce
itself. Add a test that a manifest whose panel refresh is `0` starts no ticker at all.

**Approval is not wired in this task.** `PluginPermissions.needsApproval` says whether an action needs it; routing that through `AICapabilityApprovalCenter` is Task 7, so this task leaves a single call site to change rather than scattering the decision.

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRuntimeTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Context-Dock/Services/Plugins/PluginRuntime.swift Context-DockTests/PluginRuntimeTests.swift
git commit -m "feat(plugins): data for a host, cached so typing never re-runs a script"
```

---

### Task 7: the approval gate, and the preview runs for real

**Files:**
- Modify: `Context-Dock/Services/Plugins/PluginRuntime.swift`
- Modify: `Context-Dock/UI/Settings/PluginsSettingsPage.swift`
- Test: `Context-DockTests/PluginRuntimeTests.swift`

**Interfaces:**
- Consumes: `AICapabilityApprovalCenter` (read its real API before writing this — it is the app's one approval surface and this must not become a second one).
- Produces: `PluginRuntime.approvalProvider: (PluginActionRequest, PluginAction, PluginManifest) async -> Bool`, defaulting to a closure that refuses. Tests inject one that records and answers.

A default that **refuses** is the point: if a future caller forgets to install a provider, plugins stop running rather than running unattended.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func anActionAboveReadAsksBeforeItRuns() async throws {
        let runtime = PluginRuntime()
        var asked: [String] = []
        runtime.approvalProvider = { request, _, _ in asked.append(request.name); return true }
        let m = try manifest(#"""
        { "id": "x", "name": "X",
          "actions": { "wipe": { "type": "bash", "script": "echo wiped", "risk": "high" } } }
        """#)
        _ = await runtime.run(PluginActionRequest(name: "wipe"), manifest: m, inputs: PluginInputs())
        #expect(asked == ["wipe"])
    }

    @Test func aReadActionRunsWithoutAsking() async throws {
        let runtime = PluginRuntime()
        var asked = false
        runtime.approvalProvider = { _, _, _ in asked = true; return true }
        let m = try manifest(#"""
        { "id": "x", "name": "X",
          "actions": { "look": { "type": "bash", "script": "echo ok", "risk": "read" } } }
        """#)
        _ = await runtime.run(PluginActionRequest(name: "look"), manifest: m, inputs: PluginInputs())
        #expect(asked == false)
    }

    @Test func aRefusedActionDoesNotRun() async throws {
        let runtime = PluginRuntime()
        runtime.approvalProvider = { _, _, _ in false }
        let m = try manifest(#"""
        { "id": "x", "name": "X",
          "actions": { "wipe": { "type": "bash", "script": "echo wiped", "risk": "high" } } }
        """#)
        switch await runtime.run(PluginActionRequest(name: "wipe"), manifest: m, inputs: PluginInputs()) {
        case .success: Issue.record("a refused action ran anyway")
        case .failure(let failure): #expect(failure.kind == .blocked)
        }
    }

    @Test func withNoProviderInstalledNothingAboveReadRuns() async throws {
        // The default refuses. A caller that forgets to install a provider gets a plugin that
        // does nothing, which is the failure worth having.
        let runtime = PluginRuntime()
        let m = try manifest(#"""
        { "id": "x", "name": "X",
          "actions": { "wipe": { "type": "bash", "script": "echo wiped", "risk": "high" } } }
        """#)
        switch await runtime.run(PluginActionRequest(name: "wipe"), manifest: m, inputs: PluginInputs()) {
        case .success: Issue.record("an unapproved action ran with no provider installed")
        case .failure(let failure): #expect(failure.kind == .blocked)
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRuntimeTests`
Expected: build failure — `value of type 'PluginRuntime' has no member 'approvalProvider'`.

- [ ] **Step 3: Implement**

Add the property, call it in `run` when `PluginPermissions.needsApproval(action)`, and return `.blocked` on a refusal. Then give the Plugins page a **Run** button per previewed plugin that calls `refresh`, so the preview stops being sample data only: a plugin with a data script shows what its script actually prints, and a failing script shows its diagnostic. Install a provider that routes to `AICapabilityApprovalCenter`.

- [ ] **Step 4: Run to verify pass**

Run: `cd <worktree> && pwd && ./scripts/test.sh -only-testing:Context-DockTests/PluginRuntimeTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Build, launch, and look at it**

Run: `cd <worktree> && pwd && ./scripts/dev-run.sh`, open Settings → Extensions → Plugins, pick a migrated Global Command with a script and press Run.

- [ ] **Step 6: Commit**

```bash
git add Context-Dock/Services/Plugins/PluginRuntime.swift Context-Dock/UI/Settings/PluginsSettingsPage.swift Context-DockTests/PluginRuntimeTests.swift
git commit -m "feat(plugins): anything above read asks first, and the preview runs for real"
```

---

## Exit condition

A migrated Global Command with a `provider:custom` list runs through `PluginScriptRunner`, its
output decodes through `PluginOutput`, and the Phase 2 renderer draws the result — proven by
`PluginRuntimeTests` against scripts in the repo, not against the machine's state. Nothing above
`risk: read` runs without an answer from the approval provider, and the default provider refuses.

## Not in this plan

- **`SkillScope` gaining a plugin scope, and `PluginToolset`.** Both are the agent layer rather
  than the runtime, both depend on everything here, and both are independently testable — so
  they are their own plan, written after this one lands.
- Hosts: the dock sheet, corner panel and window surfaces are Phase 4.
- The cut-over that retires Global Commands and Global Extensions is Phase 8. This phase makes
  the migrated manifests *run*; it does not remove the old systems or change what the user's
  existing extensions do today.
