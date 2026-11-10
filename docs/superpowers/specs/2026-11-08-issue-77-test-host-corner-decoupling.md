# Issue #77: Test Host Corner Tests Decoupling (No Synthetic Window or Dock Dependency)

> **Date:** 2026-11-08  
> **Status:** Specification / Revised (EGM Cycle - Iteration 6)  
> **Target Branch:** `claude/issue-77-test-host-corner-decoupling` (bases on `general-chat-agent`)  
> **GitHub Issue:** #77 (Milestone 1.0)  
> **References:**  
> - GitHub Issue #77: "Test host: Corner tests with no synthetic window or dock dependency"  
> - `AGENTS.md` (Unified Dock Surface rule, Build/run/test rules, Test Host single-instance guard)  
> - `docs/master/00-NOW.md`  
> - `docs/master/00-DOCK-AND-CORNER.md` §4, §5  
> - `Context-Dock/App/ILauncherApp.swift` (`AppDelegate.isHostingTests`, `applicationDidFinishLaunching`)  
> - `Context-Dock/App/TestHostAppleEventBlocker.swift`  
> - `Context-Dock/Accessibility/AXObserverManager.swift`  
> - `Context-Dock/UI/CornerDockWindow.swift` (`CornerDockController`, `CornerDockPanel`, `CornerDockLayout`)  
> - `Context-Dock/UI/CornerChatPresentation.swift`  
> - `Context-Dock/UI/AppChatPromptModel.swift`  
> - `Context-Dock/UI/AppChatMenuBrowsing.swift`  
> - `Context-Dock/UI/AppChatSelectionScope.swift` (`FixedRunningAppsSource`)  
> - `Context-Dock/Services/MenuWarmCacheService.swift`  
> - `Context-DockTests/CornerChatPresentationTests.swift`  
> - `Context-DockTests/CornerDockPhaseTests.swift`  

---

## 1. Context & Goals

### 1.1 Problem Statement
In CI workflows and headless test runs, unit and presentation tests in `Context-DockTests/` (specifically `@MainActor` Corner suites such as `CornerChatPresentationTests.theArrowRouteBetweenModesRunsBothWays` and `CornerDockPhaseTests.rightArrowFromDockScopesLikeAnEmptyPromptDoes`) intermittently stall until hitting `swift-testing`'s 120-second timeout ceiling (CI runs 36016229990 and 36018543022).

These stalls manifest as consecutive 120-second freezes on `@MainActor` test cases that execute no shell scripts or external processes.

Investigation reveals the following root causes:
1. **Unchecked Test Host Launch Overhead (`ILauncherApp.swift`)**:
   When `xcodebuild test` starts the test host application (`Context-Dock.app`), `applicationDidFinishLaunching` runs before test execution begins. While `AppDelegate.isHostingTests` stops `ClipboardHistoryEngine`, `GlobalSearchIndexBuilder`, `DockEngine.start()`, and `DetachedPetManager`, it fails to gate numerous UI-heavy, WindowServer-dependent, and system-polling services:
   - `CornerDockController.shared.activate()` previously allocated an `NSPanel` (`CornerDockPanel`), instantiated `CornerDockHostView` hosting SwiftUI views, installed window tracking, and measured against `NSScreen.screens` and `NSEvent.mouseLocation`.
   - `DynamicNotchController.shared.start()` creates and anchors a live notch window panel.
   - `AXObserverManager.shared.startMonitoring()` attaches Accessibility observers via C APIs (`AXObserverCreateWithInfoCallback`) to the frontmost application.
   - `setupFrontmostAppTracking()` queries `NSWorkspace.shared.menuBarOwningApplication` and activates `MenuWarmCacheService.shared.frontmostAppDidChange`.
   - `MenuWarmCacheService.shared.startIdleWarming()` spawns an infinite recurring `Task` on `@MainActor` that calls `warmRecentAppsIfIdle()`, performing deep AX traversals.
   - Global Carbon hotkeys and event monitors (`registerGlobalHotkey`, `registerOutsideMouseMonitor`, `registerDoubleOptionMonitor`, `syncEdgeWatch`, etc.) install Carbon event handlers and Quartz event taps, which can block or fail in headless sessions.
   - Background catalog indexers (`InstalledApplicationsCatalog.warmUp()`, `AppCatalogService.shared.prewarm()`, `UninstalledAppCleanupService.cleanupInBackground()`, `DoraXSpotlightIndexService.shared.scheduleRebuild()`, `SkillFolder.start()`, `BinaryWatcherService.shared.startWatching()`) spin up file monitors and worker threads.
   - `DoraXMCPServer.shared.startIfEnabled()` attempts socket/port bindings that collide with running local instances.
   - `SafariBrowserBridge.shared`, `AIWorkerDiscovery.discoverInstalled()`, and `PluginEssentials.seedIfNeeded()` execute unneeded I/O during test startup.

