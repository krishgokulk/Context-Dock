import SwiftUI
import Combine
import EventKit
import Photos
import Contacts
import AppKit

struct SystemPermissionsSettingsView: View {
    @ObservedObject private var permissions = ILAppPermissionCenter.shared
    @State private var calendarStatus: String = "Unknown"
    @State private var remindersStatus: String = "Unknown"
    @State private var photosStatus: String = "Unknown"
    @State private var contactsStatus: String = "Unknown"
    @State private var automationStatus: String = "Unknown"

    var body: some View {
        Form {
            Section(header: Text("Calendars")) {
                Toggle("Enable Calendar Search", isOn: $permissions.allowCalendars)
                HStack {
                    statusLabel(calendarStatus)
                    Spacer()
                    Button("Request Access") { Task { await requestCalendar() } }
                }
            }
            Section(header: Text("Reminders")) {
                Toggle("Enable Reminders Search", isOn: $permissions.allowReminders)
                HStack {
                    statusLabel(remindersStatus)
                    Spacer()
                    Button("Request Access") { Task { await requestReminders() } }
                }
            }
            Section(header: Text("Photos")) {
                Toggle("Enable Photos Search", isOn: $permissions.allowPhotos)
                HStack {
                    statusLabel(photosStatus)
                    Spacer()
                    Button("Request Access") { Task { await requestPhotos() } }
                }
            }
            Section(header: Text("Contacts")) {
                Toggle("Enable Contacts Search", isOn: $permissions.allowContacts)
                HStack {
                    statusLabel(contactsStatus)
                    Spacer()
                    Button("Request Access") { requestContacts() }
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
            remindersStatus = (remStatus == .fullAccess || remStatus == .writeOnly) ? "Authorized" : "Not Authorized"
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
            remindersStatus = remStatus == .authorized ? "Authorized" : "Not Authorized"
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
        automationStatus = permissions.allowAutomation ? "Enabled in App" : "Disabled in App"

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

    // MARK: - Requests
    private func requestCalendar() async {
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

    var body: some View {
        Group {
            Section(header: Text("Calendars")) {
                Toggle("Enable Calendar Search", isOn: $permissions.allowCalendars)
                HStack {
                    statusLabel(calendarStatus)
                    Spacer()
                    Button("Request Access") { Task { await requestCalendar() } }
                }
            }
            Section(header: Text("Reminders")) {
                Toggle("Enable Reminders Search", isOn: $permissions.allowReminders)
                HStack {
                    statusLabel(remindersStatus)
                    Spacer()
                    Button("Request Access") { Task { await requestReminders() } }
                }
            }
            Section(header: Text("Photos")) {
                Toggle("Enable Photos Search", isOn: $permissions.allowPhotos)
                HStack {
                    statusLabel(photosStatus)
                    Spacer()
                    Button("Request Access") { Task { await requestPhotos() } }
                }
            }
            Section(header: Text("Contacts")) {
                Toggle("Enable Contacts Search", isOn: $permissions.allowContacts)
                HStack {
                    statusLabel(contactsStatus)
                    Spacer()
                    Button("Request Access") { requestContacts() }
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
            remindersStatus = (remStatus == .fullAccess || remStatus == .writeOnly) ? "Authorized" : "Not Authorized"
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
            remindersStatus = remStatus == .authorized ? "Authorized" : "Not Authorized"
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
        automationStatus = permissions.allowAutomation ? "Enabled in App" : "Disabled in App"

        #if DEBUG
        print("🔍 Final statuses - Calendar: \(calendarStatus), Reminders: \(remindersStatus), Photos: \(photosStatus), Contacts: \(contactsStatus)")
        #endif
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestCalendar() async {
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
