//
//  ILauncherApp.swift
//  ILauncher
//
//  Created by Krishgokul on 20/11/2025.
//

import AppKit
import Carbon
import SwiftUI

// Custom NSHostingView that can accept first responder and has a transparent background
class FocusableHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 34
        layer?.masksToBounds = true
        // Suppress the system focus ring — without this a blue rounded rectangle
        // appears over all apps when the window is visible and the view is first responder.
        focusRingType = .none
        layer?.borderWidth = 0
    }
}

// Custom NSWindow that can become key window and is draggable
// NSPanel (not NSWindow) so it can carry .nonactivatingPanel: the launcher
// becomes key for typing WITHOUT activating Context-Dock, so the frontmost app
// keeps its menu bar (Spotlight/Alfred behaviour) instead of being replaced by
// our app's menus.
class KeyableWindow: NSPanel {
    // Flag to anchor window at bottom when expanding
    var anchorAtBottom: Bool = false
    var horizontalResizeAnchorX: CGFloat?
    private var bottomAnchorY: CGFloat = 10  // Distance from bottom of screen

    // Track initial mouse location for smooth dragging
    private var initialMouseLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?

    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return true
    }

    // Start tracking drag
    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = frame.origin
        super.mouseDown(with: event)
    }

    // Make window draggable by background with smooth tracking
    override func mouseDragged(with event: NSEvent) {
        guard let initialMouse = initialMouseLocation,
            let initialOrigin = initialWindowOrigin
        else {
            super.mouseDragged(with: event)
            return
        }

        // Calculate offset from initial mouse position
        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - initialMouse.x
        let deltaY = currentLocation.y - initialMouse.y

        // Move window by the delta
        let newOrigin = NSPoint(
            x: initialOrigin.x + deltaX,
            y: initialOrigin.y + deltaY
        )

        self.setFrameOrigin(newOrigin)
    }

    // Reset tracking when mouse up
    override func mouseUp(with event: NSEvent) {
        initialMouseLocation = nil
        initialWindowOrigin = nil
        horizontalResizeAnchorX = frame.midX
        super.mouseUp(with: event)
    }

    // Override setFrame to anchor at bottom when flag is enabled
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var adjustedFrame = frameRect

        if anchorAtBottom, let screen = self.screen ?? NSScreen.main {
            // When anchored at bottom, calculate the Y position to keep bottom fixed
            let screenFrame = screen.visibleFrame
            let desiredBottomY = screenFrame.minY + bottomAnchorY

            // Set Y so that window bottom stays at desired position
            adjustedFrame.origin.y = desiredBottomY

        }

        super.setFrame(adjustedFrame, display: flag)
    }

    // Ensure standard text-editing keyboard shortcuts (Cmd+A/V/C/X/Z) always reach the
    // focused SwiftUI TextField. In .accessory policy mode the main menu isn't always
    // the active menu, so macOS doesn't automatically route these key equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            let key = event.characters?.lowercased()
        else { return false }
        switch key {
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        case ",":
            AppDelegate.shared?.showSettings()
            return true
        default: return false
        }
    }

    // Escape key (via AppKit responder chain) — fires if SwiftUI doesn't capture it first.
    // Posts a notification so ContentView can exit any active scope.
    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .escapePressed, object: nil)
    }

    // Disable Full Keyboard Navigation tab traversal.
    override func selectKeyView(following aView: NSView) {}
    override func selectKeyView(preceding aView: NSView) {}

    // Also override the animated version
    override func setFrame(
        _ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool
    ) {
        var adjustedFrame = frameRect

        if anchorAtBottom, let screen = self.screen ?? NSScreen.main {
            // When anchored at bottom, calculate the Y position to keep bottom fixed
            let screenFrame = screen.visibleFrame
            let desiredBottomY = screenFrame.minY + bottomAnchorY

            // Set Y so that window bottom stays at desired position
            adjustedFrame.origin.y = desiredBottomY

        }

        super.setFrame(adjustedFrame, display: displayFlag, animate: animateFlag)
    }
}

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
    /// Global shared reference — safe to use from anywhere without NSApp.delegate cast.
    /// (The @NSApplicationDelegateAdaptor pattern can make NSApp.delegate as? AppDelegate fail.)
    static weak var shared: AppDelegate?

    var launcherWindow: NSWindow?
    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem?
    var eventMonitor: Any?
    var localEventMonitor: Any?
    var outsideMouseMonitor: Any?
    var lastOutsideMouseDownAt: TimeInterval = 0
    var hotKeyRef: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var contextDockHotKeyRef: EventHotKeyRef?
    var contextDockEventHandlerRef: EventHandlerRef?   // stored so re-register removes old handler
    var clipboardScopeHotKeyRef: EventHotKeyRef?
    var clipboardScopeEventHandlerRef: EventHandlerRef? // stored so re-register removes old handler
    var lastHotkeyFiredAt: TimeInterval = 0
    /// Hide-on-resign-key is suppressed until this date (set around Space switches).
    var suppressHideOnResignUntil: Date = .distantPast
    private var smartScopeActivationGeneration = 0
    var doubleOptionMonitor: Any?
    var doubleOptionLocalMonitor: Any?
    var lastOptionPressTime: TimeInterval = 0
    var optionKeyDown = false
    var optionTapContaminated = false
    // Single Option-press focus: bring our search field to front without a hotkey
    var singleOptionFocusMonitor: Any?
    var singleOptionLocalFocusMonitor: Any?
    var singleOptionCancelMonitor: Any?
    var singleOptionLocalCancelMonitor: Any?
    var optionAloneActive: Bool = false
    var optionAloneDownTime: TimeInterval = 0
    // Single Command-press focus: switch the visible dock to Global Context.
    var singleCommandFocusMonitor: Any?
    var singleCommandLocalFocusMonitor: Any?
    var singleCommandCancelMonitor: Any?
    var singleCommandLocalCancelMonitor: Any?
    var commandAloneActive: Bool = false
    var commandAloneDownTime: TimeInterval = 0
    /// True when the launcher was opened / switched via the context-dock shortcut.
    /// ContentView reads this on `launcherWindowOpened` to keep the app in L2.
    var isDockContextMode: Bool = false
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

    // Settings window size protection
    private var settingsResizeObserver: NSObjectProtocol?
    private var settingsEndLiveResizeObserver: NSObjectProtocol?
    private var settingsCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self  // Register global reference
        // Enforce single instance — if another copy is already running, tell it to show and quit
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
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

        // Create the launcher window
        setupLauncherWindow()

        // Register global hotkeys
        registerGlobalHotkey()
        registerContextDockHotkey()
        registerClipboardScopeHotkey()
        registerOutsideMouseMonitor()
        unregisterModifierSideEffectMonitors()
        registerDoubleOptionMonitor()

        // Setup notification observers for settings changes
        setupNotificationObservers()

        // Track frontmost app changes to capture context BEFORE ILauncher activates
        setupFrontmostAppTracking()
        MenuWarmCacheService.shared.startIdleWarming()
        DoraXSpotlightIndexService.shared.scheduleRebuild(reason: "launch")

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

        // Desktop/Space switches briefly deactivate the app, which would trigger
        // the hide-on-resign-key path. Suppress that hide around space changes so
        // the launcher (which joins all Spaces) survives desktop switching.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
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

        // Re-register hotkeys on wake — Carbon hotkeys are invalidated after sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWakeFromSleep),
            name: NSWorkspace.screensDidWakeNotification,
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

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTermination(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func handleAppActivation(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            let resolvedApp = resolvedUserFacingApplication(app)
        else { return }
        recordFrontmostApp(resolvedApp)
        reinforceFloatingDockWindow(reason: "app activation", activate: false)
        // Menu cache is validated by bundleVersion inside AXMenuEnumerator — no manual invalidation needed.
    }

    @objc private func handleAppLaunch(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        MenuWarmCacheService.shared.appDidLaunch(app)
        reinforceFloatingDockWindow(reason: "app launch", activate: false)
    }

    @objc private func handleAppTermination(_ notification: Notification) {
        reinforceFloatingDockWindow(reason: "app termination", activate: false)
    }

    @objc func handleServicesOpenWithFiles(_ notification: Notification) {
        #if DEBUG
        print("🔧 [AppDelegate] Received servicesOpenWithFiles notification")
        #endif
        // Show launcher - the ContentView will handle the context
        showLauncher()
    }

    @objc func handleServicesOpenWithText(_ notification: Notification) {
        #if DEBUG
        print("🔧 [AppDelegate] Received servicesOpenWithText notification")
        #endif
        // Show launcher - the ContentView will handle the context
        showLauncher()
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
        // Re-register hotkeys after wake — Carbon hotkeys are invalidated during sleep.
        // Register methods clean up old handlers automatically, so just re-register all.
        registerGlobalHotkey()
        registerContextDockHotkey()
        registerClipboardScopeHotkey()
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
        DispatchQueue.main.async { self.showLauncher() }
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
                title: "Show Launcher (⌥⌥ · \(settings.hotkeyDisplayString))",
                action: #selector(showLauncherFromMenu), keyEquivalent: ""))
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

    @objc func showLauncherFromMenu() {
        showLauncher()
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
            ?? AppDelegate.shared?.launcherWindow?.screen
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

    /// Finds the settings window, sizes it to 80% of the screen, and installs a persistent
    /// Makes the settings window a fixed, non-resizable size centered on screen.
    private func applySettingsWindowSize() {
        guard let screen = NSScreen.main else { return }
        let win: NSWindow? =
            NSApp.windows.first(where: {
                $0.title.contains("Settings") || $0.title.contains("Preferences")
            })
            ?? NSApp.windows.first(where: {
                $0 !== self.launcherWindow && $0.styleMask.contains(.titled) && $0.isVisible
            })
        guard let win else { return }

        let fixedW: CGFloat = 920
        let fixedH: CGFloat = 680
        let sf = screen.visibleFrame
        let x = (sf.origin.x + (sf.width - fixedW) / 2).rounded()
        let y = (sf.origin.y + (sf.height - fixedH) / 2).rounded()
        let target = NSRect(x: x, y: y, width: fixedW, height: fixedH)

        // Remove resizable so SwiftUI tab switches can never change the window size
        win.styleMask.remove(.resizable)
        win.minSize = NSSize(width: fixedW, height: fixedH)
        win.maxSize = NSSize(width: fixedW, height: fixedH)
        win.setFrame(target, display: true, animate: false)
        win.makeKeyAndOrderFront(nil)

        // Re-apply once to catch SwiftUI's first layout pass
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            win.setFrame(target, display: true, animate: false)
        }

        // Remove any previous observers
        if let obs = settingsResizeObserver {
            NotificationCenter.default.removeObserver(obs)
            settingsResizeObserver = nil
        }
        if let obs = settingsEndLiveResizeObserver {
            NotificationCenter.default.removeObserver(obs)
            settingsEndLiveResizeObserver = nil
        }
        if let obs = settingsCloseObserver {
            NotificationCenter.default.removeObserver(obs)
            settingsCloseObserver = nil
        }

        // Restore resizable on close so other windows aren't affected
        settingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak win, weak self] _ in
            win?.styleMask.insert(.resizable)
            if let obs = self?.settingsCloseObserver {
                NotificationCenter.default.removeObserver(obs)
                self?.settingsCloseObserver = nil
            }
        }
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

    func setupLauncherWindow() {
        let contentView = LauncherShell(onClose: {
            self.hideLauncher(force: true)
        })
        .environmentObject(ContextDockEnvironment.shared)
        .environmentObject(AppState.shared)

        launcherWindow = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 60),
            styleMask: [.borderless, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // FocusableHostingView directly as contentView (original working approach)
        let hostingView = FocusableHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]

        launcherWindow?.contentView = hostingView
        launcherWindow?.backgroundColor = .clear
        launcherWindow?.isOpaque = false
        // Stay visible when Context-Dock isn't the active app — it never becomes
        // active now that it's a non-activating panel.
        launcherWindow?.hidesOnDeactivate = false
        let windowLevel: NSWindow.Level = settings.effectiveDockAtBottom
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        launcherWindow?.level = windowLevel
        launcherWindow?.collectionBehavior =
            settings.effectiveDockAtBottom
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        launcherWindow?.isMovableByWindowBackground = true
        // No window shadow: on a tight transparent window it renders as a hard dark
        // edge that fights the glass rim (double outline). A soft shadow needs window
        // margin around the card — handled in SwiftUI instead.
        launcherWindow?.hasShadow = false
        launcherWindow?.delegate = self
        launcherWindow?.ignoresMouseEvents = false
        launcherWindow?.hidesOnDeactivate = false
        // Persistent context dock: window stays visible + joins all spaces
        applyPersistentDockBehavior()

        // Set min/max size for resizing
        launcherWindow?.minSize = NSSize(width: 400, height: 60)
        launcherWindow?.maxSize = NSSize(width: 1200, height: 1000)

        launcherWindow?.showsResizeIndicator = false

        // Apply appearance from settings
        applyAppearanceOverride()
    }


    func applyPersistentDockBehavior() {
        guard let window = launcherWindow else { return }
        // Bottom dock joins every Space (always present). Floating dock uses
        // moveToActiveSpace: the hotkey brings it to WHATEVER desktop the user is
        // on, but a passive desktop switch does NOT make it appear — manual show/
        // hide, on the user's wish.
        window.collectionBehavior =
            settings.effectiveDockAtBottom
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        let newLevel: NSWindow.Level = settings.effectiveDockAtBottom
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        if window.level != newLevel { window.level = newLevel }
        window.isMovableByWindowBackground = true
    }

    func reinforceFloatingDockWindow(reason: String, activate: Bool) {
        guard settings.alwaysFloatDock || settings.effectiveDockAtBottom else { return }
        guard let window = launcherWindow else { return }
        // Only keep an ALREADY-visible dock on top. Never resurrect a dock the
        // user hid — otherwise switching/activating apps re-opens it. Manual
        // show/hide only. (Bottom dock is exempt; it's meant to be persistent.)
        guard window.isVisible || settings.effectiveDockAtBottom else { return }
        applyPersistentDockBehavior()
        suppressHideOnResignUntil = Date().addingTimeInterval(0.8)
        window.alphaValue = 1
        window.orderFrontRegardless()
        if activate {
            window.makeKeyAndOrderFront(nil)
            self.launcherWindow?.makeKey()
        }
    }

    /// Overrides window appearance (light/dark/system)
    func applyAppearanceOverride() {
        guard let window = launcherWindow else { return }
        switch settings.appearanceMode {
        case "light":
            window.appearance = NSAppearance(named: .aqua)
        case "dark":
            window.appearance = NSAppearance(named: .darkAqua)
        default:
            window.appearance = nil
        }
    }

    @objc private func handleActiveSpaceChanged(_ notification: Notification) {
        guard let window = launcherWindow, window.isVisible else { return }
        // Floating dock is manual: do NOT follow the user to a new Space or grab
        // focus there. Only the bottom dock re-asserts itself across Spaces.
        guard settings.effectiveDockAtBottom else { return }
        suppressHideOnResignUntil = Date().addingTimeInterval(1.0)
        applyPersistentDockBehavior()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let window = self.launcherWindow, window.isVisible else { return }
            self.reinforceFloatingDockWindow(reason: "active Space changed", activate: false)
        }
    }

    // Match Spotlight/Raycast: clicking another app dismisses launcher without terminating it.
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === launcherWindow else { return }
        guard !settings.effectiveDockAtBottom else { return }
        // Always-float: never auto-hide on focus loss (incl. when a launched/menu-acted
        // app comes frontmost). Dismiss only via Escape / hotkey.
        guard !settings.alwaysFloatDock else { return }
        // Pinned via the pin button: stays floating over every app until unpinned.
        guard !settings.launcherPinned else { return }
        guard Date() >= suppressHideOnResignUntil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.launcherWindow, window.isVisible else { return }
            guard Date() >= self.suppressHideOnResignUntil else { return }
            // Keep launcher available while one of our own panels (settings, approvals) owns focus.
            guard !NSApp.isActive else { return }
            // Hide on any focus loss to another app — mouse click OR Cmd+Tab OR Dock click.
            // The previous mouse-click-only guard caused the launcher to remain key after
            // Cmd+Tab, silently eating all keyboard input (space, arrows) in the user's app.
            self.hideLauncher()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === launcherWindow else { return }
        NotificationCenter.default.post(name: .focusSearchField, object: nil)
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Do not hide on Space/full-screen switches. `windowDidResignKey` handles real outside clicks.
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
        }
    }

    func registerGlobalHotkey() {
        // Use Carbon API for reliable global hotkey registration
        // Use settings for keyCode and modifiers

        let hotKeyID = EventHotKeyID(signature: FourCharCode(bitPattern: 0x494C_6E63), id: 1)  // 'ILnc'

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))

        // Install event handler
        let handler: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
            guard let appDelegate = userData?.assumingMemoryBound(to: AppDelegate.self).pointee
            else {
                return noErr
            }
            appDelegate.toggleLauncher()
            return noErr
        }

        var selfPointer = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        selfPointer.initialize(to: self)

        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType, selfPointer, &eventHandler)

        // Register the hotkey using settings
        let status = RegisterEventHotKey(
            settings.hotkeyKeyCode,
            settings.hotkeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            #if DEBUG
            print("Failed to register global hotkey: \(status)")
            #endif
        } else {
            #if DEBUG
            print("Successfully registered global hotkey: \(settings.hotkeyDisplayString)")
            #endif
        }
        // Always add NSEvent monitor as belt-and-suspenders alongside Carbon
        // (Carbon alone can be unreliable on macOS 14+ for accessory apps)
        fallbackToNSEventMonitoring()
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
        let handler: EventHandlerUPP = { (_, _, userData) -> OSStatus in
            guard let delegate = userData?.assumingMemoryBound(to: AppDelegate.self).pointee else {
                return noErr
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
        guard settings.useDoubleOptionLaunch else { return }

        let cancelOptionTap: () -> Void = { [weak self] in
            guard let self else { return }
            self.optionTapContaminated = true
            self.lastOptionPressTime = 0
        }

        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let optionNow = flags.contains(.option)
            let extraModifiers = flags.intersection([.command, .control, .shift])

            if !extraModifiers.isEmpty {
                self.optionTapContaminated = true
                self.lastOptionPressTime = 0
                return
            }

            if optionNow && !self.optionKeyDown {
                self.optionKeyDown = true
                self.optionTapContaminated = false
                return
            }

            if !optionNow && self.optionKeyDown {
                self.optionKeyDown = false
                guard !self.optionTapContaminated else {
                    self.optionTapContaminated = false
                    return
                }

                let now = Date().timeIntervalSinceReferenceDate
                let gap = now - self.lastOptionPressTime
                if gap > 0.04 && gap < 0.40 {
                    self.lastOptionPressTime = 0
                    DispatchQueue.main.async { self.toggleLauncher() }
                } else {
                    self.lastOptionPressTime = now
                }
            } else if !optionNow {
                self.lastOptionPressTime = 0
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

    // Single Option press (alone, no other modifiers, from another app) → focus our search field.
    func registerSingleOptionFocusMonitor() {
        if let m = singleOptionFocusMonitor {
            NSEvent.removeMonitor(m)
            singleOptionFocusMonitor = nil
        }
        if let m = singleOptionLocalFocusMonitor {
            NSEvent.removeMonitor(m)
            singleOptionLocalFocusMonitor = nil
        }
        if let m = singleOptionCancelMonitor {
            NSEvent.removeMonitor(m)
            singleOptionCancelMonitor = nil
        }
        if let m = singleOptionLocalCancelMonitor {
            NSEvent.removeMonitor(m)
            singleOptionLocalCancelMonitor = nil
        }

        // Single Option only releases focus. Double Option remains launcher open.
        let toggleDockInputFocus: () -> Void = { [weak self] in
            guard let self else { return }
            guard let window = self.launcherWindow, window.isVisible else { return }
            DispatchQueue.main.async {
                if window.isKeyWindow {
                    // Dock has focus → give it back to the previous app
                    guard let app = self.previousFrontmostApp, !app.isTerminated else { return }
                    window.resignKey()
                    app.activate(options: [.activateIgnoringOtherApps])
                }
            }
        }

        // If any regular key fires while Option is held, the press is a modifier — cancel.
        singleOptionCancelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] _ in
            self?.optionAloneActive = false
        }
        singleOptionLocalCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.optionAloneActive = false
            return event
        }

        let handleFlagsChanged: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags
            let optionNow = flags.contains(.option)
            let extraMods = flags.intersection([.command, .control, .shift])

            if optionNow && !self.optionAloneActive && extraMods.isEmpty {
                // Option pressed alone — record
                self.optionAloneActive = true
                self.optionAloneDownTime = Date().timeIntervalSince1970
            } else if !optionNow && self.optionAloneActive {
                // Option released — check duration
                let duration = Date().timeIntervalSince1970 - self.optionAloneDownTime
                self.optionAloneActive = false
                guard duration > 0.05 && duration < 0.45 else { return }
                toggleDockInputFocus()
            } else if !optionNow {
                self.optionAloneActive = false
            }
        }

        singleOptionFocusMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            handleFlagsChanged($0)
        }
        singleOptionLocalFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            event in
            handleFlagsChanged(event)
            return event
        }
    }

    // Single Command press (alone, no other modifiers, no regular key) toggles scope.
    func registerSingleCommandGlobalContextMonitor() {
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

        let toggleDockScope: () -> Void = { [weak self] in
            guard let self else { return }
            guard self.settings.singleCommandTogglesContextScope else { return }
            DispatchQueue.main.async {
                if self.launcherWindow == nil {
                    self.setupLauncherWindow()
                }
                guard let window = self.launcherWindow else { return }
                if let currentApp = self.resolvedUserFacingApplication(NSWorkspace.shared.frontmostApplication) {
                    self.recordFrontmostApp(currentApp)
                }
                if !window.isVisible {
                    self.isDockContextMode = true
                    self.showLauncher()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NotificationCenter.default.post(name: .activateContextDock, object: nil)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        NotificationCenter.default.post(name: .focusSearchField, object: nil)
                    }
                    return
                }
                window.alphaValue = 1.0
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
                self.launcherWindow?.makeKey()
                NotificationCenter.default.post(name: .commandKeyToggleContextScope, object: nil)
            }
        }

        singleCommandCancelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] _ in
            self?.commandAloneActive = false
        }
        singleCommandLocalCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.commandAloneActive = false
            return event
        }

        let handleFlagsChanged: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags
            let commandNow = flags.contains(.command)
            let extraMods = flags.intersection([.option, .control, .shift])

            if commandNow && !self.commandAloneActive && extraMods.isEmpty {
                self.commandAloneActive = true
                self.commandAloneDownTime = Date().timeIntervalSince1970
            } else if !commandNow && self.commandAloneActive {
                let duration = Date().timeIntervalSince1970 - self.commandAloneDownTime
                self.commandAloneActive = false
                guard duration > 0.05 && duration < 0.45 else { return }
                toggleDockScope()
            } else if !commandNow {
                self.commandAloneActive = false
            }
        }

        singleCommandFocusMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            handleFlagsChanged($0)
        }
        singleCommandLocalFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            event in
            return event
        }
    }

    private func focusAndCenterPersistentDock() {
        guard let window = launcherWindow, window.isVisible else { return }
        let screen = window.screen ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            var frame = window.frame
            frame.origin.x = visibleFrame.midX - frame.width / 2
            if settings.alwaysFloatDock && !settings.effectiveDockAtBottom {
                frame.origin.y = visibleFrame.midY - frame.height / 2
                (window as? KeyableWindow)?.anchorAtBottom = false
            }
            window.setFrame(frame, display: false)
            (window as? KeyableWindow)?.horizontalResizeAnchorX = visibleFrame.midX
        }
        window.alphaValue = 1
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        self.launcherWindow?.makeKey()
    }

    func activateContextDock() {
        guard settings.enableLayer2 else { return }  // Layer 2 disabled — hotkey does nothing
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastHotkeyFiredAt > 0.15 else { return }
        lastHotkeyFiredAt = now
        DispatchQueue.main.async {
            if let window = self.launcherWindow, window.isVisible {
                if self.isDockContextMode {
                    // Already in dock context → close (toggle off)
                    self.isDockContextMode = false
                    self.hideLauncher()
                } else {
                    // Visible at L1 → switch to dock context instantly (no window hide/show)
                    self.isDockContextMode = true
                    NotificationCenter.default.post(name: .activateContextDock, object: nil)
                }
            } else {
                // Hidden → open directly in dock context mode
                self.isDockContextMode = true
                self.showLauncher()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(name: .activateContextDock, object: nil)
                }
            }
        }
    }

    func activateClipboardScope() {
        guard settings.enableLayer2 else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastHotkeyFiredAt > 0.15 else { return }
        lastHotkeyFiredAt = now
        presentSmartScope(.activateClipboardScope)
    }

    private func presentSmartScope(_ notificationName: Notification.Name) {
        smartScopeActivationGeneration &+= 1
        let generation = smartScopeActivationGeneration
        DispatchQueue.main.async {
            guard generation == self.smartScopeActivationGeneration else { return }
            if self.launcherWindow == nil {
                self.setupLauncherWindow()
            }
            self.isDockContextMode = true
            if let window = self.launcherWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                self.launcherWindow?.makeKey()
            } else {
                self.showLauncher()
            }
            DispatchQueue.main.async {
                guard generation == self.smartScopeActivationGeneration else { return }
                NotificationCenter.default.post(name: notificationName, object: nil)
            }
        }
    }

    func fallbackToNSEventMonitoring() {
        // Fallback: Monitor for hotkey using NSEvent (less reliable)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if self.matchesHotkey(event) {
                self.toggleLauncher()
            }
        }

        // Also monitor local events (when app is active)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self = self else { return event }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                switch event.keyCode {
                case 53:  // Escape
                    NotificationCenter.default.post(name: .escapePressed, object: nil)
                    return nil
                case 51:  // Delete / Backspace
                    NotificationCenter.default.post(name: .launcherBackspacePressed, object: nil)
                    return event
                default:
                    break
                }
            }
            // In .accessory mode the app menu isn't always active, so Cmd+A/C/V/X/Z won't
            // reach the system Edit menu. Route them directly to the focused text view here.
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                let key = event.characters?.lowercased()
            {
                let responder = NSApp.keyWindow?.firstResponder
                if responder is NSTextView || responder is NSTextField {
                    switch key {
                    case "a":
                        _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                        return nil
                    case "c":
                        _ = NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                        return nil
                    case "v":
                        _ = NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                        return nil
                    case "x":
                        _ = NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                        return nil
                    case "z":
                        _ = NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                        return nil
                    default: break
                    }
                }
            }
            // Skip main-launcher toggle if this key combo belongs to context dock hotkey
            if self.matchesContextDockHotkey(event) {
                return event
            }
            if self.matchesClipboardScopeHotkey(event) {
                return event
            }
            if self.matchesHotkey(event) {
                self.toggleLauncher()
                return nil  // Consume the event
            }
            return event
        }
    }

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

    func matchesContextDockHotkey(_ event: NSEvent) -> Bool {
        guard settings.contextDockHotkeyEnabled else { return false }
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        return UInt32(event.keyCode) == settings.contextDockHotkeyKeyCode
            && mods == settings.contextDockHotkeyModifiers
    }

    func matchesClipboardScopeHotkey(_ event: NSEvent) -> Bool {
        guard settings.clipboardScopeHotkeyEnabled else { return false }
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        return UInt32(event.keyCode) == settings.clipboardScopeHotkeyKeyCode
            && mods == settings.clipboardScopeHotkeyModifiers
    }

    func matchesHotkey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
        let keyCode = event.keyCode

        // Convert NSEvent modifiers to Carbon modifiers
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }

        return UInt32(keyCode) == settings.hotkeyKeyCode
            && carbonModifiers == settings.hotkeyModifiers
    }

    func toggleLauncher() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastHotkeyFiredAt > 0.15 else { return }
        lastHotkeyFiredAt = now
        DispatchQueue.main.async {
            if let window = self.launcherWindow {
                if window.isVisible {
                    // L1 has been removed; the main launcher hotkey now toggles L2 visibility.
                    self.isDockContextMode = false
                    self.hideLauncher(force: true)
                } else {
                    // Hidden → always open at L2.
                    self.isDockContextMode = true
                    self.showLauncher()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NotificationCenter.default.post(name: .activateContextDock, object: nil)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        NotificationCenter.default.post(name: .focusSearchField, object: nil)
                    }
                }
            } else {
                self.setupLauncherWindow()
                self.isDockContextMode = true
                self.showLauncher()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(name: .activateContextDock, object: nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    NotificationCenter.default.post(name: .focusSearchField, object: nil)
                }
            }
        }
    }

    func showLauncher() {
        guard let window = launcherWindow else { return }

        #if DEBUG
        print("🚀 [AppDelegate] ===== SHOW LAUNCHER CALLED =====")
        #endif
        isDockContextMode = true

        // Capture the CURRENT frontmost app RIGHT NOW before we show the window
        // This is the app the user was using when they pressed the hotkey
        if let currentApp = resolvedUserFacingApplication(NSWorkspace.shared.frontmostApplication) {
            recordFrontmostApp(currentApp)
            print(
                "📱 [AppDelegate] Captured frontmost app at hotkey press: \(currentApp.localizedName ?? "Unknown")"
            )
            // Immediately update LauncherView's frontmostAppName so the dock reflects the real app
            DispatchQueue.main.async {
                ContextDockEnvironment.shared.frontmostAppDidChange(
                    name: currentApp.localizedName ?? "",
                    bundleID: currentApp.bundleIdentifier ?? ""
                )
            }
        }

        // Do not block launcher open on context detection. The detector can touch AX,
        // AppleScript, browser state, PDFs and OCR; running that here freezes typing.
        #if DEBUG
        print("🔍 [AppDelegate] Scheduling context detection after launcher shows...")
        #endif
        scheduleUserContextDetection()

        // Center the window horizontally and position it based on user preference
        let activeScreen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? window.screen
            ?? NSScreen.main
        guard let activeScreen else { return }
        let screenFrame = activeScreen.visibleFrame
        let windowWidth: CGFloat = 700  // Increased from 600 to 700

        // Match calculatedHeight's idle formula exactly so updateWindowSize() fires a ≤1px
        // change and the guard inside skips it — prevents the visible post-open jump.
        let statusBarHeight: CGFloat = settings.enableStatusBar ? 45 : 0
        let initialHeight: CGFloat = statusBarHeight + 70  // statusBar + searchBar (matches calculatedHeight base case)

        let x = screenFrame.midX - (windowWidth / 2)

        // Position window based on "Always Dock at Bottom" setting
        let y: CGFloat
        if settings.effectiveDockAtBottom {
            // When "Always Dock at Bottom" is enabled, ALWAYS stay at bottom
            // Results will expand upward, dock stays fixed
            y = screenFrame.minY + 10  // 10px from bottom - FIXED position
            // Enable bottom anchoring so window grows upward
            if let keyableWindow = window as? KeyableWindow {
                keyableWindow.anchorAtBottom = true
            }
            applyPersistentDockBehavior()
            print(
                "📍 [AppDelegate] Positioning window at BOTTOM (y: \(y)) - Anchor: BOTTOM (stays fixed, results expand upward)"
            )
        } else if settings.alwaysFloatDock {
            // Always Float Dock should remain persistent, but launch centered like a
            // floating command surface instead of inheriting a bottom/corner dock pose.
            y = screenFrame.midY - (initialHeight / 2)
            if let keyableWindow = window as? KeyableWindow {
                keyableWindow.anchorAtBottom = false
            }
            #if DEBUG
            print("📍 [AppDelegate] Positioning always-float window at CENTER (y: \(y))")
            #endif
        } else {
            // Default: upper third of screen
            y = screenFrame.maxY - screenFrame.height / 3
            // Disable bottom anchoring (normal behavior)
            if let keyableWindow = window as? KeyableWindow {
                keyableWindow.anchorAtBottom = false
            }
            #if DEBUG
            print("📍 [AppDelegate] Positioning window at TOP (y: \(y)) - Anchor: TOP")
            #endif
        }

        let initialFrame = NSRect(x: x, y: y, width: windowWidth, height: initialHeight)
        if let keyableWindow = window as? KeyableWindow {
            keyableWindow.horizontalResizeAnchorX = initialFrame.midX
        }
        #if DEBUG
        print("📐 [AppDelegate] Setting initial frame: \(initialFrame)")
        #endif
        #if DEBUG
        print("📐 [AppDelegate] Screen frame: \(screenFrame)")
        #endif
        // Use display: false — window is off-screen; no need to force a render pass here.
        window.setFrame(initialFrame, display: false)
        #if DEBUG
        print("📐 [AppDelegate] Actual window frame after setFrame: \(window.frame)")
        #endif

        window.alphaValue = 0

        window.orderFrontRegardless()
        window.makeKey()
        window.acceptsMouseMovedEvents = true
        self.launcherWindow?.makeKey()

        // Reset content state now that the window is key and the app is active.
        // The window is still alpha=0 at this point, so stale content is not visible.
        // Posting here (after makeKey) ensures NSApp.keyWindow is correct when
        // updateWindowSize() fires its 10ms-delayed check inside the handler.
        NotificationCenter.default.post(name: .launcherWindowOpened, object: nil, userInfo: nil)
        NotificationCenter.default.post(name: .activateContextDock, object: nil)

        // Fade only. Resizing the window while NSVisualEffectView is initializing changes
        // the sampled wallpaper region and makes the dock glass tint drift on launch.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }

        #if DEBUG
        print("✅ [AppDelegate] Window is now visible and key")
        #endif
        #if DEBUG
        print("🚀 [AppDelegate] ===== SHOW LAUNCHER COMPLETED =====")
        #endif
    }

    func hideLauncher(force: Bool = false) {
        WebQuickLookPanel.shared.close()
        guard let window = launcherWindow else { return }
        // Pinned: stay floating over every app — even after actions run. Only a
        // forced hide (Escape / hotkey toggle) dismisses, which also unpins.
        if !force && settings.launcherPinned {
            window.orderFrontRegardless()
            return
        }
        if force { settings.launcherPinned = false }
        if !force && (settings.alwaysFloatDock || settings.effectiveDockAtBottom) {
            window.alphaValue = 1
            applyPersistentDockBehavior()
            window.orderFrontRegardless()
            NotificationCenter.default.post(name: .focusSearchField, object: nil)
            return
        }
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            },
            completionHandler: {
                window.acceptsMouseMovedEvents = false
                window.orderOut(nil)
                window.alphaValue = 1  // reset for next show
            })
    }

    // Detect and store user context BEFORE launcher window opens
    // This captures selected files, text, and frontmost app info
    private func scheduleUserContextDetection() {
        let capturedApp = previousFrontmostApp
        DispatchQueue.global(qos: .userInitiated).async {
            let context = UserContextDetector.shared.detectCurrentContext(from: capturedApp)
            DispatchQueue.main.async {
                #if DEBUG
                print("🔍 [AppDelegate] ========================================")
                #endif
                #if DEBUG
                print("🔍 [AppDelegate] DETECTING USER CONTEXT (ASYNC)")
                #endif
                if let app = capturedApp {
                    print(
                        "🎯 [AppDelegate] Using PREVIOUS frontmost app: \(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "unknown"))"
                    )
                } else {
                    #if DEBUG
                    print("⚠️ [AppDelegate] No previous frontmost app stored!")
                    #endif
                }
                #if DEBUG
                print("📊 [AppDelegate] Detection completed!")
                #endif
                #if DEBUG
                print("📊 [AppDelegate] Detected context: \(context.description)")
                #endif
                #if DEBUG
                print("📤 [AppDelegate] Delivering context to ContextDockEnvironment...")
                #endif
                ContextDockEnvironment.shared.userContextDidDetect(context)
                #if DEBUG
                print("✅ [AppDelegate] Context delivered successfully")
                #endif
                #if DEBUG
                print("🔍 [AppDelegate] ========================================")
                #endif
            }
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

        // Initialize with current frontmost app
        if let currentApp = resolvedUserFacingApplication(NSWorkspace.shared.frontmostApplication) {
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

        // Only track user-facing non-DoraX apps. Resolve helper processes (ChatGPT helper, etc.)
        // back to their owning .app before pushing context into LauncherView.
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
