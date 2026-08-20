import OSLog
import SwiftUI
import Combine
import EventKit
import Photos
import Contacts
import AppKit
import CoreGraphics
import Carbon
import ApplicationServices

/// Real Automation (Apple Events) authorization for a target app — never prompts.
/// `noErr` means the user granted this app control of `bundleID` in System Settings →
/// Privacy & Security → Automation. Anything else (denied, not-yet-asked, not running)
/// is treated as not granted.
func contextDockAutomationAuthorized(bundleID: String) -> Bool {
    guard let desc = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else { return false }
    return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) == noErr
}

/// Aggregate Automation status across the apps this feature drives via AppleScript.
/// "Authorized" only when every target is granted; partial shows the count so the user
/// sees progress as they flip toggles; "Not Authorized" when none are on.
func contextDockAggregateAutomationStatus() -> String {
    let targets = [
        "com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS", "com.apple.reminders",
    ]
    let granted = targets.filter(contextDockAutomationAuthorized).count
    if granted == targets.count { return "Authorized" }
    if granted == 0 { return "Not Authorized" }
    return "Authorized \(granted)/\(targets.count)"
}

/// Whether macOS will still show a prompt for a permission, or has already decided.
///
/// TCC asks once. After a denial — including one made by clicking away the sheet — the
/// request API returns `false` immediately and no prompt appears, ever. The button here
/// called that API and reported the same "Not Authorized" it started with, so it looked
/// broken and there was no way to find out that the answer now lives in System Settings.
enum PermissionPrompt {
    static func canPrompt(_ status: EKAuthorizationStatus) -> Bool { status == .notDetermined }
    static func canPrompt(_ status: PHAuthorizationStatus) -> Bool { status == .notDetermined }
    static func canPrompt(_ status: CNAuthorizationStatus) -> Bool { status == .notDetermined }

    /// Deep links into the exact Privacy pane, because "open System Settings" and let the
    /// user hunt for it is barely better than doing nothing.
    static func openSettings(_ pane: String) {
        // `com.apple.preference.security?Privacy_X` is the pre-Ventura anchor. It still
        // opens System Settings and then lands nowhere, which reads to the user as the
        // button doing nothing. LauncherView already uses the modern pane id; this one was
        // left behind.
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)"
        guard let url = URL(string: modern) else { return }
        log.notice("open privacy pane \(pane, privacy: .public)")
        NSWorkspace.shared.open(url)
    }

    static let log = Logger(subsystem: "com.krishgokul.ContextDock", category: "Permissions")

    /// What the system actually says, rather than "Authorized" or not.
    ///
    /// One label for "never asked" and "asked and refused" hides the only thing the user
    /// needs to know: whether clicking will bring up a prompt or send them to System
    /// Settings. Both rendered as "Not Authorized" with an orange dot.
    static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted by policy"
        case .denied: return "Denied — turn on in System Settings"
        case .fullAccess: return "Authorized"
        case .writeOnly: return "Authorized (write only)"
        case .authorized: return "Authorized"
        @unknown default: return "Unknown"
        }
    }

    static func describe(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted by policy"
        case .denied: return "Denied — turn on in System Settings"
        case .authorized: return "Authorized"
        case .limited: return "Authorized (limited)"
        @unknown default: return "Unknown"
        }
    }

    static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted by policy"
        case .denied: return "Denied — turn on in System Settings"
        case .authorized: return "Authorized"
        case .limited: return "Authorized (limited)"
        @unknown default: return "Unknown"
        }
    }

    static let calendars = "Privacy_Calendars"
    static let reminders = "Privacy_Reminders"
    static let photos = "Privacy_Photos"
    static let contacts = "Privacy_Contacts"
}

struct SystemPermissionsSettingsView: View {
    @ObservedObject private var permissions = ILAppPermissionCenter.shared
    @State private var calendarStatus: String = "Unknown"
    @State private var remindersStatus: String = "Unknown"
    @State private var photosStatus: String = "Unknown"
    @State private var contactsStatus: String = "Unknown"
    @State private var automationStatus: String = "Unknown"
    @State private var screenRecordingStatus: String = "Unknown"
    @State private var accessibilityStatus: String = "Unknown"