2. **Corner Presentation & Model Coupling to Live Workspace and WindowServer**:
   - `AppChatPromptModel`: When instantiated in unit tests, `runningAppsSource` defaults to `WorkspaceRunningAppsSource()`, which queries `NSWorkspace.shared.runningApplications` and extracts NSImages from live system processes.
   - `AppChatMenuBrowsing`: In `loadMenuItems()`, when a bundle ID matches any app running on the CI host (e.g. VS Code, Finder, Safari, Terminal), it queries `NSWorkspace.shared.runningApplications`, queries `AppMenuCapabilityCache`, calls `refreshTabs()` which spawns AppleScripts against Safari, and spawns a `@MainActor` task executing `AXMenuReader.shared.liveAXMenuItems(for: pid, maxDepth: 7)` synchronously calling `AXUIElementCopyAttributeValue`. If the app does not respond or lacks TCC automation grants on CI, it hangs or blocks `@MainActor`.
   - `orderedAppPills()`: Hardcodes calls to `WorkspaceRunningAppsSource()`, ignoring mock environments.
   - `CornerDockController`: Strongly requires live `NSScreen` instances in `position()` and invokes `panel.orderFront` / `orderOut`. In headless CI environments where `NSScreen.screens` is empty or the window server is virtualized, geometry calculations and window order calls can stall or produce runtime errors.
   - Combine observation conflation: `CornerDockController.ensurePanel()` previously bundled Combine model sinks together with `CornerDockPanel` creation.

### 1.2 Goals
1. **Total Test Host Launch Decoupling**: Ensure `applicationDidFinishLaunching` in `ILauncherApp.swift` executes a strict, minimal test-host boot sequence when `AppDelegate.isHostingTests == true`. Zero window panels created, zero Carbon hotkeys/event taps registered, zero AX observers attached, zero menu warming loops started, and zero background disk/process daemons spawned.
2. **Headless & Offline Corner Test Harness**: Decouple `CornerDockController`, `CornerChatPresentation`, and `AppChatPromptModel` from live `NSPanel`, WindowServer, `NSWorkspace`, and `AXMenuReader` dependencies while preserving all Combine event flow and model synchronization.
3. **Deterministic Running-Apps & Menu Data**: Ensure `AppChatPromptModel` and `AppChatMenuBrowsing` default to isolated non-empty fixture sources (`FixedRunningAppsSource.defaultTestFixture`, zero live AX menu reads, zero browser URL disk probes, zero AppleScript tab reads) under test hosting, while preserving pre-seeded test menu items.
4. **Resilient Window Geometry Fallback & Layout Unification**: Refactor `CornerDockController.position()` to delegate to a pure, deterministic `calculatePanelOrigin` helper with synthetic fallback when `NSScreen.screens` is empty, preserving 100% of existing clamped offset arithmetic, auto-hide positioning, and movable flags.
5. **Heartbeat-Based Main-Thread Watchdog**: Add a non-blocking, heartbeat-based diagnostic watchdog that detects and reports any `@MainActor` blockage exceeding 10 seconds without deadlocks or background thread blocking.
6. **Zero Impact on Production Runtime**: All changes must preserve 100% of production behavior when `AppDelegate.isHostingTests == false`.

### 1.3 Non-Goals
1. Rewriting the `swift-testing` testing framework or changing the requirement to run tests via `./scripts/test.sh` and `./scripts/check.sh`.
2. Redesigning Corner UI layouts, animations, or styling in production mode.
3. Modifying `TestHostAppleEventBlocker`'s Apple Event swizzling logic (which works as designed).
4. Replacing `DockCore` or altering the unified `DockEngine` orchestration.

