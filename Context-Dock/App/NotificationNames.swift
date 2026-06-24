import Foundation

// Single source of truth for all NotificationCenter names used across the app.
// Grouped by the subsystem that owns the event.

extension Notification.Name {

    // MARK: - Window / launcher lifecycle
    static let launcherWindowOpened      = Notification.Name("launcherWindowOpened")
    static let escapePressed             = Notification.Name("escapePressed")
    static let launcherBackspacePressed  = Notification.Name("launcherBackspacePressed")
    static let focusSearchField          = Notification.Name("focusSearchField")
    static let folderPreviewShouldClose  = Notification.Name("folderPreviewShouldClose")

    // MARK: - Context / scope activation
    static let activateContextDock       = Notification.Name("activateContextDock")
    static let activateGlobalContext     = Notification.Name("activateGlobalContext")
    static let commandKeyToggleContextScope = Notification.Name("commandKeyToggleContextScope")
    static let activateClipboardScope    = Notification.Name("activateClipboardScope")
    static let switchToL1                = Notification.Name("switchToL1")
    static let toggleAIExtensions        = Notification.Name("toggleAIExtensions")

    // MARK: - App / context detection
    // NOTE: frontmostAppDetected and userContextDetected are declared here for
    // historic compatibility, but are no longer posted. AppDelegate now calls
    // ContextDockEnvironment.shared directly (see Services/ContextEngineProtocol.swift).
    static let frontmostAppDetected      = Notification.Name("frontmostAppDetected")
    static let userContextDetected       = Notification.Name("userContextDetected")

    // MARK: - Settings
    static let hotkeyChanged             = Notification.Name("hotkeyChanged")
    static let menuBarIconVisibilityChanged = Notification.Name("menuBarIconVisibilityChanged")
    static let chatHistoryCleared        = Notification.Name("chatHistoryCleared")
    static let settingsImported          = Notification.Name("settingsImported")

    // MARK: - Services / share sheet
    static let servicesFilesReceived     = Notification.Name("servicesFilesReceived")
    static let servicesTextReceived      = Notification.Name("servicesTextReceived")
    static let servicesURLReceived       = Notification.Name("servicesURLReceived")
    static let servicesOpenWithFiles     = Notification.Name("servicesOpenWithFiles")
    static let servicesOpenWithText      = Notification.Name("servicesOpenWithText")

    // MARK: - Tools / extensions
    static let appPanelToolRemoved       = Notification.Name("AppPanelToolRemoved")
    static let newBinaryDiscovered       = Notification.Name("com.ilauncher.newBinaryDiscovered")

    // MARK: - AI / intent
    static let intentConflictDetected    = Notification.Name("com.ilauncher.intentConflictDetected")

}