    var body: some View {
        Form {
            Section(header: Text("Accessibility"), footer: Text("Required for live menu reading and caching, frontmost-app context, and menu actions. Without it those features are silently disabled.")) {
                HStack {
                    statusLabel(accessibilityStatus)
                    Spacer()
                    Button("Open System Settings") { openAccessibilitySettings() }
                }
            }
            Section(header: Text("Calendars")) {
                Toggle("Enable Calendar Search", isOn: $permissions.allowCalendars)
                HStack {
                    statusLabel(calendarStatus)
                    Spacer()
                    Button(PermissionPrompt.canPrompt(EKEventStore.authorizationStatus(for: .event))
                        ? "Request Access" : "Open System Settings") {
                        Task { await requestCalendar() }
                    }
                }
            }
            Section(header: Text("Reminders")) {
                Toggle("Enable Reminders Search", isOn: $permissions.allowReminders)
                HStack {
                    statusLabel(remindersStatus)
                    Spacer()
                    Button(PermissionPrompt.canPrompt(EKEventStore.authorizationStatus(for: .reminder))
                        ? "Request Access" : "Open System Settings") {
                        Task { await requestReminders() }
                    }
                }
            }
            Section(header: Text("Photos")) {
                Toggle("Enable Photos Search", isOn: $permissions.allowPhotos)
                HStack {
                    statusLabel(photosStatus)
                    Spacer()
                    Button(PermissionPrompt.canPrompt(PHPhotoLibrary.authorizationStatus(for: .readWrite))
                        ? "Request Access" : "Open System Settings") {
                        Task { await requestPhotos() }
                    }
                }
            }
            Section(header: Text("Contacts")) {
                Toggle("Enable Contacts Search", isOn: $permissions.allowContacts)
                HStack {
                    statusLabel(contactsStatus)
                    Spacer()
                    Button(PermissionPrompt.canPrompt(CNContactStore.authorizationStatus(for: .contacts))
                        ? "Request Access" : "Open System Settings") {
                        requestContacts()
                    }
                }
            }
            Section(header: Text("Automation (Notes, Mail, Messages)"), footer: Text("Allows the app to control Notes, Mail, and Messages via AppleScript.")) {
                Toggle("Enable Automation Searches", isOn: $permissions.allowAutomation)
                HStack {
                    statusLabel(automationStatus)
                    Spacer()
                    Button("Open System Settings") { openAutomationSettings() }
                }
            }
            Section(header: Text("Screen Recording"), footer: Text("Allows window previews and visual context from visible apps.")) {
                HStack {
                    statusLabel(screenRecordingStatus)
                    Spacer()
                    Button(screenRecordingStatus == "Authorized" ? "Open System Settings" : "Request Access") {
                        requestScreenRecording()
                    }
                }
            }
        }
        .onAppear { refreshStatuses() }
        .navigationTitle("System Permissions")
    }

