//
//  ILauncherApp.swift
//  ILauncher
//
//  Created by Krishgokul on 20/11/2025.
//

import SwiftUI
import AppKit
import Carbon

// Custom NSHostingView that can accept first responder and has a transparent background
class FocusableHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Make hosting view layer transparent so GlassBackground shows through
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
    }
}

// Custom NSWindow that can become key window and is draggable
class KeyableWindow: NSWindow {
    // Flag to anchor window at bottom when expanding
    var anchorAtBottom: Bool = false
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
              let initialOrigin = initialWindowOrigin else {
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

            print("🔧 [KeyableWindow] setFrame: Height: \(adjustedFrame.height), Anchoring bottom at Y: \(desiredBottomY)")
        }

        super.setFrame(adjustedFrame, display: flag)
    }

    // Ensure standard text-editing keyboard shortcuts (Cmd+A/V/C/X/Z) always reach the
    // focused SwiftUI TextField. In .accessory policy mode the main menu isn't always
    // the active menu, so macOS doesn't automatically route these key equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.characters?.lowercased() else { return false }
        switch key {
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)),     to: nil, from: nil)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)),      to: nil, from: nil)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)),       to: nil, from: nil)
        case "z": return NSApp.sendAction(Selector(("undo:")),             to: nil, from: nil)
        case ",":
            AppDelegate.shared?.showSettings()
            return true
        default:  return false
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
    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        var adjustedFrame = frameRect

        if anchorAtBottom, let screen = self.screen ?? NSScreen.main {
            // When anchored at bottom, calculate the Y position to keep bottom fixed
            let screenFrame = screen.visibleFrame
            let desiredBottomY = screenFrame.minY + bottomAnchorY

            // Set Y so that window bottom stays at desired position
            adjustedFrame.origin.y = desiredBottomY

            print("🔧 [KeyableWindow] setFrame(animate): Height: \(adjustedFrame.height), Anchoring bottom at Y: \(desiredBottomY)")
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
    var hotKeyRef: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var contextDockHotKeyRef: EventHotKeyRef?
    var clipboardScopeHotKeyRef: EventHotKeyRef?
    var lastHotkeyFiredAt: TimeInterval = 0
    var doubleOptionMonitor: Any?
    var doubleOptionLocalMonitor: Any?
    var lastOptionPressTime: TimeInterval = 0
    var optionKeyDown = false
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
    var persistentDockModifierMonitor: Any?
    var persistentDockModifierLocalMonitor: Any?
    var persistentDockModifierActive: Bool = false
    /// True when the launcher was opened / switched via the context-dock shortcut.
    /// ContentView reads this on `launcherWindowOpened` to keep the app in L2.
    var isDockContextMode: Bool = false
    let settings = AppSettings.shared

    // Store the previously frontmost app for context detection
    var previousFrontmostApp: NSRunningApplication?

    // Finder selection observer — powers the FileContextOverlay (files/folders)
    private let finderSelectionObserver = AXSelectionObserver()

    // Text selection monitor — powers the FileContextOverlay (text/URL in any app)
    private let textSelectionMonitor = TextSelectionMonitor()

    // Recent app history — last 5 apps the user was in (excluding ILauncher)
    private(set) var recentApps: [NSRunningApplication] = []
    private let maxRecentApps = 5

    /// Record an app as the current frontmost — updates both previousFrontmostApp and recentApps.
    /// Replaces recentApps with the authoritative list from the Apple menu "Recent Items".
    /// Called after liveMenuItems loads so the NL cross-app handler uses accurate data.
    func setRecentAppsFromMenu(_ apps: [NSRunningApplication]) {
        recentApps = apps
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

    // Settings window size protection
    private var settingsResizeObserver: NSObjectProtocol?
    private var settingsEndLiveResizeObserver: NSObjectProtocol?
    private var settingsCloseObserver: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self   // Register global reference
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

        // Create the launcher window
        setupLauncherWindow()

        // Register global hotkeys
        registerGlobalHotkey()
        registerContextDockHotkey()
        registerClipboardScopeHotkey()
        registerDoubleOptionMonitor()
        registerSingleOptionFocusMonitor()
        registerSingleCommandGlobalContextMonitor()
        registerPersistentDockModifierExpansionMonitor()

        // Setup notification observers for settings changes
        setupNotificationObservers()

        // Track frontmost app changes to capture context BEFORE ILauncher activates
        setupFrontmostAppTracking()

        // Start event-driven AX observer pipeline
        AXObserverManager.shared.startMonitoring()

        // Start binary watcher so L2 auto-discovers newly installed CLI tools
        Task { @MainActor in
            BinaryWatcherService.shared.startWatching()
            print("✅ [AppDelegate] Binary watcher started")

            // Scan once after packages have loaded to catch tools installed while app was closed.
            // skipHelpScan=true avoids spawning 100+ --help subprocesses at startup.
            // Help text is fetched lazily when the user taps "Add to L2".
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            await BinaryWatcherService.shared.scanNow(skipHelpScan: true)
            print("✅ [AppDelegate] Startup scan complete")
        }
    }
    
    func registerServicesProvider() {
        // Register the services provider with NSApp
        // This allows shortcuts to appear in the Services menu of all apps
        NSApp.servicesProvider = ServicesProvider.shared
        print("✅ [Services] Registered ServicesProvider")
    }
    
    func restoreSearchDirectoryAccess() {
        // Start accessing all saved search directories using their security-scoped bookmarks
        // This allows the app to access folders without prompting the user again
        settings.startAccessingSearchDirectories()
        print("📁 Restored access to \(settings.searchDirectories.count) search directories")
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

        // Track every app activation so recentApps stays current
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        recordFrontmostApp(app)
        // Menu cache is validated by bundleVersion inside AXMenuEnumerator — no manual invalidation needed.
    }
    
    @objc func handleServicesOpenWithFiles(_ notification: Notification) {
        print("🔧 [AppDelegate] Received servicesOpenWithFiles notification")
        // Show launcher - the ContentView will handle the context
        showLauncher()
    }
    
    @objc func handleServicesOpenWithText(_ notification: Notification) {
        print("🔧 [AppDelegate] Received servicesOpenWithText notification")
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

    func setupApplicationMenu() {
        // Setup main menu bar to enable keyboard shortcuts even when status bar icon is hidden
        let mainMenu = NSMenu()
        
        // App menu (ILauncher menu)
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        
        appMenu.addItem(NSMenuItem(title: "About ILauncher", action: nil, keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Hide ILauncher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit ILauncher", action: #selector(quitApp), keyEquivalent: "q"))
        
        mainMenu.addItem(appMenuItem)
        
        // Edit menu (enables Copy, Paste, Cut, Select All in text fields)
        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        
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
        registerDoubleOptionMonitor()
        registerSingleCommandGlobalContextMonitor()
        registerPersistentDockModifierExpansionMonitor()
    }
    
    func setupMenuBar() {
        // Only setup if showMenuBarIcon is true
        guard settings.showMenuBarIcon else { return }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Context-Dock")
        }
        
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Show Launcher (\(settings.hotkeyDisplayString))", action: #selector(showLauncherFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit ILauncher", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
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

        let fixedW: CGFloat = 920
        let fixedH: CGFloat = 680
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: (screenFrame.midX - fixedW / 2).rounded(),
            y: (screenFrame.midY - fixedH / 2).rounded(),
            width: fixedW,
            height: fixedH
        )

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Context-Dock Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: fixedW, height: fixedH)
        window.maxSize = NSSize(width: fixedW, height: fixedH)
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    
    /// Finds the settings window, sizes it to 80% of the screen, and installs a persistent
    /// Makes the settings window a fixed, non-resizable size centered on screen.
    private func applySettingsWindowSize() {
        guard let screen = NSScreen.main else { return }
        let win: NSWindow? = NSApp.windows.first(where: {
            $0.title.contains("Settings") || $0.title.contains("Preferences")
        }) ?? NSApp.windows.first(where: {
            $0 !== self.launcherWindow && $0.styleMask.contains(.titled) && $0.isVisible
        })
        guard let win else { return }

        let fixedW: CGFloat = 920
        let fixedH: CGFloat = 680
        let sf = screen.visibleFrame
        let x = (sf.origin.x + (sf.width  - fixedW) / 2).rounded()
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
        if let obs = settingsResizeObserver        { NotificationCenter.default.removeObserver(obs); settingsResizeObserver = nil }
        if let obs = settingsEndLiveResizeObserver { NotificationCenter.default.removeObserver(obs); settingsEndLiveResizeObserver = nil }
        if let obs = settingsCloseObserver         { NotificationCenter.default.removeObserver(obs); settingsCloseObserver = nil }

        // Restore resizable on close so other windows aren't affected
        settingsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak win, weak self] _ in
            win?.styleMask.insert(.resizable)
            if let obs = self?.settingsCloseObserver { NotificationCenter.default.removeObserver(obs); self?.settingsCloseObserver = nil }
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func checkAccessibilityPermissions() {
        // Check without prompting first - this is the actual permission state
        let accessEnabled = AXIsProcessTrusted()
        
        if !accessEnabled {
            // Only prompt if permissions are not granted
            // Use the prompt option to show the system dialog
            let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [checkOptPrompt: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            
            print("⚠️ Accessibility permissions not granted - system prompt shown")
        } else {
            print("✅ Accessibility permissions already granted")
        }
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
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    func setupLauncherWindow() {
        let contentView = LauncherView(onClose: {
            self.hideLauncher()
        })
        .environmentObject(ContextDockEnvironment.shared)

        launcherWindow = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 60),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        // FocusableHostingView directly as contentView (original working approach)
        let hostingView = FocusableHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]

        launcherWindow?.contentView = hostingView
        launcherWindow?.backgroundColor = .clear
        launcherWindow?.isOpaque = false
        launcherWindow?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        launcherWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        launcherWindow?.isMovableByWindowBackground = true
        launcherWindow?.hasShadow = false
        launcherWindow?.delegate = self
        launcherWindow?.ignoresMouseEvents = false
        launcherWindow?.hidesOnDeactivate = false
        // Persistent context dock: window stays visible + joins all spaces
        applyPersistentDockBehavior()
        launcherWindow?.acceptsMouseMovedEvents = true

        // Set min/max size for resizing
        launcherWindow?.minSize = NSSize(width: 400, height: 60)
        launcherWindow?.maxSize = NSSize(width: 1200, height: 1000)

        // Show resize indicator
        launcherWindow?.showsResizeIndicator = true

        // Apply transparency and appearance from settings
        applyLauncherWindowOpacity()
        applyAppearanceOverride()

        // Observe opacity changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(opacitySettingChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc func opacitySettingChanged() {
        // UserDefaults.didChangeNotification can fire on any thread — always dispatch to main
        DispatchQueue.main.async { [weak self] in
            self?.applyLauncherWindowOpacity()
            self?.applyAppearanceOverride()
            self?.applyPersistentDockBehavior()
        }
    }

    func applyLauncherWindowOpacity() {
        // Keep the window fully opaque — opacity is applied only to GlassBackground
        // so pills, icons, and input fields remain crisp regardless of the slider.
        launcherWindow?.alphaValue = 1.0
    }

    func applyPersistentDockBehavior() {
        guard let window = launcherWindow else { return }
        let settings = AppSettings.shared
        if settings.persistentContextDock {
            // NSStatusWindowLevel floats above ALL app windows, Dock, and Spaces
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isMovableByWindowBackground = false
            // Anchor at bottom so chat/results grow UPWARD, not downward
            if let kw = window as? KeyableWindow { kw.anchorAtBottom = true }
            // Position at bottom center
            if let screen = NSScreen.main {
                let sw = screen.visibleFrame.width
                let ww: CGFloat = 700
                let minHeight: CGFloat = (settings.enableStatusBar ? 45 : 0) + 70
                let height = max(window.frame.height, minHeight)
                let x = screen.visibleFrame.minX + (sw - ww) / 2
                let y = screen.visibleFrame.minY + 10
                window.setFrame(NSRect(x: x, y: y, width: ww, height: height), display: false)
            }
            // Make sure it's always visible
            window.orderFrontRegardless()
            // Set up auto-hide mouse tracking if enabled
            if settings.persistentContextDockAutoHide {
                setupPersistentDockAutoHide()
            } else {
                removePersistentDockAutoHide()
                window.alphaValue = 1
            }
        } else {
            // Restore normal behavior
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
            window.isMovableByWindowBackground = true
            removePersistentDockAutoHide()
        }
    }

    private var autoHideMonitor: Any?
    private var autoHideTimer: Timer?

    func setupPersistentDockAutoHide() {
        removePersistentDockAutoHide()
        guard let screen = NSScreen.main else { return }
        let screenBottom = screen.frame.minY
        let triggerZone: CGFloat = 5   // px from bottom edge
        launcherWindow?.alphaValue = 0  // start hidden

        autoHideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self = self, let window = self.launcherWindow else { return }
            let mouse = NSEvent.mouseLocation
            if mouse.y <= screenBottom + triggerZone {
                // Mouse near bottom — show dock
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    window.animator().alphaValue = 1
                }
            } else if mouse.y > screenBottom + 80 {
                // Mouse moved away — hide dock
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    window.animator().alphaValue = 0
                }
            }
        }
    }

    func removePersistentDockAutoHide() {
        if let m = autoHideMonitor { NSEvent.removeMonitor(m); autoHideMonitor = nil }
        autoHideTimer?.invalidate(); autoHideTimer = nil
    }

    /// Sets the NSVisualEffectView material based on user appearance preference
    func applyVisualEffectMaterial(to ve: NSVisualEffectView) {
        switch settings.appearanceMode {
        case "light":
            ve.material = .underWindowBackground
            ve.appearance = NSAppearance(named: .aqua)
        case "dark":
            ve.material = .underWindowBackground
            ve.appearance = NSAppearance(named: .darkAqua)
        default: // "system"
            ve.material = .underWindowBackground
            ve.appearance = nil // follows system
        }
    }

    /// Overrides window appearance (light/dark/system) and applies rounded corners
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
        // Rounded corners — apply to the visual effect view layer
        if let ve = window.contentView as? NSVisualEffectView {
            ve.layer?.cornerRadius = 16
            ve.layer?.masksToBounds = true
        }
    }
    
    // Handle window losing focus
    func windowDidResignKey(_ notification: Notification) {
        // Don't hide launcher when it loses focus (like Spotlight/Raycast)
        // Only hide on hotkey press or explicit close action
        // This allows buttons and interactions to work without closing the window
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
        }
    }
    
    func registerGlobalHotkey() {
        // Use Carbon API for reliable global hotkey registration
        // Use settings for keyCode and modifiers
        
        let hotKeyID = EventHotKeyID(signature: FourCharCode(bitPattern: 0x494C6E63), id: 1) // 'ILnc'
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        
        // Install event handler
        let handler: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
            guard let appDelegate = userData?.assumingMemoryBound(to: AppDelegate.self).pointee else {
                return noErr
            }
            appDelegate.toggleLauncher()
            return noErr
        }
        
        var selfPointer = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        selfPointer.initialize(to: self)
        
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPointer, &eventHandler)
        
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
            print("Failed to register global hotkey: \(status)")
        } else {
            print("Successfully registered global hotkey: \(settings.hotkeyDisplayString)")
        }
        // Always add NSEvent monitor as belt-and-suspenders alongside Carbon
        // (Carbon alone can be unreliable on macOS 14+ for accessory apps)
        fallbackToNSEventMonitoring()
    }
    
    func unregisterGlobalHotkey() {
        // Unregister Carbon hotkey
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
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
        if let monitor = persistentDockModifierMonitor {
            NSEvent.removeMonitor(monitor)
            persistentDockModifierMonitor = nil
        }
        if let monitor = persistentDockModifierLocalMonitor {
            NSEvent.removeMonitor(monitor)
            persistentDockModifierLocalMonitor = nil
        }
    }

    func registerContextDockHotkey() {
        if let ref = contextDockHotKeyRef { UnregisterEventHotKey(ref); contextDockHotKeyRef = nil }
        guard settings.contextDockHotkeyEnabled else { return }
        let hotKeyID = EventHotKeyID(signature: FourCharCode(bitPattern: 0x494C6364), id: 2) // 'ILcd'
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, theEvent, userData) -> OSStatus in
            guard let delegate = userData?.assumingMemoryBound(to: AppDelegate.self).pointee else { return noErr }
            delegate.activateContextDock()
            return noErr
        }
        var selfPtr = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        selfPtr.initialize(to: self)
        var handlerRef: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &handlerRef)
        RegisterEventHotKey(settings.contextDockHotkeyKeyCode, settings.contextDockHotkeyModifiers,
                            hotKeyID, GetApplicationEventTarget(), 0, &contextDockHotKeyRef)
    }

    func registerClipboardScopeHotkey() {
        if let ref = clipboardScopeHotKeyRef { UnregisterEventHotKey(ref); clipboardScopeHotKeyRef = nil }
        guard settings.clipboardScopeHotkeyEnabled else { return }
        let hotKeyID = EventHotKeyID(signature: FourCharCode(bitPattern: 0x494C636C), id: 3) // 'ILcl'
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, _, userData) -> OSStatus in
            guard let delegate = userData?.assumingMemoryBound(to: AppDelegate.self).pointee else { return noErr }
            delegate.activateClipboardScope()
            return noErr
        }
        var selfPtr = UnsafeMutablePointer<AppDelegate>.allocate(capacity: 1)
        selfPtr.initialize(to: self)
        var handlerRef: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &handlerRef)
        RegisterEventHotKey(settings.clipboardScopeHotkeyKeyCode, settings.clipboardScopeHotkeyModifiers,
                            hotKeyID, GetApplicationEventTarget(), 0, &clipboardScopeHotKeyRef)
    }

    func registerDoubleOptionMonitor() {
        if let m = doubleOptionMonitor { NSEvent.removeMonitor(m); doubleOptionMonitor = nil }
        if let m = doubleOptionLocalMonitor { NSEvent.removeMonitor(m); doubleOptionLocalMonitor = nil }
        guard settings.useDoubleOptionLaunch else { return }

        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags
            let optionNow = flags.contains(.option)
            // Ignore presses that combine Option with Cmd / Ctrl / Shift
            let extraModifiers = flags.intersection([.command, .control, .shift])
            if !extraModifiers.isEmpty {
                self.optionKeyDown = false
                return
            }
            if optionNow && !self.optionKeyDown {
                let now = Date().timeIntervalSince1970
                let gap = now - self.lastOptionPressTime
                if gap > 0.04 && gap < 0.40 {
                    DispatchQueue.main.async { self.toggleLauncher() }
                }
                self.lastOptionPressTime = now
                self.optionKeyDown = true
            } else if !optionNow {
                self.optionKeyDown = false
            }
        }

        // Global: fires when another app is frontmost
        doubleOptionMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { handle($0) }
        // Local: fires when our own window is frontmost (launcher is visible)
        doubleOptionLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event); return event
        }
    }

    // Single Option press (alone, no other modifiers, from another app) → focus our search field.
    func registerSingleOptionFocusMonitor() {
        if let m = singleOptionFocusMonitor  { NSEvent.removeMonitor(m); singleOptionFocusMonitor  = nil }
        if let m = singleOptionLocalFocusMonitor  { NSEvent.removeMonitor(m); singleOptionLocalFocusMonitor  = nil }
        if let m = singleOptionCancelMonitor { NSEvent.removeMonitor(m); singleOptionCancelMonitor = nil }
        if let m = singleOptionLocalCancelMonitor { NSEvent.removeMonitor(m); singleOptionLocalCancelMonitor = nil }

        // Single Option — three-state toggle:
        //   Dock hidden          → do nothing (double-press only to open)
        //   Dock visible, key    → resign key + return focus to previous app (dock stays)
        //   Dock visible, not key → bring dock to front and focus the search field
        let toggleDockInputFocus: () -> Void = { [weak self] in
            guard let self else { return }
            guard let window = self.launcherWindow, window.isVisible else { return }
            DispatchQueue.main.async {
                if window.isKeyWindow {
                    // Dock has focus → give it back to the previous app
                    guard let app = self.previousFrontmostApp, !app.isTerminated else { return }
                    window.resignKey()
                    app.activate(options: [.activateIgnoringOtherApps])
                } else {
                    // Dock is visible but not focused → re-focus the search field
                    if let currentApp = NSWorkspace.shared.frontmostApplication,
                       currentApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                        self.recordFrontmostApp(currentApp)
                    }
                    window.alphaValue = 1.0
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                        NotificationCenter.default.post(name: .focusSearchField, object: nil)
                    }
                }
            }
        }

        // If any regular key fires while Option is held, the press is a modifier — cancel.
        singleOptionCancelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.optionAloneActive = false
        }
        singleOptionLocalCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.optionAloneActive = false
            return event
        }

        let handleFlagsChanged: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags
            let optionNow = flags.contains(.option)
            let extraMods  = flags.intersection([.command, .control, .shift])

            if optionNow && !self.optionAloneActive && extraMods.isEmpty {
                // Option pressed alone — record
                self.optionAloneActive    = true
                self.optionAloneDownTime  = Date().timeIntervalSince1970
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
        singleOptionLocalFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
            return event
        }
    }

    // Single Command press (alone, no other modifiers, no regular key) → Global Context.
    func registerSingleCommandGlobalContextMonitor() {
        if let m = singleCommandFocusMonitor { NSEvent.removeMonitor(m); singleCommandFocusMonitor = nil }
        if let m = singleCommandLocalFocusMonitor { NSEvent.removeMonitor(m); singleCommandLocalFocusMonitor = nil }
        if let m = singleCommandCancelMonitor { NSEvent.removeMonitor(m); singleCommandCancelMonitor = nil }
        if let m = singleCommandLocalCancelMonitor { NSEvent.removeMonitor(m); singleCommandLocalCancelMonitor = nil }

        let activateGlobalContext: () -> Void = { [weak self] in
            guard let self else { return }
            guard let window = self.launcherWindow, window.isVisible else { return }
            DispatchQueue.main.async {
                if let currentApp = NSWorkspace.shared.frontmostApplication,
                   currentApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self.recordFrontmostApp(currentApp)
                }
                window.alphaValue = 1.0
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .activateGlobalContext, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    NotificationCenter.default.post(name: .focusSearchField, object: nil)
                }
            }
        }

        singleCommandCancelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.commandAloneActive = false
        }
        singleCommandLocalCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
                activateGlobalContext()
            } else if !commandNow {
                self.commandAloneActive = false
            }
        }

        singleCommandFocusMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            handleFlagsChanged($0)
        }
        singleCommandLocalFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
            return event
        }
    }

    func registerPersistentDockModifierExpansionMonitor() {
        if let m = persistentDockModifierMonitor {
            NSEvent.removeMonitor(m)
            persistentDockModifierMonitor = nil
        }
        if let m = persistentDockModifierLocalMonitor {
            NSEvent.removeMonitor(m)
            persistentDockModifierLocalMonitor = nil
        }

        persistentDockModifierActive = false

        let handleFlagsChanged: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let active = flags.contains(.command) || flags.contains(.option)
            guard active != self.persistentDockModifierActive else { return }

            self.persistentDockModifierActive = active
            guard self.settings.persistentContextDock else { return }
            NotificationCenter.default.post(
                name: .persistentDockModifierExpansionChanged,
                object: nil,
                userInfo: ["isDown": active]
            )
        }

        persistentDockModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            handleFlagsChanged($0)
        }
        persistentDockModifierLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
            return event
        }
    }

    func activateContextDock() {
        guard settings.enableLayer2 else { return } // Layer 2 disabled — hotkey does nothing
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
        DispatchQueue.main.async {
            if let window = self.launcherWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .activateClipboardScope, object: nil)
            } else {
                self.isDockContextMode = true
                self.showLauncher()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(name: .activateClipboardScope, object: nil)
                }
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
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                switch event.keyCode {
                case 53: // Escape
                    NotificationCenter.default.post(name: .escapePressed, object: nil)
                    return nil
                case 51: // Delete / Backspace
                    NotificationCenter.default.post(name: .launcherBackspacePressed, object: nil)
                    return event
                default:
                    break
                }
            }
            // In .accessory mode the app menu isn't always active, so Cmd+A/C/V/X/Z won't
            // reach the system Edit menu. Route them directly to the focused text view here.
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               let key = event.characters?.lowercased() {
                let responder = NSApp.keyWindow?.firstResponder
                if responder is NSTextView || responder is NSTextField {
                    switch key {
                    case "a": _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil); return nil
                    case "c": _ = NSApp.sendAction(#selector(NSText.copy(_:)),      to: nil, from: nil); return nil
                    case "v": _ = NSApp.sendAction(#selector(NSText.paste(_:)),     to: nil, from: nil); return nil
                    case "x": _ = NSApp.sendAction(#selector(NSText.cut(_:)),       to: nil, from: nil); return nil
                    case "z": _ = NSApp.sendAction(Selector(("undo:")),             to: nil, from: nil); return nil
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
                return nil // Consume the event
            }
            return event
        }
    }

    func matchesContextDockHotkey(_ event: NSEvent) -> Bool {
        guard settings.contextDockHotkeyEnabled else { return false }
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option)  { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return UInt32(event.keyCode) == settings.contextDockHotkeyKeyCode && mods == settings.contextDockHotkeyModifiers
    }

    func matchesClipboardScopeHotkey(_ event: NSEvent) -> Bool {
        guard settings.clipboardScopeHotkeyEnabled else { return false }
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option)  { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return UInt32(event.keyCode) == settings.clipboardScopeHotkeyKeyCode && mods == settings.clipboardScopeHotkeyModifiers
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
        
        return UInt32(keyCode) == settings.hotkeyKeyCode && carbonModifiers == settings.hotkeyModifiers
    }
    
    func toggleLauncher() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastHotkeyFiredAt > 0.15 else { return }
        lastHotkeyFiredAt = now
        DispatchQueue.main.async {
            // In persistent context dock mode, Option+Space should always recover the dock.
            // Carbon and NSEvent fallback monitors can both fire for one keypress; the
            // debounce above prevents a show-then-resign double toggle.
            if AppSettings.shared.persistentContextDock {
                self.restorePersistentLauncherWindow()
                return
            }

            if let window = self.launcherWindow {
                if window.isVisible {
                    // L1 has been removed; the main launcher hotkey now toggles L2 visibility.
                    self.isDockContextMode = false
                    self.hideLauncher()
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

    private func restorePersistentLauncherWindow() {
        if launcherWindow == nil {
            setupLauncherWindow()
        }

        guard let window = launcherWindow else { return }

        isDockContextMode = true

        if !window.isVisible {
            showLauncher()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NotificationCenter.default.post(name: .activateContextDock, object: nil)
            }
            return
        }

        applyPersistentDockBehavior()

        // Auto-hide can leave the persistent window at alphaValue 0 — restore it fully.
        window.alphaValue = 1.0
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.post(name: .launcherWindowOpened, object: nil, userInfo: nil)
        NotificationCenter.default.post(name: .activateContextDock, object: nil)
    }
    
    func showLauncher() {
        guard let window = launcherWindow, let screen = NSScreen.main else { return }

        print("🚀 [AppDelegate] ===== SHOW LAUNCHER CALLED =====")
        isDockContextMode = true

        // Capture the CURRENT frontmost app RIGHT NOW before we show the window
        // This is the app the user was using when they pressed the hotkey
        if let currentApp = NSWorkspace.shared.frontmostApplication,
           currentApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            recordFrontmostApp(currentApp)
            print("📱 [AppDelegate] Captured frontmost app at hotkey press: \(currentApp.localizedName ?? "Unknown")")
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
        print("🔍 [AppDelegate] Scheduling context detection after launcher shows...")
        scheduleUserContextDetection()
        
        // Center the window horizontally and position it based on user preference
        let screenFrame = screen.visibleFrame
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
            // Float above ALL application windows — same level as macOS status-bar extras
            if !settings.persistentContextDock {
                window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            }
            print("📍 [AppDelegate] Positioning window at BOTTOM (y: \(y)) - Anchor: BOTTOM (stays fixed, results expand upward)")
        } else {
            // Default: upper third of screen
            y = screenFrame.maxY - screenFrame.height / 3
            // Disable bottom anchoring (normal behavior)
            if let keyableWindow = window as? KeyableWindow {
                keyableWindow.anchorAtBottom = false
            }
            print("📍 [AppDelegate] Positioning window at TOP (y: \(y)) - Anchor: TOP")
        }

        let initialFrame = NSRect(x: x, y: y, width: windowWidth, height: initialHeight)
        print("📐 [AppDelegate] Setting initial frame: \(initialFrame)")
        print("📐 [AppDelegate] Screen frame: \(screenFrame)")
        // Use display: false — window is off-screen; no need to force a render pass here.
        window.setFrame(initialFrame, display: false)
        print("📐 [AppDelegate] Actual window frame after setFrame: \(window.frame)")

        window.alphaValue = 0

        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        // Reset content state now that the window is key and the app is active.
        // The window is still alpha=0 at this point, so stale content is not visible.
        // Posting here (after makeKey) ensures NSApp.keyWindow is correct when
        // updateWindowSize() fires its 10ms-delayed check inside the handler.
        NotificationCenter.default.post(name: .launcherWindowOpened, object: nil, userInfo: nil)
        NotificationCenter.default.post(name: .activateContextDock, object: nil)

        // Fade only. Resizing the window while NSVisualEffectView is initializing changes
        // the sampled wallpaper region and makes the dock glass tint drift on launch.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1.0)
            window.animator().alphaValue = 1.0
        }

        print("✅ [AppDelegate] Window is now visible and key")

        // Detect frontmost app asynchronously (don't block window showing)
        if settings.enableFrontmostDetection {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.detectAndStoreFrontmostApp()
            }
        }
        
        print("🚀 [AppDelegate] ===== SHOW LAUNCHER COMPLETED =====")
    }
    
    func hideLauncher() {
        // If persistent context dock is on, never fully hide — just resign key
        if AppSettings.shared.persistentContextDock {
            launcherWindow?.resignKey()
            return
        }
        guard let window = launcherWindow else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1   // reset for next show
        })
    }

    // Detect and store user context BEFORE launcher window opens
    // This captures selected files, text, and frontmost app info
    private func scheduleUserContextDetection() {
        let capturedApp = previousFrontmostApp
        DispatchQueue.global(qos: .userInitiated).async {
            let context = UserContextDetector.shared.detectCurrentContext(from: capturedApp)
            DispatchQueue.main.async {
                print("🔍 [AppDelegate] ========================================")
                print("🔍 [AppDelegate] DETECTING USER CONTEXT (ASYNC)")
                if let app = capturedApp {
                    print("🎯 [AppDelegate] Using PREVIOUS frontmost app: \(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "unknown"))")
                } else {
                    print("⚠️ [AppDelegate] No previous frontmost app stored!")
                }
                print("📊 [AppDelegate] Detection completed!")
                print("📊 [AppDelegate] Detected context: \(context.description)")
                print("📤 [AppDelegate] Delivering context to ContextDockEnvironment...")
                ContextDockEnvironment.shared.userContextDidDetect(context)
                print("✅ [AppDelegate] Context delivered successfully")
                print("🔍 [AppDelegate] ========================================")
            }
        }
    }

    private func detectAndStoreUserContextAsync() {
        print("🔍 [AppDelegate] ========================================")
        print("🔍 [AppDelegate] DETECTING USER CONTEXT (SYNC)")
        if let app = previousFrontmostApp {
            print("🎯 [AppDelegate] Using PREVIOUS frontmost app: \(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "unknown"))")
        } else {
            print("⚠️ [AppDelegate] No previous frontmost app stored!")
        }

        // Detect context SYNCHRONOUSLY so it's ready before window shows
        let context = UserContextDetector.shared.detectCurrentContext(from: previousFrontmostApp)

        print("📊 [AppDelegate] Detection completed!")
        print("📊 [AppDelegate] Detected context: \(context.description)")
        print("📤 [AppDelegate] Delivering context to ContextDockEnvironment...")

        ContextDockEnvironment.shared.userContextDidDetect(context)

        print("✅ [AppDelegate] Context delivered successfully")
        print("🔍 [AppDelegate] ========================================")
    }
    
    // Detect and store frontmost app info before ILauncher activates
    private func detectAndStoreFrontmostApp() {
        let script = """
        tell application "System Events"
            set frontApp to first application process whose frontmost is true
            set appName to name of frontApp
            set appBundleID to bundle identifier of frontApp
            return appName & "|" & appBundleID
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let output = scriptObject.executeAndReturnError(&error)

            if let result = output.stringValue, !result.isEmpty {
                let components = result.components(separatedBy: "|")
                if components.count == 2 {
                    let appName = components[0]
                    let bundleID = components[1]

                    // Skip if it's ILauncher itself
                    if bundleID != Bundle.main.bundleIdentifier {
                        DispatchQueue.main.async {
                            ContextDockEnvironment.shared.frontmostAppDidChange(name: appName, bundleID: bundleID)
                        }
                        print("🎯 Detected frontmost app BEFORE activation: \(appName) (\(bundleID))")
                    }
                }
            }
        }
    }

    // Track frontmost app changes to capture the previously active app
    func setupFrontmostAppTracking() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Initialize with current frontmost app
        if let currentApp = NSWorkspace.shared.frontmostApplication,
           currentApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            recordFrontmostApp(currentApp)
            print("📱 [AppDelegate] Initial frontmost app: \(currentApp.localizedName ?? "Unknown")")
        }
    }

    @objc func frontmostAppChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        // Only track non-ILauncher apps
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        recordFrontmostApp(app)
        print("📱 [AppDelegate] Frontmost app changed to: \(app.localizedName ?? "Unknown")")

        // File / text context overlay
        let pid = app.processIdentifier
        guard settings.enableFileContextOverlay else {
            finderSelectionObserver.stop()
            textSelectionMonitor.stop()
            Task { @MainActor in FileContextOverlayController.shared.hide() }
            return
        }

        if app.bundleIdentifier == "com.apple.finder" {
            // Finder: watch file/folder selection; position near mouse at selection time
            textSelectionMonitor.stop()
            finderSelectionObserver.start(for: pid, debounceInterval: 0.035)
            finderSelectionObserver.onChange = {
                Task { @MainActor in
                    let files = ContextDetector.shared.getFinderSelectedFiles()
                    let mousePt = NSEvent.mouseLocation
                    if files.isEmpty {
                        FileContextOverlayController.shared.updateFromClipboard(at: mousePt)
                    } else {
                        FileContextOverlayController.shared.update(files: files, at: mousePt)
                    }
                }
            }
        } else {
            // Any other app: watch text/URL selection via global mouse events + AX
            finderSelectionObserver.stop()
            Task { @MainActor in FileContextOverlayController.shared.hide() }
            textSelectionMonitor.start(for: pid)
            textSelectionMonitor.onChange = { text, mousePt in
                Task { @MainActor in
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        FileContextOverlayController.shared.updateFromClipboard(at: mousePt)
                    } else {
                        FileContextOverlayController.shared.update(text: text, at: mousePt)
                    }
                }
            }
        }
        Task.detached(priority: .background) {
            var items = AXMenuReader.shared.cachedAllMenuItems(for: pid, maxDepth: 6)
            for index in items.indices {
                items[index].sourcePID = pid
                items[index].sourceAppName = app.localizedName ?? ""
            }
            AppMenuCapabilityCache.shared.store(items: items, for: app)
        }

        // Browser windows are expensive AX trees. Do not eagerly crawl page text just
        // because a browser became frontmost; the dock warms that context on demand.
        if AXWebReader.shared.isBrowser(bundleId: app.bundleIdentifier ?? "") {
            AXWebReader.shared.invalidate(pid: pid)
        } else {
            // Not a browser — evict stale cache so memory doesn't grow
            AXWebReader.shared.invalidate(pid: pid)
        }

        // Notify LauncherView immediately so it can reload menu items for the new app
        DispatchQueue.main.async {
            ContextDockEnvironment.shared.frontmostAppDidChange(
                name: app.localizedName ?? "",
                bundleID: app.bundleIdentifier ?? ""
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop accessing security-scoped resources
        settings.stopAccessingSearchDirectories()

        // Unregister hotkeys and cleanup
        unregisterGlobalHotkey()

        // Remove notification observers
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