---

## 2. Architectural Lane & Layer Alignment

### 2.1 DoraX Architecture Rules (`AGENTS.md`)
- **Corner Parity & Engine Reuse**: Corner App Chat and Global Context remain presentations over `DockEngine`. Decoupling the test harness must not introduce separate mock engine duplicates; rather, the existing components must cleanly support headless, injected inputs.
- **Data Lane vs. UI Lane**:
  - Headless tests belong purely to the Data Lane: testing prompt state machines, arrow key walks, navigation destination logic, phase transitions, and focus changes in memory.
  - No synthetic `NSWindow` or live WindowServer event pump may be required to verify pure model transitions.

### 2.2 Test Host Gate Invariant
`AppDelegate.isHostingTests` is the authoritative discriminator. Update `ILauncherApp.swift:29-32` to encompass all test environments:
```swift
static let isHostingTests: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["XCTestConfigurationFilePath"] != nil 
        || env["XCTestBundlePath"] != nil
        || env["CONTEXT_DOCK_DEFAULTS_SUITE"] != nil
        || env["TEST_RUNNER_CONTEXT_DOCK_DEFAULTS_SUITE"] != nil
        || NSClassFromString("XCTest") != nil
}()
```
When `isHostingTests` is `true`:
- The process is a test host runner.
- It MUST NOT attach to hardware display server features (window ordering, status bar items, Carbon hotkeys, event taps).
- It MUST NOT spawn unmanaged background loops (menu warmers, spotlight indexers, MCP listeners, file monitors).

---

## 3. Data Model, Invariants & Interface Design

### 3.1 Test Host Launch Quarantine (`ILauncherApp.swift`)

