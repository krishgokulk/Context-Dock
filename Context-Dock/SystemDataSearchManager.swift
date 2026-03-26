//
//  SystemDataSearchManager.swift
//  ILauncher
//
//  Unified search manager for Calendar, Reminders, Photos, Contacts, and Voice Recordings
//

import Foundation
import EventKit
import Photos
import AppKit
import Contacts
import Combine

// Central permission toggles controlled by App Settings UI
@MainActor
final class ILAppPermissionCenter: ObservableObject {
    static let shared = ILAppPermissionCenter()
    // These flags should be bound to your Settings screen
    @Published var allowCalendars = true
    @Published var allowReminders = true
    @Published var allowPhotos = true
    @Published var allowContacts = true
    @Published var allowAutomation = true // AppleScript (Safari/Music/Finder)
}

// MARK: - Search Result Types

enum SystemDataType {
    case note
    case mail
    case photo
    case voiceRecording
    case contact
    case calendarEvent
    case reminder
    case message
}

struct SystemSearchResult {
    let id: String
    let type: SystemDataType
    let title: String
    let subtitle: String
    let details: String?
    let date: Date?
    let icon: NSImage?
    let metadata: [String: Any]

    func open() {
        switch type {
        
        case .note:
            if let noteId = metadata["noteId"] as? String,
               let url = URL(string: "notes://showNote?identifier=\(noteId)") {
                NSWorkspace.shared.open(url)
            }
        case .mail:
            if let messageId = metadata["messageId"] as? String {
                // Open Mail app
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app"))
            }
        case .photo:
            if let localId = metadata["localIdentifier"] as? String {
                // Open Photos app
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
            }
        
        case .voiceRecording:
            if let filePath = metadata["filePath"] as? String {
                NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
            }
        case .contact:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Contacts.app"))
        case .calendarEvent:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        case .reminder:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
        case .message:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app"))
        }
    }
}

// MARK: - Calendar & Reminders Manager

@MainActor
class ILCalendarRemindersSearchManager: ObservableObject {
    static let shared = ILCalendarRemindersSearchManager()
    
    private let eventStore = EKEventStore()
    private let permissionCenter = ILAppPermissionCenter.shared
    
    @Published private(set) var hasCalendarPermission = false
    @Published private(set) var hasRemindersPermission = false
    
    // Flags to prevent concurrent permission requests
    private var isRequestingCalendarPermission = false
    private var isRequestingRemindersPermission = false
    
    private init() {
        checkPermissions()
    }
    
