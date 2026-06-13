//
//  AppleAppsAPI.swift
//  ILauncher
//
//  Provides access to all Apple app data for extensions
//

import AppKit
import Contacts
import EventKit
import Foundation
import Photos

class AppleAppsAPI {
    static let shared = AppleAppsAPI()

    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()

    private init() {}

    // MARK: - Calendar API

    func getCalendarEvents(limit: Int = 10) -> [[String: Any]] {
        var events: [[String: Any]] = []

        let calendars = eventStore.calendars(for: .event)
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: 7, to: startDate)!

        let predicate = eventStore.predicateForEvents(
            withStart: startDate, end: endDate, calendars: calendars)
        let ekEvents = eventStore.events(matching: predicate).prefix(limit)

        for event in ekEvents {
            events.append([
                "title": event.title ?? "",
                "location": event.location ?? "",
                "startDate": ISO8601DateFormatter().string(from: event.startDate),
                "endDate": ISO8601DateFormatter().string(from: event.endDate),
                "isAllDay": event.isAllDay,
                "calendar": event.calendar.title,
                "notes": event.notes ?? "",
            ])
        }

        return events
    }

    func getNextEvent() -> [String: Any]? {
        let events = getCalendarEvents(limit: 1)
        return events.first
    }

    func getTodayEvents() -> [[String: Any]] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = eventStore.predicateForEvents(
            withStart: startOfDay, end: endOfDay, calendars: nil)
        let ekEvents = eventStore.events(matching: predicate)

        return ekEvents.map { event in
            [
                "title": event.title ?? "",
                "startDate": ISO8601DateFormatter().string(from: event.startDate),
                "endDate": ISO8601DateFormatter().string(from: event.endDate),
                "isAllDay": event.isAllDay,
            ]
        }
    }

    func getEvents(from startDate: Date, to endDate: Date) -> [[String: Any]] {
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        return eventStore.events(matching: predicate).map { ev in
            var d: [String: Any] = [
                "title": ev.title ?? "",
                "startDate": ISO8601DateFormatter().string(from: ev.startDate),
                "endDate": ISO8601DateFormatter().string(from: ev.endDate),
                "isAllDay": ev.isAllDay,
            ]
            if let loc = ev.location, !loc.isEmpty { d["location"] = loc }
            if let notes = ev.notes, !notes.isEmpty { d["notes"] = notes }
            return d
        }
    }

    func searchEvents(query: String, limit: Int = 50) -> [[String: Any]] {
        let now = Date()
        let start = Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now
        let end = Calendar.current.date(byAdding: .month, value: 6, to: now) ?? now
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let q = query.lowercased()
        return eventStore.events(matching: predicate)
            .filter { ev in
                q.isEmpty ||
                (ev.title?.lowercased().contains(q) ?? false) ||
                (ev.location?.lowercased().contains(q) ?? false) ||
                (ev.notes?.lowercased().contains(q) ?? false)
            }
            .prefix(limit)
            .map { ev in
                var d: [String: Any] = [
                    "title": ev.title ?? "",
                    "startDate": ISO8601DateFormatter().string(from: ev.startDate),
                    "endDate": ISO8601DateFormatter().string(from: ev.endDate),
                    "isAllDay": ev.isAllDay,
                ]
                if let loc = ev.location, !loc.isEmpty { d["location"] = loc }
                return d
            }
    }

    /// Create a new calendar event
    func createEvent(
        title: String, startDate: Date, endDate: Date? = nil, notes: String? = nil,
        location: String? = nil
    ) -> Bool {
        // Request calendar access if not already granted
        let semaphore = DispatchSemaphore(value: 0)
        var accessGranted = false

        eventStore.requestAccess(to: .event) { granted, error in
            accessGranted = granted
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)

        guard accessGranted else {
            print("❌ Calendar access not granted")
            return false
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate ?? startDate.addingTimeInterval(3600)  // Default 1 hour duration
        event.notes = notes
        event.location = location
        event.calendar = eventStore.defaultCalendarForNewEvents

        do {
            try eventStore.save(event, span: .thisEvent)
            print("✅ Calendar event created: \(title)")
            return true
        } catch {
            print("❌ Failed to create calendar event: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Reminders API

    func getReminders(limit: Int = 10) -> [[String: Any]] {
        var reminders: [[String: Any]] = []

        let predicate = eventStore.predicateForReminders(in: nil)

        let semaphore = DispatchSemaphore(value: 0)

        eventStore.fetchReminders(matching: predicate) { ekReminders in
            if let ekReminders = ekReminders {
                for reminder in ekReminders.prefix(limit) where !reminder.isCompleted {
                    var reminderDict: [String: Any] = [
                        "title": reminder.title ?? "",
                        "isCompleted": reminder.isCompleted,
                        "priority": reminder.priority,
                        "notes": reminder.notes ?? "",
                    ]

                    if let dueDate = reminder.dueDateComponents?.date {
                        reminderDict["dueDate"] = ISO8601DateFormatter().string(from: dueDate)
                    }

                    reminders.append(reminderDict)
                }
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 2)
        return reminders
    }

    func getOverdueReminders() -> [[String: Any]] {
        let allReminders = getReminders(limit: 100)
        let now = Date()

        return allReminders.filter { reminder in
            guard let dueDateString = reminder["dueDate"] as? String,
                let dueDate = ISO8601DateFormatter().date(from: dueDateString)
            else {
                return false
            }
            return dueDate < now
        }
    }

    // MARK: - Contacts API

    func getContacts(limit: Int = 100) -> [[String: Any]] {
        var contacts: [[String: Any]] = []

        let keys =
            [
                CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey,
                CNContactEmailAddressesKey, CNContactImageDataKey,
            ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)

        do {
            try contactStore.enumerateContacts(with: request) { contact, stop in
                var contactDict: [String: Any] = [
                    "firstName": contact.givenName,
                    "lastName": contact.familyName,
                    "fullName": "\(contact.givenName) \(contact.familyName)",
                ]

                if !contact.phoneNumbers.isEmpty {
                    contactDict["phone"] = contact.phoneNumbers.first?.value.stringValue ?? ""
                }

                if !contact.emailAddresses.isEmpty {
                    contactDict["email"] = contact.emailAddresses.first?.value as String? ?? ""
                }

                contacts.append(contactDict)

                if contacts.count >= limit {
                    stop.pointee = true
                }
            }
        } catch {
            print("Failed to fetch contacts: \(error)")
        }

        return contacts
    }

    func searchContacts(query: String) -> [[String: Any]] {
        let allContacts = getContacts(limit: 1000)
        return allContacts.filter { contact in
            let fullName = (contact["fullName"] as? String ?? "").lowercased()
            return fullName.contains(query.lowercased())
        }
    }

    // MARK: - Safari API

    func getCurrentTab() -> [String: Any] {
        let script = """
            tell application "Safari"
                if (count of windows) > 0 then
                    set currentTab to current tab of front window
                    set tabURL to URL of currentTab
                    set tabTitle to name of currentTab
                    return tabURL & "|||" & tabTitle
                end if
            end tell
            return ""
            """

        if let result = runAppleScript(script), !result.isEmpty {
            let parts = result.components(separatedBy: "|||")
            if parts.count >= 2 {
                return [
                    "url": parts[0],
                    "title": parts[1],
                ]
            } else if parts.count == 1 {
                return ["url": parts[0], "title": ""]
            }
        }
        return [:]
    }

    func getAllTabs() -> [[String: Any]] {
        let script = """
            tell application "Safari"
                set tabList to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabURL to URL of t
                        set tabTitle to name of t
                        set tabList to tabList & tabURL & "|||" & tabTitle & "^^^"
                    end repeat
                end repeat
                return tabList
            end tell
            """

        var tabs: [[String: Any]] = []
        if let result = runAppleScript(script), !result.isEmpty {
            let tabStrings = result.components(separatedBy: "^^^").filter { !$0.isEmpty }
            for tabString in tabStrings {
                let parts = tabString.components(separatedBy: "|||")
                if parts.count >= 2 {
                    tabs.append([
                        "url": parts[0],
                        "title": parts[1],
                    ])
                }
            }
        }
        return tabs
    }

    func openSafariURL(_ url: String) -> Bool {
        let script = """
            tell application "Safari"
                activate
                open location "\(escapeAppleScriptString(url))"
            end tell
            """
        return runAppleScript(script) != nil
    }

    func closeCurrentSafariTab() -> Bool {
        let script = """
            tell application "Safari"
                if (count of windows) > 0 then
                    close current tab of front window
                end if
            end tell
            """
        return runAppleScript(script) != nil
    }

    func searchSafariTabs(query: String) -> [[String: Any]] {
        let allTabs = getAllTabs()
        let needle = query.lowercased()
        return allTabs.filter { tab in
            let title = (tab["title"] as? String ?? "").lowercased()
            let url = (tab["url"] as? String ?? "").lowercased()
            return title.contains(needle) || url.contains(needle)
        }
    }

    /// Save the current Safari page as PDF
    func saveCurrentPageAsPDF(filename: String? = nil) -> Bool {
        let outputName = filename ?? "safari_page_\(Int(Date().timeIntervalSince1970))"
        let outputPath = NSHomeDirectory() + "/Desktop/\(outputName).pdf"

        let script = """
            tell application "Safari"
                if (count of windows) > 0 then
                    set currentTab to current tab of front window
                    set theURL to URL of currentTab
                end if
            end tell

            tell application "System Events"
                tell process "Safari"
                    keystroke "p" using command down
                    delay 1
                    click menu button "PDF" of sheet 1 of window 1
                    delay 0.5
                    click menu item "Save as PDF" of menu 1 of menu button "PDF" of sheet 1 of window 1
                    delay 1
                    keystroke "\(outputPath)"
                    delay 0.5
                    keystroke return
                    delay 1
                end tell
            end tell
            return "success"
            """

        let result = runAppleScript(script)
        return result != nil
    }

    // MARK: - Music API

    func getMusicInfo() -> [String: Any] {
        let script = """
            tell application "Music"
                if player state is not stopped then
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackDuration to duration of current track
                    set playerPos to player position
                    set playerState to player state as text
                    return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & playerState & "|||" & (trackDuration as text) & "|||" & (playerPos as text)
                end if
            end tell
            return ""
            """

        if let result = runAppleScript(script), !result.isEmpty {
            let parts = result.components(separatedBy: "|||")
            if parts.count >= 6 {
                return [
                    "title": parts[0],
                    "artist": parts[1],
                    "album": parts[2],
                    "state": parts[3],
                    "duration": Double(parts[4]) ?? 0,
                    "position": Double(parts[5]) ?? 0,
                ]
            }
        }
        return [:]
    }

    /// Control Music playback
    func musicControl(_ action: String) -> Bool {
        let script: String
        switch action.lowercased() {
        case "play":
            script = "tell application \"Music\" to play"
        case "pause":
            script = "tell application \"Music\" to pause"
        case "next":
            script = "tell application \"Music\" to next track"
        case "previous":
            script = "tell application \"Music\" to previous track"
        case "toggle":
            script = "tell application \"Music\" to playpause"
        default:
            return false
        }
        return runAppleScript(script) != nil
    }

    func getMusicVolume() -> Int? {
        let script = """
            tell application "Music"
                return sound volume as text
            end tell
            """
        if let result = runAppleScript(script),
            let volume = Int(result.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return volume
        }
        return nil
    }

    func setMusicVolume(_ volume: Int) -> Bool {
        let clamped = max(0, min(100, volume))
        let script = """
            tell application "Music"
                set sound volume to \(clamped)
            end tell
            """
        return runAppleScript(script) != nil
    }

    // MARK: - Photos API

    func getRecentPhotos(limit: Int = 10) -> [[String: Any]] {
        guard requestPhotosAccess() else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var results: [[String: Any]] = []

        assets.enumerateObjects { asset, _, stop in
            let created = asset.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
            results.append([
                "id": asset.localIdentifier,
                "filename": filename,
                "created": created,
                "width": asset.pixelWidth,
                "height": asset.pixelHeight,
                "favorite": asset.isFavorite,
            ])

            if results.count >= limit {
                stop.pointee = true
            }
        }

        return results
    }

    func searchPhotos(query: String, limit: Int = 20) -> [[String: Any]] {
        guard requestPhotosAccess() else { return [] }

        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var results: [[String: Any]] = []

        assets.enumerateObjects { asset, _, stop in
            let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
            if normalized.isEmpty || filename.lowercased().contains(normalized) {
                let created =
                    asset.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
                results.append([
                    "id": asset.localIdentifier,
                    "filename": filename,
                    "created": created,
                    "width": asset.pixelWidth,
                    "height": asset.pixelHeight,
                    "favorite": asset.isFavorite,
                ])
                if results.count >= limit {
                    stop.pointee = true
                }
            }
        }

        return results
    }

    // MARK: - Finder API

    func getCurrentFolder() -> String {
        let script = """
            tell application "Finder"
                if (count of Finder windows) > 0 then
                    return POSIX path of (target of front window as alias)
                end if
            end tell
            return ""
            """

        return runAppleScript(script) ?? ""
    }

    func openFinder(at path: String) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        let script = """
            tell application "Finder"
                activate
                open POSIX file "\(escapeAppleScriptString(expanded))"
            end tell
            """
        return runAppleScript(script) != nil
    }

    func getSelectedFiles() -> [String] {
        let script = """
            tell application "Finder"
                set selectedItems to selection
                set filePaths to ""
                repeat with anItem in selectedItems
                    set filePaths to filePaths & (POSIX path of (anItem as alias)) & "|||"
                end repeat
                return filePaths
            end tell
            """

        if let result = runAppleScript(script), !result.isEmpty {
            return result.components(separatedBy: "|||").filter { !$0.isEmpty }
        }
        return []
    }

    /// Get detailed info about selected files in Finder
    func getSelectedFilesInfo() -> [[String: Any]] {
        let script = """
            tell application "Finder"
                set selectedItems to selection
                set fileInfo to ""
                repeat with anItem in selectedItems
                    set itemPath to POSIX path of (anItem as alias)
                    set itemName to name of anItem
                    set itemSize to size of anItem
                    set itemKind to kind of anItem
                    set itemDate to modification date of anItem as text
                    set fileInfo to fileInfo & itemPath & "|||" & itemName & "|||" & (itemSize as text) & "|||" & itemKind & "|||" & itemDate & "^^^"
                end repeat
                return fileInfo
            end tell
            """

        var files: [[String: Any]] = []
        if let result = runAppleScript(script), !result.isEmpty {
            let fileStrings = result.components(separatedBy: "^^^").filter { !$0.isEmpty }
            for fileString in fileStrings {
                let parts = fileString.components(separatedBy: "|||")
                if parts.count >= 5 {
                    files.append([
                        "path": parts[0],
                        "name": parts[1],
                        "size": Int64(parts[2]) ?? 0,
                        "kind": parts[3],
                        "modified": parts[4],
                    ])
                }
            }
        }
        return files
    }

    /// Reveal a file in Finder
    func revealInFinder(_ path: String) -> Bool {
        let script = """
            tell application "Finder"
                reveal POSIX file "\(escapeAppleScriptString(path))"
                activate
            end tell
            """
        return runAppleScript(script) != nil
    }

    /// Move files to folder
    func moveFiles(_ sourcePaths: [String], to destinationFolder: String) -> Bool {
        let expandedDest = NSString(string: destinationFolder).expandingTildeInPath

        for sourcePath in sourcePaths {
            let script = """
                tell application "Finder"
                    move POSIX file "\(escapeAppleScriptString(sourcePath))" to POSIX file "\(escapeAppleScriptString(expandedDest))"
                end tell
                """
            if runAppleScript(script) == nil {
                return false
            }
        }
        return true
    }

    /// Create a new folder
    func createFolder(at path: String, name: String) -> Bool {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let script = """
            tell application "Finder"
                make new folder at POSIX file "\(escapeAppleScriptString(expandedPath))" with properties {name:"\(escapeAppleScriptString(name))"}
            end tell
            """
        return runAppleScript(script) != nil
    }

    // MARK: - Notes API

    func getNotes(limit: Int = 10) -> [[String: Any]] {
        let script = """
            tell application "Notes"
                set noteList to ""
                repeat with n in (notes of default account)
                    if (count of noteList) < \(limit * 100) then
                        set noteName to name of n
                        set noteBody to plaintext of n
                        set noteDate to modification date of n as text
                        -- Truncate body to first 200 chars
                        if length of noteBody > 200 then
                            set noteBody to text 1 thru 200 of noteBody
                        end if
                        set noteList to noteList & noteName & "|||" & noteBody & "|||" & noteDate & "^^^"
                    end if
                end repeat
                return noteList
            end tell
            """

        var notes: [[String: Any]] = []
        if let result = runAppleScript(script), !result.isEmpty {
            let noteStrings = result.components(separatedBy: "^^^").filter { !$0.isEmpty }
            for noteString in noteStrings.prefix(limit) {
                let parts = noteString.components(separatedBy: "|||")
                if parts.count >= 3 {
                    notes.append([
                        "title": parts[0],
                        "body": parts[1],
                        "modified": parts[2],
                    ])
                }
            }
        }
        return notes
    }

    func searchNotes(query: String) -> [[String: Any]] {
        let allNotes = getNotes(limit: 100)
        let queryLower = query.lowercased()

        return allNotes.filter { note in
            let title = (note["title"] as? String ?? "").lowercased()
            let body = (note["body"] as? String ?? "").lowercased()
            return title.contains(queryLower) || body.contains(queryLower)
        }
    }

    func createNote(title: String, body: String, folder: String = "ILauncher") -> Bool {
        let noteTitle =
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Note" : title
        let script = """
            tell application "Notes"
                activate
                try
                    set targetFolder to folder "\(escapeAppleScriptString(folder))" of default account
                on error
                    set targetFolder to make new folder at default account with properties {name:"\(escapeAppleScriptString(folder))"}
                end try

                make new note at targetFolder with properties {name:"\(escapeAppleScriptString(noteTitle))", body:"\(escapeAppleScriptString(body))"}
            end tell
            """
        return runAppleScript(script) != nil
    }

    func saveLinkToNotes(url: String, title: String?, folder: String = "Web Saves") -> Bool {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return false }
        let noteTitle =
            (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? title! : cleanURL)
        let body = "\(noteTitle)\n\(cleanURL)"
        return createNote(title: noteTitle, body: body, folder: folder)
    }

    func composeMail(subject: String, body: String) -> Bool {
        var components = URLComponents(string: "mailto:")!
        var queryItems: [URLQueryItem] = []
        if !subject.isEmpty {
            queryItems.append(URLQueryItem(name: "subject", value: subject))
        }
        if !body.isEmpty {
            queryItems.append(URLQueryItem(name: "body", value: body))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    func createReminder(title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let script = """
            tell application "Reminders"
                activate
                tell default list
                    make new reminder with properties {name:"\(escapeAppleScriptString(trimmed))"}
                end tell
            end tell
            """
        return runAppleScript(script) != nil
    }

    // MARK: - Mail API

    func getRecentEmails(limit: Int = 10) -> [[String: Any]] {
        let script = """
            tell application "Mail"
                set emailList to ""
                set inboxMessages to messages of inbox
                repeat with i from 1 to (count of inboxMessages)
                    if i > \(limit) then exit repeat
                    set m to item i of inboxMessages
                    set emailSubject to subject of m
                    set emailSender to sender of m
                    set emailDate to date received of m as text
                    set emailRead to read status of m
                    set emailList to emailList & emailSubject & "|||" & emailSender & "|||" & emailDate & "|||" & (emailRead as text) & "^^^"
                end repeat
                return emailList
            end tell
            """

        var emails: [[String: Any]] = []
        if let result = runAppleScript(script), !result.isEmpty {
            let emailStrings = result.components(separatedBy: "^^^").filter { !$0.isEmpty }
            for emailString in emailStrings {
                let parts = emailString.components(separatedBy: "|||")
                if parts.count >= 4 {
                    emails.append([
                        "subject": parts[0],
                        "sender": parts[1],
                        "date": parts[2],
                        "read": parts[3] == "true",
                    ])
                }
            }
        }
        return emails
    }

    // MARK: - Helper

    private func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let output = scriptObject.executeAndReturnError(&error)
            if error == nil, let result = output.stringValue {
                return result
            }
        }
        return nil
    }

    func handleAppleScript(_ script: String) -> String? {
        runAppleScript(script)
    }

    private func escapeAppleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func requestPhotosAccess() -> Bool {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if currentStatus == .authorized || currentStatus == .limited {
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        var authorized = false

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            authorized = (status == .authorized || status == .limited)
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return authorized
    }

    // MARK: - JSON Output

    func handleCommand(_ args: [String]) -> String {
        guard !args.isEmpty else {
            return "{\"error\": \"No command specified\"}"
        }

        let command = args[0]
        var data: Any?

        switch command {
        // Calendar
        case "calendar-events":
            let limit = args.count > 1 ? Int(args[1]) ?? 10 : 10
            data = getCalendarEvents(limit: limit)
        case "calendar-next":
            data = getNextEvent()
        case "calendar-today":
            data = getTodayEvents()
        case "calendar-create":
            // Format: calendar-create "title" "start date" "end date" "notes" "location"
            if args.count >= 3 {
                let title = args[1]
                let formatter = ISO8601DateFormatter()
                if let startDate = formatter.date(from: args[2]) {
                    let endDate = args.count > 3 ? formatter.date(from: args[3]) : nil
                    let notes = args.count > 4 ? args[4] : nil
                    let location = args.count > 5 ? args[5] : nil
                    let success = createEvent(
                        title: title, startDate: startDate, endDate: endDate, notes: notes,
                        location: location)
                    data = [
                        "success": success,
                        "message": success
                            ? "Event created successfully" : "Failed to create event",
                    ]
                } else {
                    data = ["success": false, "message": "Invalid date format"]
                }
            } else {
                data = ["success": false, "message": "Missing required arguments"]
            }

        // Reminders
        case "reminders":
            let limit = args.count > 1 ? Int(args[1]) ?? 10 : 10
            data = getReminders(limit: limit)
        case "reminders-overdue":
            data = getOverdueReminders()

        // Contacts
        case "contacts":
            let limit = args.count > 1 ? Int(args[1]) ?? 100 : 100
            data = getContacts(limit: limit)
        case "contacts-search":
            if args.count > 1 {
                data = searchContacts(query: args[1])
            }

        // Safari
        case "safari-current":
            data = getCurrentTab()
        case "safari-tabs":
            data = getAllTabs()
        case "safari-search":
            if args.count > 1 {
                data = searchSafariTabs(query: args[1])
            } else {
                data = []
            }
        case "safari-open":
            if args.count > 1 {
                let success = openSafariURL(args[1])
                data = ["success": success]
            }
        case "safari-close":
            data = ["success": closeCurrentSafariTab()]
        case "safari-save-pdf":
            let filename = args.count > 1 ? args[1] : nil
            data = ["success": saveCurrentPageAsPDF(filename: filename)]

        // Music
        case "music-info":
            data = getMusicInfo()
        case "music-play":
            data = ["success": musicControl("play")]
        case "music-pause":
            data = ["success": musicControl("pause")]
        case "music-next":
            data = ["success": musicControl("next")]
        case "music-previous":
            data = ["success": musicControl("previous")]
        case "music-toggle":
            data = ["success": musicControl("toggle")]
        case "music-volume":
            data = ["volume": getMusicVolume() ?? 0]
        case "music-set-volume":
            if args.count > 1, let volume = Int(args[1]) {
                data = ["success": setMusicVolume(volume)]
            }

        // Photos
        case "photos-recent":
            let limit = args.count > 1 ? Int(args[1]) ?? 10 : 10
            data = getRecentPhotos(limit: limit)
        case "photos-search":
            let limit = args.count > 2 ? Int(args[2]) ?? 20 : 20
            if args.count > 1 {
                data = searchPhotos(query: args[1], limit: limit)
            } else {
                data = []
            }

        // Finder
        case "finder-folder":
            data = ["path": getCurrentFolder()]
        case "finder-selected":
            data = ["files": getSelectedFiles()]
        case "finder-selected-info":
            data = getSelectedFilesInfo()
        case "finder-reveal":
            if args.count > 1 {
                data = ["success": revealInFinder(args[1])]
            }
        case "finder-open":
            if args.count > 1 {
                data = ["success": openFinder(at: args[1])]
            }
        case "finder-move":
            if args.count > 2 {
                let sources = Array(args.dropFirst().dropLast())
                let destination = args.last ?? ""
                data = ["success": moveFiles(sources, to: destination)]
            }
        case "finder-create-folder":
            if args.count > 2 {
                let path = args[1]
                let name = args[2]
                data = ["success": createFolder(at: path, name: name)]
            }

        default:
            return "{\"error\": \"Unknown command: \(command)\"}"
        }

        // Convert to JSON
        if let data = data,
            let jsonData = try? JSONSerialization.data(
                withJSONObject: data, options: [.prettyPrinted]),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            return jsonString
        }

        return "{}"
    }
}