In `AppDelegate.applicationDidFinishLaunching`:
Explicitly partition the launch sequence into `configureTestHostEnvironment()` vs `configureProductionEnvironment()`:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    AppDelegate.shared = self

    if Self.isHostingTests {
        configureTestHostEnvironment()
        return
    }

    configureProductionEnvironment()
}
```

#### `configureTestHostEnvironment()` Invariants:
1. **Install Protections & Approvals**:
   - `TestHostAppleEventBlocker.install()` (fails fast on any AppleScript/AppleEvent).
   - `AXMessagingTimeout.installProcessDefault()` (caps any incidental AX call).
   - `PluginCapability.installApprovalProvider()` (routes plugin capabilities through AICapabilityApprovalCenter).
   - `TestHostMainActorWatchdog.install()` (warns on main thread stalls > 10s via non-blocking heartbeat).
2. **Accessory Activation Policy**:
   - `NSApp.setActivationPolicy(.accessory)`
3. **Register Engine & Safe Headless Subscriptions**:
   - `DockEngine.shared.register()` (pure notification routing registration, no active tasks).
   - `CornerDockController.shared.activate()` (activates in headless mode: wires all Combine model sinks without allocating any `NSPanel` or calling WindowServer).
4. **Explicitly Suppressed Services (moved exclusively to `configureProductionEnvironment`)**:
   - NO `DynamicNotchController.shared.start()`
   - NO `AXObserverManager.shared.startMonitoring()`
   - NO `setupFrontmostAppTracking()`
   - NO `MenuWarmCacheService.shared.startIdleWarming()`
   - NO `registerGlobalHotkey()` and Carbon hotkeys (`registerContextDockHotkey`, `registerClipboardScopeHotkey`, `registerQuickNoteHotkey`, `registerAppChatHotkey`, `registerChatWindowHotkey`, `registerCaptureHotkeys`, `registerInspectorHotkey`)
   - NO `registerOutsideMouseMonitor()` / `registerDoubleOptionMonitor()` / `unregisterModifierSideEffectMonitors()`
   - NO `DoraXMCPServer.shared.startIfEnabled()`
   - NO `BrainMaintenance.shared.start()`
   - NO `DoraXSpotlightIndexService.shared.scheduleRebuild()`
   - NO `SkillFolder.start()`
   - NO `BinaryWatcherService.shared.startWatching()`
   - NO `InstalledApplicationsCatalog.warmUp()`
   - NO `AppCatalogService.shared.prewarm()`
   - NO `UninstalledAppCleanupService.cleanupInBackground()`
   - NO `setupMenuBar()` / `setupApplicationMenu()` / `registerServicesProvider()`
   - NO `DistributedNotificationCenter.default().addObserver(...)` for `"com.ilauncher.showWindow"`
   - NO `AIWorkerDiscovery.discoverInstalled()`
   - NO `SafariBrowserBridge.shared`
   - NO `PluginEssentials.seedIfNeeded()`

### 3.2 Decoupling Windowing & Subscriptions in `CornerDockController` (`CornerDockWindow.swift`)

In `CornerDockController`:
1. **Decouple Window Allocation from State Subscriptions with Idempotency Guard**:
   Split `ensurePanel()` into two distinct stages:
   ```swift
   var isHeadless: Bool = AppDelegate.isHostingTests
   private var hasSetupSubscriptions = false

   private func ensurePanel() {
       setupModelSubscriptions()
       guard !isHeadless, panel == nil else { return }
       allocatePanelAndHostView()
   }

   private func setupModelSubscriptions() {
       guard !hasSetupSubscriptions else { return }
       hasSetupSubscriptions = true

       prompt.onStepIntoFile = { [weak self] url in self?.showSelection(forFile: url) ?? false }
       
       // Sinks from lines 188-486 of CornerDockWindow.swift for:
       // - NSWorkspace.activeSpaceDidChangeNotification
       // - ContextDockEnvironment.shared.frontmostAppUpdates
       // - clipboardModel.$phase, $isKeyboardArmed, $isBoardOpen, $recentlyCopied
       // - DynamicNotchState.shared.$isExpanded
       // - prompt.$phase, selection.$phase, chatPresentation.$isVisible, etc.
   }
   ```
   `setupModelSubscriptions()` is idempotent and always runs once, attaching Combine pipelines even when `isHeadless == true`.
   
   `allocatePanelAndHostView()` contains AppKit window creation (`CornerDockPanel`), view hierarchy creation (`CornerDockHostView`, `NSHostingView(rootView: CornerDockSurface())`), and window positioning.

2. **Headless Guard on Edge Watch Event Monitors**:
   In `CornerDockController.syncEdgeWatch()`:
   ```swift
   func syncEdgeWatch() {
       guard !isHeadless else { return }
       ...
   }
   ```
   Ensures zero Quartz event taps (`NSEvent.addGlobalMonitorForEvents`) are installed in headless test mode.

3. **Unified Layout Positioning Calculation (`calculatePanelOrigin`)**:
   Extract panel origin computation into a static, pure, testable helper that preserves the exact production arithmetic from `position()`:
   ```swift
   static func calculatePanelOrigin(
       visibleScreenFrame: CGRect,
       fullScreenFrame: CGRect,
       panelSize: CGSize,
       anchor: CornerDockAnchor,
       isCentred: Bool,
       centredOffsetX: CGFloat = CGFloat(AppSettings.shared.centredLauncherOffsetX),
       centredOffsetY: CGFloat = CGFloat(AppSettings.shared.centredLauncherOffsetY)
   ) -> CGPoint {
       let pad = CornerDockLayout.pad
       let margin: CGFloat = 20

       if isCentred {
           let screenW = fullScreenFrame.width
           let screenX = fullScreenFrame.minX
           let defaultX = (screenW - panelSize.width) / 2 + screenX
           let defaultY = visibleScreenFrame.minY + visibleScreenFrame.height * 0.62 + pad - panelSize.height
           let maxOffsetY = max(0, visibleScreenFrame.maxY - (visibleScreenFrame.minY + visibleScreenFrame.height * 0.62 + pad) - 40)
           let minOffsetY = -(visibleScreenFrame.height * 0.45)
           let clampedOffsetY = min(max(minOffsetY, centredOffsetY), maxOffsetY)
           let clampedOffsetX = min(max(-screenW * 0.4, centredOffsetX), screenW * 0.4)
           return CGPoint(x: defaultX + clampedOffsetX, y: defaultY + clampedOffsetY)
       }

       let x: CGFloat
       switch anchor {
       case .right:
           x = visibleScreenFrame.maxX - margin + pad - panelSize.width
       case .left, .center, .notch:
           x = visibleScreenFrame.minX + margin - pad
       }
       let y = visibleScreenFrame.minY + margin - pad
       return CGPoint(x: x, y: y)
   }
   ```
   Refactor `position()` to delegate to `calculatePanelOrigin` while preserving window movable settings, auto-hide origin branching, and screen frame updates:
   ```swift
   private func position() {
       guard let panel else { return }
       let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
           ?? NSScreen.main
       let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
       let fullScreen = screen?.frame ?? visible
       let pad = CornerDockLayout.pad
       let margin: CGFloat = 20
       let isCentredMode = chatPresentation.isCentred || AppSettings.shared.launcherPresentationMode == .centerScreen

       let wanted = CornerDockLayout.panelSize(for: anchor, panelWidth: visible.width - 2 * margin + 2 * pad)
       if panel.frame.size != wanted {
           panel.setContentSize(wanted)
           hostView?.frame = CGRect(origin: .zero, size: wanted)
       }

       panel.isMovable = isCentredMode
       panel.isMovableByWindowBackground = isCentredMode

       let origin = Self.calculatePanelOrigin(
           visibleScreenFrame: visible,
           fullScreenFrame: fullScreen,
           panelSize: panel.frame.size,
           anchor: anchor,
           isCentred: isCentredMode
       )

       shownPanelOrigin = origin
       dockScreenFrame = fullScreen
       panel.setFrameOrigin(isCentredMode ? shownPanelOrigin : (isAutoHidden ? hiddenPanelOrigin : shownPanelOrigin))
   }
   ```

4. **Window Ordering Guard in `refresh()`**:
   ```swift
   func refresh() {
       guard !isHeadless, let panel, let hostView else { return }
       ...
   }
   ```

### 3.3 Decoupling `AppChatPromptModel` and `AppChatMenuBrowsing`

1. **Running Apps Source Defaulting (`Context-Dock/UI/AppChatSelectionScope.swift`)**:
   Define a deterministic, non-empty test fixture on `FixedRunningAppsSource` in `Context-Dock/UI/AppChatSelectionScope.swift`:
   ```swift
   extension FixedRunningAppsSource {
       static let defaultTestFixture = FixedRunningAppsSource(icons: [
           MatchDockIcon(
               id: "com.apple.finder",
               bundleID: "com.apple.finder",
               title: "Finder",
               icon: NSImage(),
               isRunning: true,
               isExpandable: false,
               score: 0,
               isExactAppPrefix: false
           ),
           MatchDockIcon(
               id: "com.apple.Safari",
               bundleID: "com.apple.Safari",
               title: "Safari",
               icon: NSImage(),
               isRunning: true,
               isExpandable: false,
               score: 0,
               isExactAppPrefix: false
           )
       ])
   }
   ```
   In `AppChatPromptModel.init`:
   ```swift
   self.runningAppsSource = runningAppsSource ?? (
       AppDelegate.isHostingTests 
           ? FixedRunningAppsSource.defaultTestFixture 
           : WorkspaceRunningAppsSource()
   )
   ```
   This ensures tests like `CornerDockPhaseTests.rightArrowFromDockScopesLikeAnEmptyPromptDoes` find a valid running app to scope into from the resting dock, successfully transitioning `model.phase != .dock`.

2. **Instance-Scoped and Static `orderedAppPills()`, `pillIcons()`, and `runningApp(after:)`**:
   Add an instance method on `AppChatPromptModel`:
   ```swift
   func orderedAppPills() -> [MatchDockIcon] {
       Self.orderedAppPills(runningAppsSource: self.runningAppsSource)
   }
   ```
   Update `scopeIntoFirstRunningApp()` and `stepBackThroughRunningApps()`:
   Replace `let apps = Self.orderedAppPills()` with `let apps = self.orderedAppPills()`.

   Update static methods in `AppChatMenuBrowsing.swift`:
   ```swift
   static func orderedAppPills(
       runningAppsSource: RunningAppsSourcing = AppDelegate.isHostingTests 
           ? FixedRunningAppsSource.defaultTestFixture 
           : WorkspaceRunningAppsSource()
   ) -> [MatchDockIcon] {
       pillIcons(runningAppsSource: runningAppsSource).filter { $0.id != clipboardPillID && $0.bundleID != nil }
   }

   static func pillIcons(
       excluding scopedBundleID: String = "",
       runningAppsSource: RunningAppsSourcing = AppDelegate.isHostingTests 
           ? FixedRunningAppsSource.defaultTestFixture 
           : WorkspaceRunningAppsSource()
   ) -> [MatchDockIcon] {
       ...
   }

   static func runningApp(
       after bundleID: String,
       runningAppsSource: RunningAppsSourcing = AppDelegate.isHostingTests 
           ? FixedRunningAppsSource.defaultTestFixture 
           : WorkspaceRunningAppsSource()
   ) -> (name: String, bundleID: String)? {
       let apps = orderedAppPills(runningAppsSource: runningAppsSource)
       guard let idx = apps.firstIndex(where: { $0.bundleID == bundleID }) else {
           return apps.first.flatMap { icon in icon.bundleID.map { (name: icon.title, bundleID: $0) } }
       }
       let next = idx + 1
       guard next < apps.count, let nextID = apps[next].bundleID else { return nil }
       return (name: apps[next].title, bundleID: nextID)
   }
   ```

3. **Deterministic Menu Browsing in Test Host (`loadMenuItems()`)**:
   In `AppChatMenuBrowsing.loadMenuItems()`:
   Keep `updateTabStrip()` and `adapterActions` initialization active across all environments.
   Under test hosting, preserve any pre-seeded `allMenuItems` injected by unit tests (e.g. `CornerRemainingScopesTests`, `CornerAppPinsTests`), and bypass `refreshTabs()` (which queries Safari via AppleScript), live workspace lookups, capability cache queries, browser disk probes, and live AX menu walks:
   ```swift
   func loadMenuItems() {
       updateTabStrip()
       adapterActions = AppAdapterManager.shared.adapter(for: appBundleID)?
           .actions.filter { !$0.name.isEmpty } ?? []

       if AppDelegate.isHostingTests {
           // Retain pre-seeded menu items from tests if present; otherwise keep empty
           updateMenuMatches()
           return
       }

       refreshTabs()

       guard !appBundleID.isEmpty,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == appBundleID && !$0.isTerminated
           })
       else {
           allMenuItems = []
           menuMatches = []
           return
       }

       allMenuItems = AppMenuCapabilityCache.shared.menuItems(for: app, maxResults: 400)
       updateMenuMatches()

       if BrowserTabList.listsTabs(bundleID: appBundleID) {
           BrowserURLLibraryService.shared.refreshIfNeeded { [weak self] in self?.updateMenuMatches() }
       }

       guard !finderSkipsLiveMenus else { return }

       let pid = app.processIdentifier
       let bundleID = appBundleID
       Task { @MainActor [weak self] in
           let live = AXMenuReader.shared.liveAXMenuItems(for: pid, maxDepth: 7)
           ...
       }
   }
   ```

4. **Preserve `FakeAppChatSelectionReader` in `refreshSelectionForCurrentScope()`**:
   In `AppChatPromptModel.refreshSelectionForCurrentScope()`:
   Only guard the live workspace query and AX refresh calls; do NOT early-exit before reading the current context:
   ```swift
   func refreshSelectionForCurrentScope() {
       let ownBundleID = Bundle.main.bundleIdentifier ?? ""
       if !AppDelegate.isHostingTests {
           if isGlobalScope {
               if let app = AppDelegate.shared?.menuBarOwningUserFacingApplication(),
                   app.bundleIdentifier != ownBundleID
               {
                   selectionReader.refreshLightweight(from: app)
                   selectionReader.refreshSelectionOnly(from: app, includeFinderFiles: true)
               }
           } else if !appBundleID.isEmpty,
               let app = NSWorkspace.shared.runningApplications.first(where: {
                   $0.bundleIdentifier == appBundleID && !$0.isTerminated
               })
           {
               selectionReader.refreshLightweight(from: app)
               selectionReader.refreshSelectionOnly(from: app, includeFinderFiles: true)
           }
       }
       
       let context = selectionReader.current
       let scopedTo =
           isGlobalScope
           ? (context.bundleId == ownBundleID ? "" : context.bundleId)
           : appBundleID
       applySelection(from: context, scopedTo: scopedTo)
   }
   ```
   This guarantees that `FakeAppChatSelectionReader` context passes into `applySelection` during tests.

### 3.4 Menu Warming & AX Hard Gates

Add upfront guards on all entry points in `MenuWarmCacheService.swift`:
```swift
func frontmostAppDidChange(_ app: NSRunningApplication) {
    guard !AppDelegate.isHostingTests else { return }
    ...
}

