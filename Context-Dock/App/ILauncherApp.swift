//
//  ILauncherApp.swift
//  ILauncher
//
//  Created by Krishgokul on 20/11/2025.
//

import AppKit
import Carbon
import SwiftUI


@main
struct ILauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings scene - this handles the Cmd+, shortcut automatically
        Settings {
            SettingsView()
        }
        .defaultSize(width: 920, height: 680)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// True when this process is the host XCTest loaded the test bundle into, not the app a
    /// person launched.
    static let isHostingTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }()


    /// Global shared reference — safe to use from anywhere without NSApp.delegate cast.
    /// (The @NSApplicationDelegateAdaptor pattern can make NSApp.delegate as? AppDelegate fail.)
    static weak var shared: AppDelegate?

    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem?
    var eventMonitor: Any?
    var localEventMonitor: Any?
    var outsideMouseMonitor: Any?
    var lastOutsideMouseDownAt: TimeInterval = 0
    /// A single system wake fires both `didWakeFromSleep` and `screensDidWake`. Recovery
    /// tears down and reinstalls every monitor, so running it twice in a row would drop
    /// the events arriving in between.
    private var lastWakeRecoveryAt: TimeInterval = 0
    var hotKeyRef: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var contextDockHotKeyRef: EventHotKeyRef?
    var contextDockEventHandlerRef: EventHandlerRef?   // stored so re-register removes old handler
    var clipboardScopeHotKeyRef: EventHotKeyRef?
    var chatWindowHotKeyRef: EventHotKeyRef?
    var chatWindowEventHandlerRef: EventHandlerRef?
    var clipboardScopeEventHandlerRef: EventHandlerRef? // stored so re-register removes old handler
    var appChatHotKeyRef: EventHotKeyRef?
    var appChatEventHandlerRef: EventHandlerRef?
    var quickNoteHotKeyRef: EventHotKeyRef?
    var quickNoteEventHandlerRef: EventHandlerRef?
    var captureTextHotKeyRef: EventHotKeyRef?
    var captureAreaHotKeyRef: EventHotKeyRef?
    var captureScreenshotHotKeyRef: EventHotKeyRef?
    var selectionScopeHotKeyRef: EventHotKeyRef?
    var globalContextHotKeyRef: EventHotKeyRef?
    var captureHotkeyEventHandlerRef: EventHandlerRef?
    #if DEBUG
    var inspectorHotKeyRef: EventHotKeyRef?
    var inspectorEventHandlerRef: EventHandlerRef?
    #endif
    var lastHotkeyFiredAt: TimeInterval = 0
    /// While in the future, a global-context app launch is morphing into that app's Context
    /// Dock — result-execution hides are skipped so the dock stays instead of hide+relaunch.
    var suppressResultHideUntil: Date = .distantPast

    func holdDockThroughAppLaunch(seconds: TimeInterval = 1.5) {
        suppressResultHideUntil = Date().addingTimeInterval(seconds)
    }

    /// Quitting an app transfers macOS focus before the process has fully exited; the
    /// hold lets the user quit several apps from the same result list.
    func holdDockForGlobalQuitBatch(seconds: TimeInterval = 10) {
        suppressResultHideUntil = Date().addingTimeInterval(seconds)
    }
    var doubleOptionMonitor: Any?
    var doubleOptionLocalMonitor: Any?
    var lastOptionPressTime: TimeInterval = 0
    var optionTapContaminated = false
    // Single Option-press focus: bring our search field to front without a hotkey
    var singleOptionFocusMonitor: Any?
    var singleOptionLocalFocusMonitor: Any?
    var singleOptionCancelMonitor: Any?
    var singleOptionLocalCancelMonitor: Any?
    // Single Command-press focus: switch the visible dock to Global Context.
    var singleCommandFocusMonitor: Any?
    var singleCommandLocalFocusMonitor: Any?
    var singleCommandCancelMonitor: Any?
    var singleCommandLocalCancelMonitor: Any?
    var commandAloneActive: Bool = false
    let settings = AppSettings.shared

    // Store the previously frontmost app for context detection
    var previousFrontmostApp: NSRunningApplication?

    // Recent app history — last 5 apps the user was in (excluding ILauncher)
    private(set) var recentApps: [NSRunningApplication] = []
    private let maxRecentApps = 5

    /// Record an app as the current frontmost — updates both previousFrontmostApp and recentApps.
    /// Replaces recentApps with the authoritative list from the Apple menu "Recent Items".
    /// Called after liveMenuItems loads so the NL cross-app handler uses accurate data.
    func setRecentAppsFromMenu(_ apps: [NSRunningApplication]) {
        recentApps = apps.filter { !$0.isTerminated }
    }

    func removeRecentApp(_ app: NSRunningApplication) {
        let bundleID = app.bundleIdentifier
        recentApps.removeAll {
            $0.isTerminated
                || $0.processIdentifier == app.processIdentifier
                || (!(bundleID ?? "").isEmpty && $0.bundleIdentifier == bundleID)
        }
    }

    func recordFrontmostApp(_ app: NSRunningApplication) {
        previousFrontmostApp = app
        // Deduplicate by PID, purge terminated apps, keep newest at front
        recentApps.removeAll { $0.processIdentifier == app.processIdentifier || $0.isTerminated }
        recentApps.insert(app, at: 0)
        if recentApps.count > maxRecentApps { recentApps = Array(recentApps.prefix(maxRecentApps)) }
        // Evict stale structural menu cache for apps that restart or switch away
        // (keeps the cache warm for apps that stay alive between dock opens)
    }

    /// The app macOS shows in the MENU BAR — the true frontmost owner, and the signal to trust.
    /// Our dock runs as an .accessory app (no menu bar of its own), so this stays correct even
    /// while our floating panel holds key focus, where frontmostApplication instead reports US.
    /// That mismatch is what made the dock scope to a stale app and mis-detect quits.
    func menuBarOwningUserFacingApplication() -> NSRunningApplication? {
        resolvedUserFacingApplication(NSWorkspace.shared.menuBarOwningApplication)
            ?? resolvedUserFacingApplication(NSWorkspace.shared.frontmostApplication)
    }

    /// Chooses a corner App Chat target without ever falling back to Context-Dock itself.
    /// The panel may already be key when a repeated hotkey arrives, so the remembered
    /// external app outranks the raw frontmost process.
    static func appChatTargetApplication(
        menuBarOwner: NSRunningApplication?,
        remembered: NSRunningApplication?,
        rawFrontmost: NSRunningApplication?,
        ownBundleID: String
    ) -> NSRunningApplication? {
        [menuBarOwner, remembered, rawFrontmost]
            .compactMap { $0 }
            .first {
                !$0.isTerminated
                    && !($0.bundleIdentifier ?? "").isEmpty
                    && $0.bundleIdentifier != ownBundleID
            }
    }

    private func resolvedUserFacingApplication(_ app: NSRunningApplication?) -> NSRunningApplication? {
        guard let app, !app.isTerminated else { return nil }
        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty, bundleID != ownBundleID {
            return app
        }

        // Some apps, notably ChatGPT, can briefly report a helper process as frontmost.
        // The helper has no bundle identifier, but its executable lives inside the real .app.
        if let bundleURL = app.bundleURL,
            let resolved = runningApplication(forAppBundleURL: bundleURL, excluding: ownBundleID)
        {
            return resolved
        }
        if let executableURL = app.executableURL,
            let appBundleURL = enclosingAppBundleURL(for: executableURL),
            let resolved = runningApplication(forAppBundleURL: appBundleURL, excluding: ownBundleID)
        {
            return resolved
        }

        return nil
    }

    private func enclosingAppBundleURL(for url: URL) -> URL? {
        var current = url
        while current.path != "/" {
            if current.pathExtension == "app" { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private func runningApplication(forAppBundleURL appURL: URL, excluding ownBundleID: String) -> NSRunningApplication? {
        guard
            let bundle = Bundle(url: appURL),
            let bundleID = bundle.bundleIdentifier,
            !bundleID.isEmpty,
            bundleID != ownBundleID
        else { return nil }

        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self  // Register global reference
        // Before anything else can send one: in the test host every Apple Event fails fast
        // instead of waiting 120 s for an Automation prompt nobody answers.
        if Self.isHostingTests { TestHostAppleEventBlocker.install() }
        // The agent-facing server, only if the user turned it on. Started here rather than
        // lazily: an agent's first tool call must not be the thing that starts the server,
        // or that call fails and the agent concludes the capability does not exist.
        DoraXMCPServer.shared.startIfEnabled()
        // Before any accessibility read happens: cap how long one may block. An app that
        // is slow to answer (Terminal while launching or streaming output is the usual
        // one) otherwise stalls every reader for seconds, and the ones on the main thread
        // take the whole dock down with them.
        AXMessagingTimeout.installProcessDefault()
        // Plugin actions ask before they run. Installed here, once, because PluginRuntime's
        // default provider REFUSES: a surface that forgot to install one would get a plugin
        // whose buttons quietly do nothing, and "nothing happened" is the hardest bug to
        // report. Routing through AICapabilityApprovalCenter keeps one approval surface.
        PluginCapability.installApprovalProvider()
        // The plugins the app ships, written onto disk where every other plugin lives so they
        // can be read and edited by hand. Never overwrites an edited one.
        PluginEssentials.seedIfNeeded()
        // Which apps exist on this Mac, read once in the background. Nothing owned this
        // before, so the catalog was built by whichever feature happened to touch an app
        // first — and General Chat, asked about an app on an empty desktop, resolved
        // against an empty list.
        InstalledApplicationsCatalog.warmUp()
        // Keeps the derived half of memory current: today's brief, and yesterday's finished
        // off now that yesterday is over. Reads receipts already on disk and calls no
        // model, so it is free enough to sit on a timer.
        BrainMaintenance.shared.start()
        // Enforce single instance — if another copy is already running, tell it to show and quit
        //
        // Except under XCTest. The test bundle is loaded into a second copy of this app, and
        // the developer's own copy is nearly always running while they work — so the runner
        // launched, saw a duplicate, terminated itself, and every test failed with "exited
        // before establishing connection". That is why this project believed it could not
        // have automated tests: it could, the host was quitting before they started.
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty, !Self.isHostingTests {
            // Notify the existing instance to show its window
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.ilauncher.showWindow"), object: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        // Listen for "show" requests from duplicate launches
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowWindowRequest),
            name: .init("com.ilauncher.showWindow"), object: nil)

        // Hide the app from the Dock
        NSApp.setActivationPolicy(.accessory)

        // Register Services Provider for macOS Services menu integration
        registerServicesProvider()

        // Setup application menu (even if menu bar icon is hidden, this enables Cmd+, shortcut)
        setupApplicationMenu()

        // Setup menu bar icon
        setupMenuBar()

        // Check accessibility permissions
        checkAccessibilityPermissions()

        // Restore access to saved search directories (security-scoped bookmarks)
        restoreSearchDirectoryAccess()

        // Build the installed-app catalog in the background now, so the launcher
        // shows the full app list the instant it first opens.
        AppCatalogService.shared.prewarm()

        // Purge cached data (menus, adapters) for apps no longer installed.
        UninstalledAppCleanupService.cleanupInBackground()

        // Instantiate the Safari bridge now — its Darwin observers only exist once
        // the singleton is created, and the extension can fire before any UI does.
        _ = SafariBrowserBridge.shared

        // The clipboard history records every copy from launch, whatever is on screen. Not
        // in the test host: it would write the developer's own history file.
        if !Self.isHostingTests { ClipboardHistoryEngine.shared.start() }
        // Global search's index builds itself and stays fresh, whatever is on screen.
        if !Self.isHostingTests { GlobalSearchIndexBuilder.shared.start() }

        // The engine the Corner's search and App Chat run on, window or not (#257 E2).
        DockEngine.shared.register()
        if !Self.isHostingTests { DockEngine.shared.start() }

        // No launcher window: the engine runs without one, and the Corner is the launcher
        // (#257 E3).

        // Register global hotkeys
        registerGlobalHotkey()
        registerContextDockHotkey()
        registerClipboardScopeHotkey()
        registerQuickNoteHotkey()
        registerAppChatHotkey()
        registerChatWindowHotkey()
        registerCaptureHotkeys()
        #if DEBUG
        registerInspectorHotkey()
        #endif
        // Which coding agents are installed, resolved once here rather than when somebody
        // asks. The alternative is a filesystem probe on the path that answers while the user
        // is still typing, which is how a launcher stops feeling like one.
        Task.detached(priority: .utility) {
            let workers = AIWorkerDiscovery.discoverInstalled()
            await MainActor.run { AIWorkerRegistry.shared.replaceInstalled(workers) }
        }
        registerOutsideMouseMonitor()
        unregisterModifierSideEffectMonitors()
        registerDoubleOptionMonitor()

        // Setup notification observers for settings changes
        setupNotificationObservers()

        // Track frontmost app changes to capture context BEFORE ILauncher activates
        setupFrontmostAppTracking()
        MenuWarmCacheService.shared.startIdleWarming()
        DoraXSpotlightIndexService.shared.scheduleRebuild(reason: "launch")
        // Skills the user can edit as files, plus DoraX's own description of each surface.
        // Seeded once, watched thereafter, so an edit lands without a relaunch.
        SkillFolder.start()

        // Start event-driven AX observer pipeline
        AXObserverManager.shared.startMonitoring()

        // Beta updater: check manifest in the background after launch.
        // Skipped in Debug — the updater touches /Applications to replace the
        // app, which triggers a per-launch App Management (TCC) prompt while
        // iterating on local Debug builds.
        #if !DEBUG
            AppUpdateService.shared.runLaunchAutoCheckIfNeeded()
        #endif

        // Start binary watcher so L2 auto-discovers newly installed CLI tools
        Task { @MainActor in
            BinaryWatcherService.shared.startWatching()
            #if DEBUG
            print("✅ [AppDelegate] Binary watcher started")
            #endif

            // Scan once after packages have loaded to catch tools installed while app was closed.
            // skipHelpScan=true avoids spawning 100+ --help subprocesses at startup.
            // Help text is fetched lazily when the user taps "Add to L2".
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s
            await BinaryWatcherService.shared.scanNow(skipHelpScan: true)
            // Unlink guessed CLI links the user allowed but never used. One wrong Allow
            // used to tax every prompt for that app forever.
            CLILinkTrustStore.shared.sweepExpiredLinks()
            #if DEBUG
            print("✅ [AppDelegate] Startup scan complete")
            #endif
        }
    }

    func registerServicesProvider() {
        // Register the services provider with NSApp
        // This allows shortcuts to appear in the Services menu of all apps
        NSApp.servicesProvider = ServicesProvider.shared
        #if DEBUG
        print("✅ [Services] Registered ServicesProvider")
        #endif
    }

    func restoreSearchDirectoryAccess() {
        // Start accessing all saved search directories using their security-scoped bookmarks
        // This allows the app to access folders without prompting the user again
        settings.startAccessingSearchDirectories()
        #if DEBUG
        print("📁 Restored access to \(settings.searchDirectories.count) search directories")
        #endif
    }

    func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMenuBarIconVisibilityChanged),
            name: .menuBarIconVisibilityChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyChanged),
            name: .hotkeyChanged,
            object: nil
        )

        // Safari toolbar button — open Context Dock scoped to the frontmost browser
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBrowserActivateDockRequest),
            name: .browserActivateDockRequested,
            object: nil
        )

        // Observe Services notifications to show launcher
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleServicesOpenWithFiles),
            name: .servicesOpenWithFiles,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleServicesOpenWithText),
            name: .servicesOpenWithText,
            object: nil
        )

        // Observe window close events to restore app to accessory mode
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // Re-register hotkeys on wake — Carbon hotkeys are invalidated after sleep.
        //
        // Both notifications, because neither one covers every wake on its own. The Mac can
        // wake with the display left off (Power Nap, wake for network, clamshell), and that
        // fires `didWake` with no `screensDidWake` — the hotkeys are dead and the user finds
        // out by pressing them. Screen wake alone is the more common case and arrives first.
        // The handler debounces the overlap.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWakeFromSleep),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWakeFromSleep),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Track every app activation so recentApps stays current
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    @objc private func handleAppActivation(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }

        // A capture UI taking the screen — ours via /usr/sbin/screencapture, or the system
        // Screenshot app on ⌘⇧4/⌘⇧5 — is not an app the user switched to.
        if Self.isScreenCaptureUI(app) { return }

        guard let resolvedApp = resolvedUserFacingApplication(app) else { return }
        recordFrontmostApp(resolvedApp)
        // Menu cache is validated by bundleVersion inside AXMenuEnumerator — no manual invalidation needed.
    }

    /// The system Screenshot agent, or the `screencapture` tool we spawn ourselves.
    static func isScreenCaptureUI(_ app: NSRunningApplication) -> Bool {
        if let bundleId = app.bundleIdentifier?.lowercased() {
            if bundleId.hasPrefix("com.apple.screencapture") || bundleId == "com.apple.screenshot" {
                return true
            }
        }
        let executable = app.executableURL?.lastPathComponent.lowercased()
        return executable == "screencapture" || executable == "screencaptureui"
    }

    @objc private func handleAppLaunch(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        MenuWarmCacheService.shared.appDidLaunch(app)
    }

    @objc func handleBrowserActivateDockRequest(_ notification: Notification) {
        // Safari is frontmost when the toolbar button is clicked, so the dock
        // opens already scoped to the page the user was reading.
        activateContextDock()
    }

    @objc func handleServicesOpenWithFiles(_ notification: Notification) {
        #if DEBUG
        print("🔧 [AppDelegate] Received servicesOpenWithFiles notification")
        #endif
        // The files' Selection card in the centred Corner, not the old launcher (owner
        // 2026-10-12: the old UI must not show any more).
        let urls = notification.userInfo?["urls"] as? [URL] ?? []
        CornerDockController.shared.showCentredSelection(files: urls, text: nil)
    }

    @objc func handleServicesOpenWithText(_ notification: Notification) {
        #if DEBUG
        print("🔧 [AppDelegate] Received servicesOpenWithText notification")
        #endif
        let text = notification.userInfo?["text"] as? String
        CornerDockController.shared.showCentredSelection(files: [], text: text)
    }

    @objc func handleWindowWillClose(_ notification: Notification) {
        // Check if this is the settings window closing
        if let window = notification.object as? NSWindow {
            if window.title.contains("Settings") || window.title.contains("Preferences") {
                // Restore app to accessory mode (hide from dock)
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc func handleSystemWakeFromSleep() {
        // Two notifications point here for one wake. Collapse them.
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastWakeRecoveryAt > 2 else { return }
        lastWakeRecoveryAt = now

        // Re-register hotkeys after wake — Carbon hotkeys are invalidated during sleep.
        // Register methods clean up old handlers automatically, so just re-register all.
        registerGlobalHotkey()
        registerContextDockHotkey()
        registerClipboardScopeHotkey()
        registerQuickNoteHotkey()
        registerAppChatHotkey()
        registerChatWindowHotkey()
        registerCaptureHotkeys()

        // The Carbon refs above are not how the launcher is actually opened — double-tap
        // Option is, and that runs on NSEvent global monitors. A monitor that stops
        // delivering after wake takes the primary way in with it, and the Carbon
        // re-registration above would have masked the problem as "hotkeys work fine".
        // Reinstalling is idempotent: each of these removes its old monitor first.
        registerOutsideMouseMonitor()
        unregisterModifierSideEffectMonitors()
        registerDoubleOptionMonitor()
    }

    func setupApplicationMenu() {
        // Setup main menu bar to enable keyboard shortcuts even when status bar icon is hidden
        let mainMenu = NSMenu()

        // App menu (ILauncher menu)
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        appMenu.addItem(NSMenuItem(title: "About ILauncher", action: nil, keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "General Chat", action: #selector(showGeneralChatWindow),
                keyEquivalent: "n"))
        appMenu.addItem(
            NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Hide ILauncher", action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            NSMenuItem(title: "Quit ILauncher", action: #selector(quitApp), keyEquivalent: "q"))

        mainMenu.addItem(appMenuItem)

        // Edit menu (enables Copy, Paste, Cut, Select All in text fields)
        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(
            NSMenuItem(
                title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func handleShowWindowRequest() {
        DispatchQueue.main.async { CornerDockController.shared.showCentred() }
    }

    @objc func handleMenuBarIconVisibilityChanged() {
        if settings.showMenuBarIcon {
            if statusItem == nil {
                setupMenuBar()
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    @objc func handleHotkeyChanged() {
        unregisterGlobalHotkey()
        registerGlobalHotkey()
        registerContextDockHotkey()
        registerClipboardScopeHotkey()
        registerQuickNoteHotkey()
        registerAppChatHotkey()
        registerChatWindowHotkey()
        registerCaptureHotkeys()
        unregisterModifierSideEffectMonitors()
        registerDoubleOptionMonitor()
    }

    func setupMenuBar() {
        // Only setup if showMenuBarIcon is true
        guard settings.showMenuBarIcon else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = menuBarLogoImage()
                ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Context-Dock")
        }

        let menu = NSMenu()

        menu.addItem(
            NSMenuItem(
                title: "Show Launcher (⌥⌥)",
                action: #selector(showCornerFromMenu), keyEquivalent: ""))
        menu.addItem(
            NSMenuItem(
                title: "General Chat",
                action: #selector(showGeneralChatWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Quit ILauncher", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    /// Loads DoraXD, strips the black background by mapping luminance → alpha,
    /// forces RGB to white, then sets isTemplate so macOS tints it correctly for
    /// any menubar style (dark/light/coloured).
    private func menuBarLogoImage() -> NSImage? {
        guard let source = NSImage(named: "DoraXD"),
              let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let ci = CIImage(cgImage: cgSource)

        // CIColorMatrix: output = dot(inputRGBA, xVector) + bias
        // → RGB forced to 1 (white), alpha = luminance of original pixel
        guard let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0), forKey: "inputAVector")
        filter.setValue(CIVector(x: 1, y: 1, z: 1, w: 0), forKey: "inputBiasVector")

        guard let output = filter.outputImage else { return nil }

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgOut = ctx.createCGImage(output, from: output.extent) else { return nil }

        let size = NSSize(width: 18, height: 18)
        let result = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            let img = NSImage(cgImage: cgOut, size: size)
            img.draw(in: rect)
            return true
        }
        result.isTemplate = true
        return result
    }

    @objc func showCornerFromMenu() {
        CornerDockController.shared.showCentred()
    }

    /// Menu items land here. Choosing "General Chat" from a menu means bring it up — never
    /// "and put it away if it is already there", which is what a toggle would do to someone
    /// who just picked it out of a list.
    @objc func showGeneralChatWindow() {
        GeneralChatWindowController.shared.show()
    }

    /// The hotkey lands here instead: press once to open, press again to dismiss.
    @objc func toggleGeneralChatWindow() {
        GeneralChatWindowController.shared.toggle()
    }

    @objc func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        // Sized to fit the sidebar plus a page that may itself be a master-detail
        // (Commands/CLI). Resizable with a floor so the nested panes never clip.
        let initialW: CGFloat = 1180
        let initialH: CGFloat = 760
        // Center on the screen the user is actually looking at (cursor's screen),
        // not NSScreen.main — which on multi-display setups can be a side display,
        // throwing the window into a corner.
        let activeScreen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let screenFrame =
            activeScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: (screenFrame.midX - initialW / 2).rounded(),
            y: (screenFrame.midY - initialH / 2).rounded(),
            width: initialW,
            height: initialH
        )

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Context-Dock Settings"
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isOpaque = true
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1040, height: 680)
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        settingsWindow = window
        installSettingsSidebarToggle(in: window)
        // Explicit centered frame already set — don't call center() (it nudges
        // upward and re-resolves the screen, reintroducing the corner bug).
        window.setFrame(frame, display: false)
        window.makeKeyAndOrderFront(nil)
    }

    /// Native sidebar-toggle button in the titlebar, leading edge (after the
    /// traffic lights) — the standard macOS position, instead of a button
    /// floating over the content.
    private func installSettingsSidebarToggle(in window: NSWindow) {
        let button = NSButton(
            image: NSImage(
                systemSymbolName: "sidebar.left",
                accessibilityDescription: "Toggle Sidebar") ?? NSImage(),
            target: self,
            action: #selector(toggleSettingsSidebar)
        )
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Toggle Sidebar"
        button.setButtonType(.momentaryChange)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: 28))
        button.frame = NSRect(x: 6, y: 2, width: 28, height: 24)
        container.addSubview(button)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func toggleSettingsSidebar() {
        SettingsChromeState.shared.toggleSidebar()
    }


    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func checkAccessibilityPermissions() {
        let accessEnabled = AXIsProcessTrusted()

        #if DEBUG
        // Do not show Apple's trust prompt on every Debug launch. Ad-hoc Xcode
        // builds change cdhash often, so macOS can report "not trusted" even
        // when the previous build is already enabled in System Settings.
        print(accessEnabled ? "✅ Accessibility permissions already granted" : "⚠️ Accessibility permissions not granted")
        #endif
    }

    func showPermissionsAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permissions Required"
        alert.informativeText = """
            ILauncher needs Accessibility permissions to detect the Option+Space hotkey globally.

            To grant permissions:
            1. Open System Settings
            2. Go to Privacy & Security → Accessibility
            3. Enable ILauncher
            4. Restart the app

            Click "Open System Settings" to go there now.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Remind Me Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Settings to Accessibility
            if let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            {
                NSWorkspace.shared.open(url)
            }
        }
    }







    func applicationDidResignActive(_ notification: Notification) {
        // Do not hide on Space/full-screen switches. `windowDidResignKey` handles real outside clicks.
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
        }
        restoreAccessoryPolicyIfNoWindowsRemain(closing: notification.object as? NSWindow)
    }

    /// Goes back to being a menu-bar app once the last ordinary window closes.
    ///
    /// Opening the chat window or Settings switches the app to `.regular` so it can own a
    /// menu bar, and nothing switched it back. The app then kept the menu bar and the Dock
    /// icon for the rest of the session, took focus from whatever the user was working in,
    /// and interrupted copy and paste in that app — because a `.regular` app that
    /// activates is, correctly, taking over.
    func restoreAccessoryPolicyIfNoWindowsRemain(closing: NSWindow?) {
        // Run after the close completes: the window being closed still reports itself
        // visible while the notification is being delivered.
        DispatchQueue.main.async {
            let settingsOpen = self.settingsWindow?.isVisible == true
                && self.settingsWindow !== closing
            let chatOpen = GeneralChatWindowController.shared.isVisible
            guard !settingsOpen, !chatOpen else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func registerGlobalHotkey() {
        // Double-press Option (⌥⌥) is the ONLY launcher activation — the legacy
        // Carbon key combo (⌘D / ⌥Space) is retired and never registered. This
        // also clears any previously registered launcher hotkey ref.
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    func unregisterGlobalHotkey() {
        // Unregister all three Carbon hotkeys
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let ref = contextDockHotKeyRef {
            UnregisterEventHotKey(ref)
            contextDockHotKeyRef = nil
        }
        if let ref = clipboardScopeHotKeyRef {
            UnregisterEventHotKey(ref)
            clipboardScopeHotKeyRef = nil
        }
        unregisterCaptureHotkeys()

        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        // Remove NSEvent monitors
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = singleOptionFocusMonitor {
            NSEvent.removeMonitor(monitor)
            singleOptionFocusMonitor = nil
        }
        if let monitor = singleOptionLocalFocusMonitor {
            NSEvent.removeMonitor(monitor)
            singleOptionLocalFocusMonitor = nil
        }
        if let monitor = singleOptionCancelMonitor {
            NSEvent.removeMonitor(monitor)
            singleOptionCancelMonitor = nil
        }
        if let monitor = singleOptionLocalCancelMonitor {
            NSEvent.removeMonitor(monitor)
            singleOptionLocalCancelMonitor = nil
        }
        if let monitor = singleCommandFocusMonitor {
            NSEvent.removeMonitor(monitor)
            singleCommandFocusMonitor = nil
        }
        if let monitor = singleCommandLocalFocusMonitor {
            NSEvent.removeMonitor(monitor)
            singleCommandLocalFocusMonitor = nil
        }
        if let monitor = singleCommandCancelMonitor {
            NSEvent.removeMonitor(monitor)
            singleCommandCancelMonitor = nil
        }
        if let monitor = singleCommandLocalCancelMonitor {
            NSEvent.removeMonitor(monitor)
            singleCommandLocalCancelMonitor = nil
        }
    }

    func registerContextDockHotkey() {
        // Remove previous handler BEFORE installing new one — prevents N-fire ghost activations
        // when settings change re-calls this function (leaked handlers stack up on the event target).
        if let ref = contextDockEventHandlerRef {
            RemoveEventHandler(ref)
            contextDockEventHandlerRef = nil
        }
        if let ref = contextDockHotKeyRef {
            UnregisterEventHotKey(ref)
            contextDockHotKeyRef = nil
        }
        // "Show Context Dock" global hotkey removed — Context Dock is reached by tapping ⌘
        // (single-command monitor) to switch from Global Context. This stays as a cleanup-only
        // no-op so any stale handler from a previous launch is torn down.
    }

    func registerClipboardScopeHotkey() {
        if let ref = clipboardScopeEventHandlerRef {
            RemoveEventHandler(ref)
            clipboardScopeEventHandlerRef = nil
        }
        if let ref = clipboardScopeHotKeyRef {
            UnregisterEventHotKey(ref)
            clipboardScopeHotKeyRef = nil
        }
        guard settings.clipboardScopeHotkeyEnabled else { return }
        let hotKeyID = EventHotKeyID(signature: FourCharCode(bitPattern: 0x494C_636C), id: 3)  // 'ILcl'
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var receivedID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID)
            guard status == noErr,
                receivedID.signature == FourCharCode(bitPattern: 0x494C_636C),
                receivedID.id == 3
            else { return OSStatus(eventNotHandledErr) }
            guard let delegate = userData?.assumingMemoryBound(to: AppDelegate.self).pointee else {
                return OSStatus(eventNotHandledErr)
            }
            delegate.activateClipboardScope()
            return noErr
        }
        var selfPtr = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        selfPtr.initialize(to: self)
        var handlerRef: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &handlerRef)
        clipboardScopeEventHandlerRef = handlerRef  // store so next call can remove it
        RegisterEventHotKey(
            settings.clipboardScopeHotkeyKeyCode, settings.clipboardScopeHotkeyModifiers,
            hotKeyID, GetApplicationEventTarget(), 0, &clipboardScopeHotKeyRef)
    }

    /// Global hotkey → put the App Chat prompt in the corner, aimed at whatever the user
    /// is looking at. The surface is built; the route the question takes is not yet.
    func registerAppChatHotkey() {
        if let ref = appChatEventHandlerRef {
            RemoveEventHandler(ref)
            appChatEventHandlerRef = nil
        }
        if let ref = appChatHotKeyRef {
            UnregisterEventHotKey(ref)
            appChatHotKeyRef = nil
        }
        guard settings.appChatHotkeyEnabled else { return }
        let hotKeyID = EventHotKeyID(signature: FourCharCode(bitPattern: 0x494C_6163), id: 9)  // 'ILac'
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var receivedID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID)
            guard status == noErr,
                receivedID.signature == FourCharCode(bitPattern: 0x494C_6163),
                receivedID.id == 9
            else { return OSStatus(eventNotHandledErr) }
            guard let delegate = userData?.assumingMemoryBound(to: AppDelegate.self).pointee else {
                return OSStatus(eventNotHandledErr)
            }
            delegate.activateAppChatPrompt()
            return noErr
        }
        var selfPtr = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        selfPtr.initialize(to: self)
        var handlerRef: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &handlerRef)
        appChatEventHandlerRef = handlerRef
        RegisterEventHotKey(
            settings.appChatHotkeyKeyCode, settings.appChatHotkeyModifiers,
            hotKeyID, GetApplicationEventTarget(), 0, &appChatHotKeyRef)
    }

    #if DEBUG
    /// Developer Inspector toggle. DEBUG only, fixed, and absent from hotkey settings — this is
    /// developer infrastructure, not a product hotkey a user can rebind or stumble into.
    ///
    /// Registration fails closed: if `⌥⌘I` is already taken, Inspect Mode is simply unavailable
    /// for this launch. Displacing whatever holds it would be a developer tool silently
    /// breaking someone's real shortcut.
    func registerInspectorHotkey() {
        if let ref = inspectorEventHandlerRef {
            RemoveEventHandler(ref)
            inspectorEventHandlerRef = nil
        }
        if let ref = inspectorHotKeyRef {
            UnregisterEventHotKey(ref)
            inspectorHotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: FourCharCode(bitPattern: 0x494C_6469), id: 77)  // 'ILdi'
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var receivedID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID)
            guard status == noErr,
                receivedID.signature == FourCharCode(bitPattern: 0x494C_6469),
                receivedID.id == 77
            else { return OSStatus(eventNotHandledErr) }
            guard userData?.assumingMemoryBound(to: AppDelegate.self).pointee != nil else {
                return OSStatus(eventNotHandledErr)
            }
            InspectorSessionController.shared.toggle()
            return noErr
        }
        var selfPtr = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        selfPtr.initialize(to: self)
        var handlerRef: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &handlerRef)
        inspectorEventHandlerRef = handlerRef

        // 34 is `I`; the modifiers are Option + Command.
        let status = RegisterEventHotKey(
            34, UInt32(optionKey | cmdKey), hotKeyID, GetApplicationEventTarget(), 0,
            &inspectorHotKeyRef)
        if status != noErr {
            NSLog("[Inspector] ⌥⌘I unavailable (RegisterEventHotKey status \(status))")
            inspectorHotKeyRef = nil
        }
    }

    #endif

    /// The prompt is about the app the user is looking at, so the app is captured here —
    /// before opening the prompt makes Context-Dock frontmost.
    /// The app the user is working in, as the corner's Context Dock target — read before the
    /// corner takes the keys. If the panel is already key, the helper remembers the app
    /// behind it instead of turning the next summon into "Chat with Context-Dock".
    func frontmostChatTarget() -> CornerChatTarget {
        let target = Self.appChatTargetApplication(
            menuBarOwner: menuBarOwningUserFacingApplication(),
            remembered: previousFrontmostApp,
            rawFrontmost: NSWorkspace.shared.frontmostApplication,
            ownBundleID: Bundle.main.bundleIdentifier ?? "")
        return CornerChatTarget(
            name: target?.localizedName ?? "",
            bundleID: target?.bundleIdentifier ?? "",
            suggestions: AppChatSuggestionProvider.suggestions(for: target),
            summary: AppChatSuggestionProvider.summary(for: target))
    }

    func activateAppChatPrompt(toggles: Bool = true) {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastHotkeyFiredAt > 0.15 else { return }
        lastHotkeyFiredAt = now
        let chatTarget = frontmostChatTarget()
        CornerDockController.shared.activate()
        if toggles {
            CornerChatPresentation.shared.cycle(target: chatTarget)
        } else {
            CornerChatPresentation.shared.showFrontmostApp(target: chatTarget)
        }
    }

    /// ⌥⌥ again while it is up puts it away, as the other scope hotkeys do.
    func toggleCentredCorner() {
        guard settings.enableLayer2 else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastHotkeyFiredAt > 0.15 else { return }
        lastHotkeyFiredAt = now
        let presentation = CornerDockController.shared.chatPresentation
        if presentation.isVisible, presentation.isCentred {
            presentation.dismiss()
            return
        }
        CornerDockController.shared.showCentred()
    }

    /// ⌘⌘: the app in front's Context Dock. Pressed again while that is up (and not slid away
    /// by auto-hide), it puts the corner away, as the other scope hotkeys do.
    func activateContextDockFromDoubleCommand() {
        let presentation = CornerDockController.shared.chatPresentation
        if presentation.isVisible, presentation.mode == .frontmostApp,
            !CornerDockController.shared.isAutoHidden
        {
            presentation.dismiss()
            return
        }
        // From Global or General, straight to the app's Context Dock — not a toggle that
        // would put a visible corner away instead.
        activateAppChatPrompt(toggles: false)
        // Already that app's resting dock, slid away by auto-hide: showing it again changed
        // nothing, so it stayed hidden (owner 2026-10-11). Open the field, as a fresh ⌘⌘ does.
        CornerDockController.shared.prompt.expandFromDock(seeding: nil)
        CornerDockController.shared.armKeyboard()
    }

    /// Global hotkey → open (pin) a Quick Note sticky.
    func registerQuickNoteHotkey() {
        if let ref = quickNoteEventHandlerRef {
            RemoveEventHandler(ref)
            quickNoteEventHandlerRef = nil
        }
        if let ref = quickNoteHotKeyRef {
            UnregisterEventHotKey(ref)
            quickNoteHotKeyRef = nil
        }
        guard settings.quickNoteHotkeyEnabled else { return }
        let hotKeyID = EventHotKeyID(signature: FourCharCode(bitPattern: 0x494C_716E), id: 4)  // 'ILqn'
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var receivedID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID)
            guard status == noErr,
                receivedID.signature == FourCharCode(bitPattern: 0x494C_716E),
                receivedID.id == 4
            else { return OSStatus(eventNotHandledErr) }
            guard let delegate = userData?.assumingMemoryBound(to: AppDelegate.self).pointee else {
                return OSStatus(eventNotHandledErr)
            }
            delegate.activateQuickNoteSticky()
            return noErr
        }
        let selfPtr = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        selfPtr.initialize(to: self)
        var handlerRef: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &handlerRef)
        quickNoteEventHandlerRef = handlerRef
        RegisterEventHotKey(
            settings.quickNoteHotkeyKeyCode, settings.quickNoteHotkeyModifiers,
            hotKeyID, GetApplicationEventTarget(), 0, &quickNoteHotKeyRef)
    }

    /// Global hotkey → open the full-window General Chat surface.
    func registerChatWindowHotkey() {
        if let ref = chatWindowEventHandlerRef {
            RemoveEventHandler(ref)
            chatWindowEventHandlerRef = nil
        }
        if let ref = chatWindowHotKeyRef {
            UnregisterEventHotKey(ref)
            chatWindowHotKeyRef = nil
        }
        guard settings.chatWindowHotkeyEnabled else { return }
        let hotKeyID = EventHotKeyID(signature: FourCharCode(bitPattern: 0x494C_6377), id: 5)  // 'ILcw'
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var receivedID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID)
            guard status == noErr,
                receivedID.signature == FourCharCode(bitPattern: 0x494C_6377),
                receivedID.id == 5
            else { return OSStatus(eventNotHandledErr) }
            guard let delegate = userData?.assumingMemoryBound(to: AppDelegate.self).pointee else {
                return OSStatus(eventNotHandledErr)
            }
            delegate.toggleGeneralChatWindow()
            return noErr
        }
        let selfPtr = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        selfPtr.initialize(to: self)
        var handlerRef: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &handlerRef)
        chatWindowEventHandlerRef = handlerRef
        RegisterEventHotKey(
            settings.chatWindowHotkeyKeyCode, settings.chatWindowHotkeyModifiers,
            hotKeyID, GetApplicationEventTarget(), 0, &chatWindowHotKeyRef)
    }

    /// Open a floating Quick Note sticky — the most recent note, or a fresh one.
    func activateQuickNoteSticky() {
        DispatchQueue.main.async {
            let store = QuickNotesStore.shared
            let id = store.notes.first?.id ?? store.create()
            StickyNotesManager.shared.pin(id)
        }
    }

    func unregisterCaptureHotkeys() {
        if let ref = captureHotkeyEventHandlerRef {
            RemoveEventHandler(ref)
            captureHotkeyEventHandlerRef = nil
        }
        for ref in [captureTextHotKeyRef, captureAreaHotKeyRef, captureScreenshotHotKeyRef,
                    selectionScopeHotKeyRef] {
            if let ref { UnregisterEventHotKey(ref) }
        }
        captureTextHotKeyRef = nil
        captureAreaHotKeyRef = nil
        captureScreenshotHotKeyRef = nil
        selectionScopeHotKeyRef = nil
    }

    func registerCaptureHotkeys() {
        unregisterCaptureHotkeys()
        let configured = [
            settings.captureTextHotkeyKeyCode,
            settings.captureAreaHotkeyKeyCode,
            settings.captureScreenshotHotkeyKeyCode,
            settings.selectionScopeHotkeyKeyCode,
        ].contains { $0 != 0 }
        guard configured else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            guard hotKeyID.signature == FourCharCode(bitPattern: 0x494C_6370) else {
                return OSStatus(eventNotHandledErr)
            }
            switch hotKeyID.id {
            case 41: ScreenCaptureService.shared.capture(.text)
            case 42: ScreenCaptureService.shared.capture(.area)
            case 43: ScreenCaptureService.shared.capture(.screenshot)
            case 45: AppDelegate.shared?.activateSelectionScope()
            case 46: AppDelegate.shared?.activateGlobalContextScope()
            default: return OSStatus(eventNotHandledErr)
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType, nil,
            &captureHotkeyEventHandlerRef)

        let signature = FourCharCode(bitPattern: 0x494C_6370) // 'ILcp'
        if settings.captureTextHotkeyKeyCode != 0 {
            let id = EventHotKeyID(signature: signature, id: 41)
            RegisterEventHotKey(
                settings.captureTextHotkeyKeyCode, settings.captureTextHotkeyModifiers,
                id, GetApplicationEventTarget(), 0, &captureTextHotKeyRef)
        }
        if settings.captureAreaHotkeyKeyCode != 0 {
            let id = EventHotKeyID(signature: signature, id: 42)
            RegisterEventHotKey(
                settings.captureAreaHotkeyKeyCode, settings.captureAreaHotkeyModifiers,
                id, GetApplicationEventTarget(), 0, &captureAreaHotKeyRef)
        }
        if settings.captureScreenshotHotkeyKeyCode != 0 {
            let id = EventHotKeyID(signature: signature, id: 43)
            RegisterEventHotKey(
                settings.captureScreenshotHotkeyKeyCode,
                settings.captureScreenshotHotkeyModifiers,
                id, GetApplicationEventTarget(), 0, &captureScreenshotHotKeyRef)
        }
        if settings.selectionScopeHotkeyKeyCode != 0 {
            let id = EventHotKeyID(signature: signature, id: 45)
            RegisterEventHotKey(
                settings.selectionScopeHotkeyKeyCode, settings.selectionScopeHotkeyModifiers,
                id, GetApplicationEventTarget(), 0, &selectionScopeHotKeyRef)
        }
        if settings.globalContextHotkeyKeyCode != 0 {
            let id = EventHotKeyID(signature: signature, id: 46)
            RegisterEventHotKey(
                settings.globalContextHotkeyKeyCode, settings.globalContextHotkeyModifiers,
                id, GetApplicationEventTarget(), 0, &globalContextHotKeyRef)
        }
    }

    func registerDoubleOptionMonitor() {
        if let m = doubleOptionMonitor {
            NSEvent.removeMonitor(m)
            doubleOptionMonitor = nil
        }
        if let m = doubleOptionLocalMonitor {
            NSEvent.removeMonitor(m)
            doubleOptionLocalMonitor = nil
        }
        if let m = singleOptionCancelMonitor {
            NSEvent.removeMonitor(m)
            singleOptionCancelMonitor = nil
        }
        if let m = singleOptionLocalCancelMonitor {
            NSEvent.removeMonitor(m)
            singleOptionLocalCancelMonitor = nil
        }
        guard settings.useDoubleOptionLaunch || settings.useDoubleCommandGlobalContext else { return }

        var optionTap = DoubleModifierTap()
        var commandTap = DoubleModifierTap()

        let cancelOptionTap: () -> Void = { [weak self] in
            guard let self else { return }
            self.optionTapContaminated = true
            self.lastOptionPressTime = 0
            optionTap.cancel()
            commandTap.cancel()
        }

        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if commandTap.update(
                isDown: flags.contains(.command),
                hasOtherModifiers: !flags.intersection([.option, .control, .shift, .function]).isEmpty,
                time: event.timestamp), self.settings.useDoubleCommandGlobalContext {
                // ⌘⌘ opens the Context Dock of the app in front; a single ⌘ tap switches to
                // Global, and Backspace on its empty field goes there too (owner 2026-10-08).
                DispatchQueue.main.async { self.activateContextDockFromDoubleCommand() }
            }
            if optionTap.update(
                isDown: flags.contains(.option),
                hasOtherModifiers: !flags.intersection([.command, .control, .shift, .function]).isEmpty,
                time: event.timestamp), self.settings.useDoubleOptionLaunch {
                // ⌥⌥: the Corner's Global Context in the middle of the display, like
                // Spotlight — the Corner's own UI, not the old launcher (owner 2026-10-12).
                DispatchQueue.main.async { self.toggleCentredCorner() }
            }
        }

        doubleOptionMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            handle($0)
        }
        doubleOptionLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            event in
            handle(event)
            return event
        }
        singleOptionCancelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in
            cancelOptionTap()
        }
        singleOptionLocalCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            cancelOptionTap()
            return event
        }
    }

    func unregisterModifierSideEffectMonitors() {
        if let m = singleOptionFocusMonitor {
            NSEvent.removeMonitor(m)
            singleOptionFocusMonitor = nil
        }
        if let m = singleOptionLocalFocusMonitor {
            NSEvent.removeMonitor(m)
            singleOptionLocalFocusMonitor = nil
        }
        if let m = singleCommandFocusMonitor {
            NSEvent.removeMonitor(m)
            singleCommandFocusMonitor = nil
        }
        if let m = singleCommandLocalFocusMonitor {
            NSEvent.removeMonitor(m)
            singleCommandLocalFocusMonitor = nil
        }
        if let m = singleCommandCancelMonitor {
            NSEvent.removeMonitor(m)
            singleCommandCancelMonitor = nil
        }
        if let m = singleCommandLocalCancelMonitor {
            NSEvent.removeMonitor(m)
            singleCommandLocalCancelMonitor = nil
        }
        commandAloneActive = false
    }


    func activateContextDock() {
        // Captured before the async hop, which is what lost the caller last time: the stack
        // inside the dispatched closure shows only libdispatch.
        if DoraXTurnLog.isEnabled {
            DoraXTurnLog.record(
                "activateContextDock — \(Thread.callStackSymbols.dropFirst().prefix(6).joined(separator: " | "))")
        }
        guard settings.enableLayer2 else { return }  // Layer 2 disabled — hotkey does nothing
        // The app's Context Dock is the centred Corner now, not the old launcher (owner
        // 2026-10-12) — the Context Dock hotkey and Safari's toolbar button alike.
        toggleCentredCorner()
    }


    func activateClipboardScope() {
        guard settings.enableLayer2 else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastHotkeyFiredAt > 0.15 else { return }
        lastHotkeyFiredAt = now
        // The Corner's clipboard board (owner 2026-10-07).
        ClipboardPanelController.shared.toggle()
    }

    /// Global hotkey → open the dock directly in Selection Scope for whatever the frontmost
    /// app has selected. Deliberately separate from the launcher hotkey: a plain launcher open
    /// must stay a launcher (typing an app name), never get hijacked by a live selection.
    /// Global Context in the corner: every running app's commands in one ranked list.
    ///
    /// A scope of the corner chat rather than a surface of its own — the same field asks,
    /// and the chip says which scope is answering. Pressing it again puts the corner away,
    /// like the other scope hotkeys.
    func activateGlobalContextScope() {
        guard settings.enableLayer2 else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastHotkeyFiredAt > 0.15 else { return }
        lastHotkeyFiredAt = now

        let presentation = CornerDockController.shared.chatPresentation
        // Slid below the screen by auto-hide is not "open": the press brings it up.
        if presentation.isVisible, presentation.mode == .globalContext,
            !CornerDockController.shared.isAutoHidden
        {
            presentation.dismiss()
            return
        }
        presentation.showGlobalContext()
        CornerDockController.shared.armKeyboard()
    }

    /// `sourceBundleID`: when the caller already knows exactly which app the selection
    /// belongs to — a button inside that app's own corner chat, say — name it explicitly
    /// rather than asking "whatever is frontmost right now". Reading frontmostApplication
    /// at that point returns *this app*, since a click on our own button requires our own
    /// window to be key: the guard below would then skip the refresh and quietly fall back
    /// to whatever AXContextReader last happened to hold, which is correct only by luck.
    /// The global hotkey path keeps asking "whatever is frontmost" because there it is
    /// genuinely true — the hotkey fires while some other app still holds the key window.
    func activateSelectionScope(sourceBundleID: String? = nil) {
        guard settings.enableLayer2 else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastHotkeyFiredAt > 0.15 else { return }
        lastHotkeyFiredAt = now
        // Read the selection BEFORE the panel appears, while the source app is still frontmost.
        // The launcher then paints Selection Scope on its first frame instead of showing Context
        // Dock and swapping once an async AX read lands.
        if let bundleID = sourceBundleID, !bundleID.isEmpty,
            let named = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleID && !$0.isTerminated
            })
        {
            AXContextReader.shared.refreshSelectionOnly(from: named)
        } else if let source = NSWorkspace.shared.frontmostApplication,
            source.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            AXContextReader.shared.refreshSelectionOnly(from: source)
        }
        // The selection is a corner surface, stacked with the clipboard, the shelf and the
        // chat that will act on it. It used to open the launcher window drawn as a compact
        // pill, which looked like a corner card without being one — it could not stack,
        // and it pulled the whole launcher up behind it.
        //
        // Nothing selected leaves the corner alone rather than raising an empty card.
        CornerDockController.shared.selection.toggle(from: AXContextReader.shared.current)
    }

    /// True while a compact scope (Clipboard / Notifications) is showing, so the
    /// launcher does not auto-hide when another app takes focus.
    var smartScopeActive = false



    func registerOutsideMouseMonitor() {
        if let outsideMouseMonitor {
            NSEvent.removeMonitor(outsideMouseMonitor)
        }
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]) { [weak self] _ in
            self?.lastOutsideMouseDownAt = Date().timeIntervalSinceReferenceDate
        }
    }







    // Detect and store frontmost app info before ILauncher activates
    // Track frontmost app changes to capture the previously active app
    func setupFrontmostAppTracking() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Quitting the scoped app hands the empty desktop to Finder on macOS (menu bar always
        // has an owner). But our floating panel often holds key focus, so macOS may not post a
        // didActivate for Finder — the dock would otherwise sit on a stale/blank scope. Observe
        // termination and re-resolve the owner (next real app, or Finder when none).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Initialize with the current MENU BAR owner (what macOS actually shows).
        if let currentApp = menuBarOwningUserFacingApplication() {
            recordFrontmostApp(currentApp)
            Task { @MainActor in
                MenuWarmCacheService.shared.frontmostAppDidChange(currentApp)
            }
            #if DEBUG
            print("📱 [AppDelegate] Initial frontmost app: \(currentApp.localizedName ?? "Unknown")")
            #endif
        }
    }

    @objc func frontmostAppChanged(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else {
            return
        }

        // A capture UI is a transient overlay, not the user moving to another app —
        // pushing it through as the new frontmost would swap the dock's scope out from
        // under whatever they were doing.
        if Self.isScreenCaptureUI(app) { return }

        // Only track user-facing non-DoraX apps. Resolve helper processes (ChatGPT helper, etc.)
        // back to their owning .app before pushing context into DockCore.
        guard let resolvedApp = resolvedUserFacingApplication(app) else { return }

        recordFrontmostApp(resolvedApp)
        #if DEBUG
        print("📱 [AppDelegate] Frontmost app changed to: \(resolvedApp.localizedName ?? "Unknown")")
        #endif
        ContextDockEnvironment.shared.frontmostAppDidChange(
            name: resolvedApp.localizedName ?? "",
            bundleID: resolvedApp.bundleIdentifier ?? ""
        )
        Task { @MainActor in
            MenuWarmCacheService.shared.frontmostAppDidChange(resolvedApp)
        }

        let pid = resolvedApp.processIdentifier
        // Browser windows are expensive AX trees. Do not eagerly crawl page text just
        // because a browser became frontmost; the dock warms that context on demand.
        if AXWebReader.shared.isBrowser(bundleId: resolvedApp.bundleIdentifier ?? "") {
            AXWebReader.shared.invalidate(pid: pid)
        } else {
            // Not a browser — evict stale cache so memory doesn't grow
            AXWebReader.shared.invalidate(pid: pid)
        }

    }

    @objc func appDidTerminate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        // Only react when the app we're tracking/scoped to went away — other apps quitting in
        // the background don't change the dock's scope.
        let wasTracked =
            app.processIdentifier == previousFrontmostApp?.processIdentifier
            || (app.bundleIdentifier != nil
                && app.bundleIdentifier == previousFrontmostApp?.bundleIdentifier)
        guard wasTracked else { return }

        let terminatedPID = app.processIdentifier

        // Let macOS settle, then just READ THE MENU BAR — it already names the new owner (the
        // next real app, or Finder on an empty desktop). No guessing at "who's next": macOS has
        // decided, and the menu bar is what the user sees.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let target = self.menuBarOwningUserFacingApplication(),
                target.bundleIdentifier != ownBundleID,
                target.processIdentifier != terminatedPID,
                !target.isTerminated
            else { return }
            self.recordFrontmostApp(target)
            ContextDockEnvironment.shared.frontmostAppDidChange(
                name: target.localizedName ?? "Finder",
                bundleID: target.bundleIdentifier ?? "com.apple.finder"
            )
            Task { @MainActor in
                MenuWarmCacheService.shared.frontmostAppDidChange(target)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop accessing security-scoped resources
        settings.stopAccessingSearchDirectories()

        // Terminate any running MCP server subprocesses.
        Task { await MCPRuntime.shared.shutdownAll() }

        // Unregister hotkeys and cleanup
        unregisterGlobalHotkey()

        // Remove notification observers
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