    private func statusLabel(_ status: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(status == "Authorized" ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshStatuses() {
        // Calendars
        if #available(macOS 14.0, *) {
            let calStatus = EKEventStore.authorizationStatus(for: .event)
            #if DEBUG
            print("📅 Calendar auth status (macOS 14+): \(calStatus.rawValue) (.fullAccess=\(EKAuthorizationStatus.fullAccess.rawValue), .writeOnly=\(EKAuthorizationStatus.writeOnly.rawValue))")
            #endif
            calendarStatus = (calStatus == .fullAccess || calStatus == .writeOnly) ? "Authorized" : "Not Authorized"

            let remStatus = EKEventStore.authorizationStatus(for: .reminder)
            #if DEBUG
            print("✅ Reminders auth status (macOS 14+): \(remStatus.rawValue)")
            #endif
            remindersStatus = PermissionPrompt.describe(remStatus)
        } else {
            let calStatus = EKEventStore.authorizationStatus(for: .event)
            #if DEBUG
            print("📅 Calendar auth status (macOS <14): \(calStatus.rawValue)")
            #endif
            calendarStatus = calStatus == .authorized ? "Authorized" : "Not Authorized"

            let remStatus = EKEventStore.authorizationStatus(for: .reminder)
            #if DEBUG
            print("✅ Reminders auth status (macOS <14): \(remStatus.rawValue)")
            #endif
            remindersStatus = PermissionPrompt.describe(remStatus)
        }
        // Photos
        let ph = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #if DEBUG
        print("📸 Photos auth status: \(ph.rawValue) (.authorized=\(PHAuthorizationStatus.authorized.rawValue))")
        #endif
        photosStatus = ph == .authorized ? "Authorized" : "Not Authorized"
        // Contacts
        let c = CNContactStore.authorizationStatus(for: .contacts)
        #if DEBUG
        print("👤 Contacts auth status: \(c.rawValue) (.authorized=\(CNAuthorizationStatus.authorized.rawValue))")
        #endif
        contactsStatus = c == .authorized ? "Authorized" : "Not Authorized"
        // Automation (AppleScript) – there's no direct API, guide user to System Settings
        automationStatus = permissions.allowAutomation ? contextDockAggregateAutomationStatus() : "Disabled in App"
        screenRecordingStatus = CGPreflightScreenCaptureAccess() ? "Authorized" : "Not Authorized"
        accessibilityStatus = AXIsProcessTrusted() ? "Authorized" : "Not Authorized"

        #if DEBUG
        print("🔍 Final statuses - Calendar: \(calendarStatus), Reminders: \(remindersStatus), Photos: \(photosStatus), Contacts: \(contactsStatus)")
        #endif
    }

    private func openAutomationSettings() {
        // Open System Settings Privacy pane (best-effort)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        screenRecordingStatus = CGPreflightScreenCaptureAccess() ? "Authorized" : "Not Authorized"
        accessibilityStatus = AXIsProcessTrusted() ? "Authorized" : "Not Authorized"
        openScreenRecordingSettings()
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Requests
    private func requestCalendar() async {
        // Already decided: no prompt is coming, so send the user where the decision lives
        // rather than call an API that returns the same answer it gave last time.
        guard PermissionPrompt.canPrompt(EKEventStore.authorizationStatus(for: .event)) else {
            PermissionPrompt.openSettings(PermissionPrompt.calendars)
            return
        }
        #if DEBUG
        print("📅 Requesting calendar permission...")
        #endif
        let granted = await ILCalendarRemindersSearchManager.shared.requestCalendarPermission()
        #if DEBUG
        print("📅 Calendar permission result: \(granted)")
        #endif
        await MainActor.run {
            calendarStatus = granted ? "Authorized" : "Not Authorized"
            refreshStatuses()
        }
    }
    private func requestReminders() async {
        guard PermissionPrompt.canPrompt(EKEventStore.authorizationStatus(for: .reminder)) else {
            PermissionPrompt.openSettings(PermissionPrompt.reminders)
            return
        }
        let before = EKEventStore.authorizationStatus(for: .reminder)
        PermissionPrompt.log.notice(
            "reminders request begin · status=\(before.rawValue, privacy: .public)")
        let granted = await ILCalendarRemindersSearchManager.shared.requestRemindersPermission()
        let after = EKEventStore.authorizationStatus(for: .reminder)
        PermissionPrompt.log.notice(
            "reminders request end · granted=\(granted, privacy: .public) status=\(after.rawValue, privacy: .public)")
        await MainActor.run {
            remindersStatus = granted ? "Authorized" : "Not Authorized"
            refreshStatuses()
        }
    }
    private func requestPhotos() async {
        guard PermissionPrompt.canPrompt(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
            PermissionPrompt.openSettings(PermissionPrompt.photos)
            return
        }
        #if DEBUG
        print("📸 Requesting photos permission...")
        #endif
        let granted = await ILPhotosSearchManager.shared.requestPermission()
        #if DEBUG
        print("📸 Photos permission result: \(granted)")
        #endif
        await MainActor.run {
            photosStatus = granted ? "Authorized" : "Not Authorized"
            refreshStatuses()
        }
    }
    private func requestContacts() {
        guard PermissionPrompt.canPrompt(CNContactStore.authorizationStatus(for: .contacts)) else {
            PermissionPrompt.openSettings(PermissionPrompt.contacts)
            return
        }
        #if DEBUG
        print("👤 Requesting contacts permission...")
        #endif
        ILContactsSearchManager.shared.requestPermission { granted in
            #if DEBUG
            print("👤 Contacts permission result: \(granted)")
            #endif
            DispatchQueue.main.async {
                contactsStatus = granted ? "Authorized" : "Not Authorized"
                refreshStatuses()
            }
        }
    }
}

struct SystemPermissionsSection: View {
    @ObservedObject private var permissions = ILAppPermissionCenter.shared
    @State private var calendarStatus: String = "Unknown"
    @State private var remindersStatus: String = "Unknown"
    @State private var photosStatus: String = "Unknown"
    @State private var contactsStatus: String = "Unknown"
    @State private var automationStatus: String = "Unknown"
    @State private var screenRecordingStatus: String = "Unknown"
    @State private var accessibilityStatus: String = "Unknown"

    var body: some View {
        Group {
            Section(header: Text("Accessibility"), footer: Text("Required for live menu reading and caching, frontmost-app context, and menu actions. Without it those features are silently disabled.")) {
                HStack {
                    statusLabel(accessibilityStatus)
                    Spacer()
                    Button("Open System Settings") { openAccessibilitySettings() }
                }
            }
            Section(header: Text("Calendars")) {
                Toggle("Enable Calendar Search", isOn: $permissions.allowCalendars)
                HStack {
                    statusLabel(calendarStatus)
                    Spacer()
                    Button(PermissionPrompt.canPrompt(EKEventStore.authorizationStatus(for: .event))
                        ? "Request Access" : "Open System Settings") {
                        Task { await requestCalendar() }
                    }
                }
            }
            Section(header: Text("Reminders")) {
                Toggle("Enable Reminders Search", isOn: $permissions.allowReminders)
                HStack {
                    statusLabel(remindersStatus)
                    Spacer()
                    Button(PermissionPrompt.canPrompt(EKEventStore.authorizationStatus(for: .reminder))
                        ? "Request Access" : "Open System Settings") {
                        Task { await requestReminders() }
                    }
                }
            }
            Section(header: Text("Photos")) {
                Toggle("Enable Photos Search", isOn: $permissions.allowPhotos)
                HStack {
                    statusLabel(photosStatus)
                    Spacer()
                    Button(PermissionPrompt.canPrompt(PHPhotoLibrary.authorizationStatus(for: .readWrite))
                        ? "Request Access" : "Open System Settings") {
                        Task { await requestPhotos() }
                    }
                }
            }
            Section(header: Text("Contacts")) {
                Toggle("Enable Contacts Search", isOn: $permissions.allowContacts)
                HStack {
                    statusLabel(contactsStatus)
                    Spacer()
                    Button(PermissionPrompt.canPrompt(CNContactStore.authorizationStatus(for: .contacts))
                        ? "Request Access" : "Open System Settings") {
                        requestContacts()
                    }
                }
            }
            Section(header: Text("Automation (Notes, Mail, Messages)"), footer: Text("Allows the app to control Notes, Mail, and Messages via AppleScript.")) {
                Toggle("Enable Automation Searches", isOn: $permissions.allowAutomation)
                HStack {
                    statusLabel(automationStatus)
                    Spacer()
                    Button("Open System Settings") { openAutomationSettings() }
                }
            }
            Section(header: Text("Screen Recording"), footer: Text("Allows window previews and visual context from visible apps.")) {
                HStack {
                    statusLabel(screenRecordingStatus)
                    Spacer()
                    Button(screenRecordingStatus == "Authorized" ? "Open System Settings" : "Request Access") {
                        requestScreenRecording()
                    }
                }
            }
        }
        .onAppear { refreshStatuses() }
    }

    private func statusLabel(_ status: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(status == "Authorized" ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshStatuses() {
        if #available(macOS 14.0, *) {
            let calStatus = EKEventStore.authorizationStatus(for: .event)
            #if DEBUG
            print("📅 Calendar auth status (macOS 14+): \(calStatus.rawValue) (.fullAccess=\(EKAuthorizationStatus.fullAccess.rawValue), .writeOnly=\(EKAuthorizationStatus.writeOnly.rawValue))")
            #endif
            calendarStatus = (calStatus == .fullAccess || calStatus == .writeOnly) ? "Authorized" : "Not Authorized"

            let remStatus = EKEventStore.authorizationStatus(for: .reminder)
            #if DEBUG
            print("✅ Reminders auth status (macOS 14+): \(remStatus.rawValue)")
            #endif
            remindersStatus = PermissionPrompt.describe(remStatus)
        } else {
            let calStatus = EKEventStore.authorizationStatus(for: .event)
            #if DEBUG
            print("📅 Calendar auth status (macOS <14): \(calStatus.rawValue)")
            #endif
            calendarStatus = calStatus == .authorized ? "Authorized" : "Not Authorized"

            let remStatus = EKEventStore.authorizationStatus(for: .reminder)
            #if DEBUG
            print("✅ Reminders auth status (macOS <14): \(remStatus.rawValue)")
            #endif
            remindersStatus = PermissionPrompt.describe(remStatus)
        }
        let ph = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #if DEBUG
        print("📸 Photos auth status: \(ph.rawValue) (.authorized=\(PHAuthorizationStatus.authorized.rawValue))")
        #endif
        photosStatus = ph == .authorized ? "Authorized" : "Not Authorized"
        let c = CNContactStore.authorizationStatus(for: .contacts)
        #if DEBUG
        print("👤 Contacts auth status: \(c.rawValue) (.authorized=\(CNAuthorizationStatus.authorized.rawValue))")
        #endif
        contactsStatus = c == .authorized ? "Authorized" : "Not Authorized"
        automationStatus = permissions.allowAutomation ? contextDockAggregateAutomationStatus() : "Disabled in App"
        screenRecordingStatus = CGPreflightScreenCaptureAccess() ? "Authorized" : "Not Authorized"
        accessibilityStatus = AXIsProcessTrusted() ? "Authorized" : "Not Authorized"

        #if DEBUG
        print("🔍 Final statuses - Calendar: \(calendarStatus), Reminders: \(remindersStatus), Photos: \(photosStatus), Contacts: \(contactsStatus)")
        #endif
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        screenRecordingStatus = CGPreflightScreenCaptureAccess() ? "Authorized" : "Not Authorized"
        accessibilityStatus = AXIsProcessTrusted() ? "Authorized" : "Not Authorized"
        openScreenRecordingSettings()
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestCalendar() async {
        // Already decided: no prompt is coming, so send the user where the decision lives
        // rather than call an API that returns the same answer it gave last time.
        guard PermissionPrompt.canPrompt(EKEventStore.authorizationStatus(for: .event)) else {
            PermissionPrompt.openSettings(PermissionPrompt.calendars)
            return
        }
        #if DEBUG
        print("📅 Requesting calendar permission...")
        #endif
        let granted = await ILCalendarRemindersSearchManager.shared.requestCalendarPermission()
        #if DEBUG
        print("📅 Calendar permission result: \(granted)")
        #endif
        await MainActor.run {
            calendarStatus = granted ? "Authorized" : "Not Authorized"
            refreshStatuses()
        }
    }
    private func requestReminders() async {
        guard PermissionPrompt.canPrompt(EKEventStore.authorizationStatus(for: .reminder)) else {
            PermissionPrompt.openSettings(PermissionPrompt.reminders)
            return
        }
        #if DEBUG
        print("✅ Requesting reminders permission...")
        #endif
        let granted = await ILCalendarRemindersSearchManager.shared.requestRemindersPermission()
        #if DEBUG
        print("✅ Reminders permission result: \(granted)")
        #endif
        await MainActor.run {
            remindersStatus = granted ? "Authorized" : "Not Authorized"
            refreshStatuses()
        }
    }
    private func requestPhotos() async {
        guard PermissionPrompt.canPrompt(PHPhotoLibrary.authorizationStatus(for: .readWrite)) else {
            PermissionPrompt.openSettings(PermissionPrompt.photos)
            return
        }
        #if DEBUG
        print("📸 Requesting photos permission...")
        #endif
        let granted = await ILPhotosSearchManager.shared.requestPermission()
        #if DEBUG
        print("📸 Photos permission result: \(granted)")
        #endif
        await MainActor.run {
            photosStatus = granted ? "Authorized" : "Not Authorized"
            refreshStatuses()
        }
    }
    private func requestContacts() {
        guard PermissionPrompt.canPrompt(CNContactStore.authorizationStatus(for: .contacts)) else {
            PermissionPrompt.openSettings(PermissionPrompt.contacts)
            return
        }
        #if DEBUG
        print("👤 Requesting contacts permission...")
        #endif
        ILContactsSearchManager.shared.requestPermission { granted in
            #if DEBUG
            print("👤 Contacts permission result: \(granted)")
            #endif
            DispatchQueue.main.async {
                contactsStatus = granted ? "Authorized" : "Not Authorized"
                refreshStatuses()
            }
        }
    }
}

#Preview {
    NavigationStack { SystemPermissionsSettingsView() }
}