func appDidLaunch(_ app: NSRunningApplication) {
    guard !AppDelegate.isHostingTests else { return }
    ...
}

func startIdleWarming() {
    guard !AppDelegate.isHostingTests else { return }
    ...
}

func warmRecentAppsOnLauncherOpen() {
    guard !AppDelegate.isHostingTests else { return }
    ...
}

func warmRunningAppsOnLauncherOpen(_ apps: [NSRunningApplication], maxApps: Int = 6) {
    guard !AppDelegate.isHostingTests else { return }
    ...
}

func warmStatusMenuAppsOnLauncherOpen(force: Bool = false) async -> Bool {
    guard !AppDelegate.isHostingTests else { return false }
    ...
}

func warm(app: NSRunningApplication, force: Bool) async {
    guard !AppDelegate.isHostingTests else { return }
    ...
}
```
Expose internal test inspection:
```swift
#if DEBUG
var isWarmingActive: Bool { warmTask != nil || idleWarmTask != nil }
#endif
```

And in `AXObserverManager.swift`:
```swift
func startMonitoring() {
    guard !AppDelegate.isHostingTests else { return }
    ...
}

#if DEBUG
var activeObserverCount: Int { pool.count }
#endif
```

### 3.5 Heartbeat-Based Main-Actor Diagnostic Watchdog (`TestHostMainActorWatchdog.swift`)

A non-blocking, Sendable watchdog using `NSLock` that schedules periodic MainActor heartbeats, logs stalls upon state transition without spamming, and does not block background or main queues:
```swift
import Foundation