    private func checkPermissions() {
#if os(macOS)
        if #available(macOS 14.0, *) {
            hasCalendarPermission = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            hasRemindersPermission = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        } else {
            hasCalendarPermission = EKEventStore.authorizationStatus(for: .event) == .authorized
            hasRemindersPermission = EKEventStore.authorizationStatus(for: .reminder) == .authorized
        }
#endif
    }
    
    func requestCalendarPermission() async -> Bool {
        // Prevent concurrent permission requests
        if isRequestingCalendarPermission {
            print("⚠️ Calendar permission request already in progress, waiting...")
            // Wait for the existing request to complete
            while isRequestingCalendarPermission {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            return hasCalendarPermission
        }
        
        isRequestingCalendarPermission = true
        defer { isRequestingCalendarPermission = false }
        
        do {
            if #available(macOS 14.0, *) {
                let granted = try await eventStore.requestFullAccessToEvents()
                await MainActor.run { hasCalendarPermission = granted }
                return granted
            } else {
                let granted = try await eventStore.requestAccess(to: .event)
                await MainActor.run { hasCalendarPermission = granted }
                return granted
            }
        } catch {
            print("⚠️ Calendar permission error: \(error)")
            return false
        }
    }
    
    func requestRemindersPermission() async -> Bool {
        // Prevent concurrent permission requests
        if isRequestingRemindersPermission {
            print("⚠️ Reminders permission request already in progress, waiting...")
            // Wait for the existing request to complete
            while isRequestingRemindersPermission {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            return hasRemindersPermission
        }
        
        isRequestingRemindersPermission = true
        defer { isRequestingRemindersPermission = false }
        
        do {
            if #available(macOS 14.0, *) {
                let granted = try await eventStore.requestFullAccessToReminders()
                await MainActor.run {
                    hasRemindersPermission = granted
                }
                return granted
            } else {
                let granted = try await eventStore.requestAccess(to: .reminder)
                await MainActor.run {
                    hasRemindersPermission = granted
                }
                return granted
            }
        } catch {
            print("⚠️ Reminders permission error: \(error)")
            return false
        }
    }
    
    // MARK: - Calendar Events Search
    
    func searchCalendarEvents(query: String, limit: Int = 200) async -> [SystemSearchResult] {
        if permissionCenter.allowCalendars == false { return [] }
        if hasCalendarPermission == false {
            if await requestCalendarPermission() == false {
                return []
            }
        }
        
        var results: [SystemSearchResult] = []
        
        // Wrap eventStore access in error handling to prevent crashes
        do {
            // Search events from past 12 months to next 12 months
            let now = Date()
            let startDate = Calendar.current.date(byAdding: .month, value: -12, to: now) ?? now
            let endDate = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
            
            let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
            let events = eventStore.events(matching: predicate)
            
            let queryLower = query.lowercased()
            let isEmptyQuery = queryLower.isEmpty
            
            for event in events {
                let titleMatches = isEmptyQuery || (event.title?.lowercased().contains(queryLower) ?? false)
                let notesMatches = !isEmptyQuery && (event.notes?.lowercased().contains(queryLower) ?? false)
                let locationMatches = !isEmptyQuery && (event.location?.lowercased().contains(queryLower) ?? false)
                
                if titleMatches || notesMatches || locationMatches {
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateStyle = .medium
                    dateFormatter.timeStyle = .short
                    
                    var subtitle = dateFormatter.string(from: event.startDate)
                    if let location = event.location, !location.isEmpty {
                        subtitle += " • \(location)"
                    }
                    
                    results.append(SystemSearchResult(
                        id: event.eventIdentifier ?? UUID().uuidString,
                        type: .calendarEvent,
                        title: event.title ?? "Untitled Event",
                        subtitle: subtitle,
                        details: event.notes,
                        date: event.startDate,
                        icon: nil,
                        metadata: ["eventIdentifier": event.eventIdentifier ?? ""]
                    ))
                }
            }
        } catch {
            // Silently handle EventKit errors
        }
        
        return results
    }
    
    
    // MARK: - Reminders Search
    
    func searchReminders(query: String, limit: Int = 500) async -> [SystemSearchResult] {
        if permissionCenter.allowReminders == false { return [] }
        if hasRemindersPermission == false {
            if await requestRemindersPermission() == false {
                return []
            }
        }
        
        return await withCheckedContinuation { continuation in
            var results: [SystemSearchResult] = []
            let queryLower = query.lowercased()
            let isEmptyQuery = queryLower.isEmpty
            
            let predicate = eventStore.predicateForReminders(in: nil)
            
            eventStore.fetchReminders(matching: predicate) { reminders in
                guard let reminders = reminders else {
                    continuation.resume(returning: [])
                    return
                }
                
                continuation.resume(returning: results)
            }
        }
    }
}

// MARK: - Photos Search Manager

@MainActor
class ILPhotosSearchManager: ObservableObject {
    static let shared = ILPhotosSearchManager()
    
    private let permissionCenter = ILAppPermissionCenter.shared
                
                @Published private(set) var hasPermission = false
                
                private init() {
                    checkPermission()
                }
                
                private func checkPermission() {
                    hasPermission = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                }
                
                func requestPermission() async -> Bool {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    await MainActor.run {
                        hasPermission = (status == .authorized)
                    }
                    return hasPermission
                }
                