final class TestHostMainActorWatchdog: @unchecked Sendable {
    static let shared = TestHostMainActorWatchdog()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.ilauncher.test-watchdog", qos: .userInitiated)
    private let lock = NSLock()
    private var lastHeartbeatTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var _isMainActorStalled = false
    private var pingPending = false
    private var hasLoggedStall = false
    
    var isMainActorStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isMainActorStalled
    }
    
    static func install(timeoutSeconds: TimeInterval = 10.0) {
        #if DEBUG
        guard AppDelegate.isHostingTests else { return }
        shared.start(timeoutSeconds: timeoutSeconds)
        #endif
    }
    
    static func stop() {
        #if DEBUG
        shared.timer?.cancel()
        shared.timer = nil
        shared.lock.lock()
        shared._isMainActorStalled = false
        shared.pingPending = false
        shared.hasLoggedStall = false
        shared.lock.unlock()
        #endif
    }
    
    private func start(timeoutSeconds: TimeInterval) {
        stop()
        lock.lock()
        lastHeartbeatTime = CFAbsoluteTimeGetCurrent()
        _isMainActorStalled = false
        pingPending = false
        hasLoggedStall = false
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            
            self.lock.lock()
            let elapsed = CFAbsoluteTimeGetCurrent() - self.lastHeartbeatTime
            if elapsed > timeoutSeconds {
                self._isMainActorStalled = true
                if !self.hasLoggedStall {
                    self.hasLoggedStall = true
                    let warning = "⚠️ [TestHostWatchdog] MainActor blocked for \(String(format: "%.1f", elapsed))s! Potential deadlock or synchronous AX scan in test host."
                    fputs(warning + "\n", stderr)
                }
            } else {
                self._isMainActorStalled = false
                self.hasLoggedStall = false
            }
            
            let shouldSchedulePing = !self.pingPending
            if shouldSchedulePing {
                self.pingPending = true
            }
            self.lock.unlock()
            
            guard shouldSchedulePing else { return }
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.lastHeartbeatTime = CFAbsoluteTimeGetCurrent()
                self._isMainActorStalled = false
                self.pingPending = false
                self.hasLoggedStall = false
                self.lock.unlock()
            }
        }
        self.timer = timer
        timer.resume()
    }
}
```

---

## 4. Failure Modes & Error Handling

1. **Test Runner Environment Variations**:
   - `xcodebuild test` vs SPM vs Xcode IDE: `AppDelegate.isHostingTests` checks multiple environment indicators (`XCTestConfigurationFilePath`, `XCTestBundlePath`, `CONTEXT_DOCK_DEFAULTS_SUITE`, `TEST_RUNNER_CONTEXT_DOCK_DEFAULTS_SUITE`, and `NSClassFromString("XCTest")`).
2. **Headless CI Displays**:
   - On GitHub Actions macOS runners without an attached hardware display, `NSScreen.screens` may be empty. The synthetic screen frame fallback (`CGRect(x: 0, y: 0, width: 1512, height: 982)`) ensures layouts compute deterministically without nil unwraps or zero-division errors.
3. **Test State Pollution**:
   - Running tests sequentially could pollute singleton state (`CornerChatPresentation.shared`, `AppChatConversation.shared`).
   - Every Corner test must instantiate its own isolated models (`CornerChatPresentation(appChat: ...)`), and `AppDelegate.configureTestHostEnvironment()` ensures no persistent observers keep strong references to test instances.
4. **Accidental Production Invocations**:
   - In production builds (`isHostingTests == false`), `configureProductionEnvironment()` runs completely unaltered, ensuring zero regressions to hotkeys, dock activation, menu warming, or notch controllers.

---

## 5. Acceptance Criteria & Offline Tests

### 5.1 Acceptance Criteria
1. **Zero Main-Thread Test Host Stalls**:
   - `CornerChatPresentationTests` and `CornerDockPhaseTests` execute completely in under 2 seconds total, with zero 120s stalls on CI or local runs.
2. **Clean Test Host Launch**:
   - Launching the test host (`./scripts/test.sh`) registers zero Carbon hotkeys, opens zero `NSPanel` windows, starts zero background AX loops, registers zero Quartz edge watch monitors, and binds zero network sockets.
3. **Headless Execution Verification**:
   - All tests in `Context-DockTests/Corner*` pass with 100% success when run in a headless environment without an active window server or accessibility grants.
4. **Gate Integrity**:
   - `AppDelegate.isHostingTests` is true during test execution, and `TestHostAppleEventBlockerTests.theTestHostKnowsItIsOne` continues to pass.
5. **Lint and Build Gate**:
   - `./scripts/check.sh` passes with zero compiler errors or warnings.

### 5.2 Machine-Verifiable Offline Tests
1. **`TestHostQuarantineTests.swift`**:
   - Assert `CornerDockController.shared.window == nil` in test host.
   - Assert `CornerDockController.shared.isHeadless == true` in test host.
   - Assert `MenuWarmCacheService.shared.isWarmingActive == false`.
   - Assert `AXObserverManager.shared.activeObserverCount == 0`.
   - Assert `TestHostMainActorWatchdog.shared.isMainActorStalled == false`.
2. **`CornerHeadlessExecutionTests.swift`**:
   - Execute `theArrowRouteBetweenModesRunsBothWays` and assert execution duration is < 100ms.
   - Execute `rightArrowFromDockScopesLikeAnEmptyPromptDoes` and assert execution duration is < 100ms.
   - Assert `AppChatPromptModel` initializes with `FixedRunningAppsSource.defaultTestFixture` and produces zero live AX requests.
   - Assert `CornerDockLayout.panelSize(for: .center, panelWidth: 1512)` computes deterministic valid `CGSize`.
   - Assert `CornerDockController.calculatePanelOrigin(visibleScreenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), fullScreenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), panelSize: CGSize(width: 400, height: 200), anchor: .center, isCentred: false)` computes deterministic origin matching expected coordinates without crashing when `NSScreen.screens` is empty.