                func searchPhotos(query: String, limit: Int = 20) async -> [SystemSearchResult] {
                    if permissionCenter.allowPhotos == false { return [] }
                    if hasPermission == false {
                        if await requestPermission() == false {
                            return []
                        }
                    }
                    
                    var results: [SystemSearchResult] = []
                    
                    // Search by text (OCR text in photos)
                    let textOptions = PHFetchOptions()
                    textOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
                    // Removed: textOptions.fetchLimit = limit
                    textOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    
                    let assets = PHAsset.fetchAssets(with: textOptions)
                    
                    let imageManager = PHImageManager.default()
                    let requestOptions = PHImageRequestOptions()
                    requestOptions.isSynchronous = true
                    requestOptions.deliveryMode = .fastFormat
                    
                    let q = query.lowercased()
                    
                    assets.enumerateObjects { asset, _, stop in
                        let dateFormatter = DateFormatter()
                        dateFormatter.dateStyle = .medium
                        
                        var subtitle = dateFormatter.string(from: asset.creationDate ?? Date())
                        if let location = asset.location {
                            subtitle += " • \(location.coordinate.latitude), \(location.coordinate.longitude)"
                        }
                        
                        // Basic filtering by filename or location coordinates text
                        var matches = true
                        if !q.isEmpty {
                            let filename = (asset.value(forKey: "filename") as? String)?.lowercased() ?? ""
                            let locText: String = {
                                if let loc = asset.location { return "\(loc.coordinate.latitude),\(loc.coordinate.longitude)".lowercased() }
                                return ""
                            }()
                            matches = filename.contains(q) || (!locText.isEmpty && locText.contains(q))
                        }
                        if !matches { return }
                        
                        // Create thumbnail
                        var thumbnail: NSImage?
                        imageManager.requestImage(for: asset, targetSize: CGSize(width: 32, height: 32), contentMode: .aspectFill, options: requestOptions) { image, _ in
                            if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                                thumbnail = NSImage(cgImage: cg, size: NSSize(width: 32, height: 32))
                            }
                        }
                        
                        results.append(SystemSearchResult(
                            id: asset.localIdentifier,
                            type: .photo,
                            title: "Photo",
                            subtitle: subtitle,
                            details: nil,
                            date: asset.creationDate,
                            icon: thumbnail ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil),
                            metadata: [
                                "localIdentifier": asset.localIdentifier,
                                "mediaType": asset.mediaType.rawValue,
                                "pixelWidth": asset.pixelWidth,
                                "pixelHeight": asset.pixelHeight
                            ]
                        ))
                        
                        if results.count >= limit { stop.pointee = true }
                    }
                    
                    if results.isEmpty && !query.isEmpty {
                        // Fallback: show most recent photos when no filename/location match
                        let fallbackOptions = PHFetchOptions()
                        fallbackOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
                        fallbackOptions.fetchLimit = limit
                        fallbackOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                        let fallbackAssets = PHAsset.fetchAssets(with: fallbackOptions)
                        var count = 0
                        fallbackAssets.enumerateObjects { asset, _, stop in
                            var thumbnail: NSImage?
                            imageManager.requestImage(for: asset, targetSize: CGSize(width: 32, height: 32), contentMode: .aspectFill, options: requestOptions) { image, _ in
                                if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                                    thumbnail = NSImage(cgImage: cg, size: NSSize(width: 32, height: 32))
                                }
                            }
                            results.append(SystemSearchResult(
                                id: asset.localIdentifier,
                                type: .photo,
                                title: "Photo",
                                subtitle: DateFormatter.localizedString(from: asset.creationDate ?? Date(), dateStyle: .medium, timeStyle: .none),
                                details: nil,
                                date: asset.creationDate,
                                icon: thumbnail ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil),
                                metadata: ["localIdentifier": asset.localIdentifier]
                            ))
                            count += 1
                            if count >= limit { stop.pointee = true }
                        }
                    }
                    
                    return results
                }
            }
            
            
            
            
            // MARK: - Contacts Search Manager
            
            class ILContactsSearchManager {
                static let shared = ILContactsSearchManager()
                private let store = CNContactStore()
                private let permissionCenter = ILAppPermissionCenter.shared
                
                func requestPermission(completion: @escaping (Bool) -> Void) {
                    store.requestAccess(for: .contacts) { granted, _ in completion(granted) }
                }
                
                func searchContacts(query: String, limit: Int = 20) async -> [SystemSearchResult] {
                    if permissionCenter.allowContacts == false { return [] }
                    let status = CNContactStore.authorizationStatus(for: .contacts)
                    if status != .authorized {
                        return await withCheckedContinuation { cont in
                            self.requestPermission { granted in
                                cont.resume(returning: granted ? [] : [])
                            }
                        }
                    }
                    var results: [SystemSearchResult] = []
                    let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
                    let request = CNContactFetchRequest(keysToFetch: keys)
                    let q = query.lowercased()
                    try? store.enumerateContacts(with: request) { contact, stop in
                        let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                        let org = contact.organizationName
                        let emails = contact.emailAddresses.map { $0.value as String }.joined(separator: ", ")
                        let phones = contact.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
                        let haystack = [name.lowercased(), org.lowercased(), emails.lowercased(), phones.lowercased()].joined(separator: " ")
                        if haystack.contains(q) {
                            let icon = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
                            icon?.size = NSSize(width: 32, height: 32)
                            results.append(SystemSearchResult(
                                id: contact.identifier,
                                type: .contact,
                                title: name.isEmpty ? org : name,
                                subtitle: !emails.isEmpty ? emails : phones,
                                details: nil,
                                date: nil,
                                icon: icon,
                                metadata: ["contactId": contact.identifier]
                            ))
                            if results.count >= limit { stop.pointee = true }
                        }
                    }
                    return results
                }
            }
            
            // MARK: - Voice Recordings Search Manager
            
            class ILVoiceRecordingsSearchManager {
                static let shared = ILVoiceRecordingsSearchManager()
                
                // Scans Voice Memos container for audio files and matches by filename
                func searchRecordings(query: String, limit: Int = 20) async -> [SystemSearchResult] {
                    var results: [SystemSearchResult] = []
                    let fm = FileManager.default
                    // Common Voice Memos group container path
                    let possiblePaths = [
                        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"),
                        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings")
                    ]
                    let q = query.lowercased()
                    for base in possiblePaths {
                        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                            for url in items where results.count < limit {
                                let name = url.deletingPathExtension().lastPathComponent
                                if name.lowercased().contains(q) {
                                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                                    let date = values?.contentModificationDate
                                    let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
                                    icon?.size = NSSize(width: 32, height: 32)
                                    results.append(SystemSearchResult(
                                        id: url.path,
                                        type: .voiceRecording,
                                        title: name,
                                        subtitle: url.lastPathComponent,
                                        details: nil,
                                        date: date,
                                        icon: icon,
                                        metadata: ["filePath": url.path]
                                    ))
                                }
                            }
                        }
                    }
                    return results
                }
            }

// MARK: - Unified System Data Manager

@MainActor
class SystemDataSearchManager: ObservableObject {
    static let shared = SystemDataSearchManager()
    
    private let calendarManager = ILCalendarRemindersSearchManager.shared
    private let photosManager = ILPhotosSearchManager.shared
    private let contactsManager = ILContactsSearchManager.shared
    private let recordingsManager = ILVoiceRecordingsSearchManager.shared
    
    @Published var isSearching = false
    
    private init() {}
    
    
    func searchAll(query: String, types: Set<SystemDataType> = [ .photo, .contact, .voiceRecording], perTypeLimit: Int = 10, allowEmptyQuery: Bool = false) async -> [SystemSearchResult] {
        guard !query.isEmpty || allowEmptyQuery else {
            print("⚠️ [SystemDataManager] Empty query, returning no results")
            return []
        }
        
        let queryLabel = query.isEmpty ? "<all>" : query
        print("🔍 [SystemDataManager] Starting search for: '\(queryLabel)' across \(types.count) types")
        
        await MainActor.run {
            isSearching = true
        }
        
        var allResults: [SystemSearchResult] = []
        
        // Perform searches in parallel
        await withTaskGroup(of: [SystemSearchResult].self) { group in
            if types.contains(.photo) {
                print("📷 [SystemDataManager] Adding photos search task")
                group.addTask(priority: .userInitiated) {
                    let results = await self.photosManager.searchPhotos(query: query)
                    print("📷 [SystemDataManager] Photos returned \(results.count) results")
                    return results
                }
            }
            
            if types.contains(.contact) {
                print("👤 [SystemDataManager] Adding contacts search task")
                group.addTask(priority: .userInitiated) {
                    let results = await self.contactsManager.searchContacts(query: query)
                    print("👤 [SystemDataManager] Contacts returned \(results.count) results")
                    return results
                }
            }
            
            if types.contains(.voiceRecording) {
                print("🎤 [SystemDataManager] Adding recordings search task")
                group.addTask(priority: .userInitiated) {
                    let results = await self.recordingsManager.searchRecordings(query: query)
                    print("🎤 [SystemDataManager] Recordings returned \(results.count) results")
                    return results
                }
            }
            
            for await results in group {
                print("📦 [SystemDataManager] Received batch of \(results.count) results")
                allResults.append(contentsOf: results)
            }
        }
        
        print("✅ [SystemDataManager] Total raw results: \(allResults.count)")
        
        await MainActor.run {
            isSearching = false
        }
        
        // Ensure representation: cap number of results per type before final sort
        var bucketed: [SystemDataType: [SystemSearchResult]] = [:]
        for r in allResults {
            bucketed[r.type, default: []].append(r)
        }
        var merged: [SystemSearchResult] = []
        for (type, list) in bucketed {
            let sorted = list.sorted { (a, b) in
                switch (a.date, b.date) {
                case let (da?, db?): return da > db
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.title < b.title
                }
            }
            merged.append(contentsOf: sorted.prefix(perTypeLimit))
        }
        allResults = merged
        
        // Sort by date (most recent first)
        return allResults.sorted { (a, b) in
            guard let dateA = a.date, let dateB = b.date else {
                return a.date != nil
            }
            return dateA > dateB
        }
    }
}

