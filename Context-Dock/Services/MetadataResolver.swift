import Contacts
import EventKit
import Foundation

struct ResolvedMailSender {
    let handle: String
    let displayName: String
    let score: Int
    let subject: String
    let dateText: String
}

private struct MetadataResolutionEnvelope: Encodable {
    let domain: String
    let query: String
    let results: [MetadataResolutionRecord]
}

private struct MetadataResolutionRecord: Encodable {
    let kind: String
    let displayName: String
    let primaryValue: String
    let secondaryValue: String?
    let source: String
    let confidence: Int
    let details: [String: String]
}

enum MetadataResolver {
    static func resolveJSONString(
        query: String,
        domain: String = "auto",
        maxResults: Int = 5
    ) async -> String {
        let normalizedDomain = normalizedDomain(domain)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeMaxResults = max(1, min(maxResults, 10))

        let records = await resolveRecords(
            query: trimmedQuery,
            domain: normalizedDomain,
            maxResults: safeMaxResults
        )
        let envelope = MetadataResolutionEnvelope(
            domain: normalizedDomain,
            query: trimmedQuery,
            results: records
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{\"domain\":\"\(normalizedDomain)\",\"query\":\"\(escapeJSONString(trimmedQuery))\",\"results\":[]}"
        }
        return json
    }

    nonisolated static func bestMailSender(matching query: String) -> ResolvedMailSender? {
        resolveMailSenders(matching: query, limit: 1).first
    }

    private static func resolveRecords(
        query: String,
        domain: String,
        maxResults: Int
    ) async -> [MetadataResolutionRecord] {
        guard !query.isEmpty else { return [] }

        switch domain {
        case "contacts":
            return await resolveContacts(matching: query, limit: maxResults)
        case "mail":
            // Off the calling executor, because this one blocks. resolveMailSenders drives
            // an AppleScript mailbox scan, and its two siblings here — contacts and
            // calendar — are awaited while it was called straight through. On the main
            // actor that freezes the app for the length of the scan: a spin report caught
            // the main thread inside NSAppleScript, under a single General Chat message.
            //
            // It is nonisolated, so it belongs off the main thread rather than in front
            // of it.
            let senders = await Task.detached(priority: .userInitiated) {
                resolveMailSenders(matching: query, limit: maxResults)
            }.value
            return senders.map { sender in
                MetadataResolutionRecord(
                    kind: "mail_sender",
                    displayName: sender.displayName,
                    primaryValue: sender.handle,
                    secondaryValue: sender.subject,
                    source: "mail",
                    confidence: sender.score,
                    details: [
                        "dateText": sender.dateText,
                        "subject": sender.subject
                    ]
                )
            }
        case "calendar":
            return await resolveCalendarEvents(matching: query, limit: maxResults)
        default:
            async let contacts = resolveContacts(matching: query, limit: maxResults)
            async let calendar = resolveCalendarEvents(matching: query, limit: maxResults)
            let mail = resolveMailSenders(matching: query, limit: maxResults).map { sender in
                MetadataResolutionRecord(
                    kind: "mail_sender",
                    displayName: sender.displayName,
                    primaryValue: sender.handle,
                    secondaryValue: sender.subject,
                    source: "mail",
                    confidence: sender.score,
                    details: [
                        "dateText": sender.dateText,
                        "subject": sender.subject
                    ]
                )
            }

            let combined = await contacts + mail + calendar
            return combined
                .sorted {
                    if $0.confidence == $1.confidence {
                        return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                    }
                    return $0.confidence > $1.confidence
                }
                .prefix(maxResults)
                .map { $0 }
        }
    }

    private static func resolveContacts(
        matching query: String,
        limit: Int
    ) async -> [MetadataResolutionRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]

        let contacts = (try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: trimmedQuery),
            keysToFetch: keys
        )) ?? []

        let normalizedQuery = normalizedText(trimmedQuery)
        return contacts.compactMap { contact in
            let fullName = CNContactFormatter.string(from: contact, style: .fullName)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayName = fullName.isEmpty
                ? [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                : fullName
            let normalizedName = normalizedText(displayName)
            let primaryEmail = contact.emailAddresses.first?.value as String? ?? ""
            let primaryPhone = contact.phoneNumbers.first?.value.stringValue ?? ""
            let normalizedEmail = primaryEmail.lowercased()
            let normalizedPhone = normalizedPhoneNumber(primaryPhone)

            var confidence = 0
            if normalizedName == normalizedQuery {
                confidence += 520
            } else if normalizedName.hasPrefix(normalizedQuery) {
                confidence += 380
            } else if normalizedName.contains(normalizedQuery) {
                confidence += 300
            }

            if !normalizedEmail.isEmpty && normalizedEmail.contains(normalizedQuery.replacingOccurrences(of: " ", with: "")) {
                confidence += 180
            }
            if !normalizedPhone.isEmpty && normalizedPhone.contains(normalizedPhoneNumber(trimmedQuery)) {
                confidence += 120
            }

            guard confidence > 0 || !displayName.isEmpty else { return nil }

            let primaryValue = !primaryEmail.isEmpty ? primaryEmail : primaryPhone
            guard !primaryValue.isEmpty else { return nil }

            var details: [String: String] = [:]
            if !primaryEmail.isEmpty { details["email"] = primaryEmail }
            if !primaryPhone.isEmpty { details["phone"] = primaryPhone }

            return MetadataResolutionRecord(
                kind: "contact",
                displayName: displayName,
                primaryValue: primaryValue,
                secondaryValue: primaryEmail.isEmpty || primaryPhone.isEmpty
                    ? nil
                    : primaryPhone,
                source: "contacts",
                confidence: confidence,
                details: details
            )
        }
        .sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.confidence > rhs.confidence
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func resolveCalendarEvents(
        matching query: String,
        limit: Int
    ) async -> [MetadataResolutionRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            let granted = await requestCalendarAccess(store)
            guard granted else { return [] }
        }

        let currentStatus = EKEventStore.authorizationStatus(for: .event)
        let hasAccess: Bool
        if #available(macOS 14.0, *) {
            hasAccess = currentStatus == .fullAccess || currentStatus == .writeOnly
        } else {
            hasAccess = currentStatus == .authorized
        }
        guard hasAccess else { return [] }

        let now = Date()
        guard let endDate = Calendar.current.date(byAdding: .day, value: 30, to: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: endDate, calendars: nil)
        let events = store.events(matching: predicate)
        let normalizedQuery = normalizedText(trimmedQuery)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        return events.compactMap { event in
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let normalizedTitle = normalizedText(title)
            let attendeeStrings = (event.attendees ?? []).map { participant -> String in
                let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let urlString = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                return [name, urlString].filter { !$0.isEmpty }.joined(separator: " ")
            }
            let normalizedAttendees = attendeeStrings.map(normalizedText)

            var confidence = 0
            if !normalizedTitle.isEmpty {
                if normalizedTitle == normalizedQuery {
                    confidence += 500
                } else if normalizedTitle.hasPrefix(normalizedQuery) {
                    confidence += 340
                } else if normalizedTitle.contains(normalizedQuery) {
                    confidence += 260
                }
            }

            if normalizedAttendees.contains(where: { $0 == normalizedQuery }) {
                confidence += 420
            } else if normalizedAttendees.contains(where: { $0.contains(normalizedQuery) }) {
                confidence += 320
            }

            guard confidence > 0 else { return nil }

            let when = formatter.string(from: event.startDate)
            var details: [String: String] = ["startDate": when]
            if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                details["location"] = location
            }
            if !attendeeStrings.isEmpty {
                details["attendees"] = attendeeStrings.joined(separator: "; ")
            }

            return MetadataResolutionRecord(
                kind: "calendar_event",
                displayName: title.isEmpty ? "(untitled event)" : title,
                primaryValue: when,
                secondaryValue: event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                source: "calendar",
                confidence: confidence,
                details: details
            )
        }
        .sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.confidence > rhs.confidence
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func requestCalendarAccess(_ store: EKEventStore) async -> Bool {
        if #available(macOS 14.0, *) {
            return await withCheckedContinuation { continuation in
                store.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }

        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .event) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated private static func resolveMailSenders(
        matching query: String,
        limit: Int
    ) -> [ResolvedMailSender] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let queryVariants = Array(
            NSOrderedSet(array: [
                trimmedQuery,
                trimmedQuery.localizedCapitalized,
                trimmedQuery.uppercased(),
            ].filter { !$0.isEmpty })
        ) as? [String] ?? [trimmedQuery]

        var matchesByHandle: [String: ResolvedMailSender] = [:]
        for variant in queryVariants {
            guard let snapshot = MailAutomation.mailboxSnapshotData(
                senderContains: variant,
                limit: max(limit * 2, 10),
                maxScan: 500
            ) else {
                continue
            }

            for message in snapshot.messages {
                guard let candidate = mailSenderCandidate(from: message, query: trimmedQuery) else {
                    continue
                }
                let key = candidate.handle.lowercased()
                if let existing = matchesByHandle[key] {
                    if candidate.score > existing.score {
                        matchesByHandle[key] = candidate
                    }
                } else {
                    matchesByHandle[key] = candidate
                }
            }
        }

        return matchesByHandle.values
            .sorted {
                if $0.score == $1.score {
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                return $0.score > $1.score
            }
            .prefix(limit)
            .map { $0 }
    }

    nonisolated private static func mailSenderCandidate(
        from message: MailAutomationMessageSummary,
        query: String
    ) -> ResolvedMailSender? {
        let sender = message.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty,
            let handle = firstEmailAddress(in: sender)
        else {
            return nil
        }

        let displayName = displayName(fromMailSender: sender, email: handle)
        let normalizedQuery = normalizedText(query)
        let normalizedDisplayName = normalizedText(displayName)
        let normalizedSender = normalizedText(sender)
        let normalizedHandle = handle.lowercased()
        let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")

        guard !normalizedQuery.isEmpty else { return nil }

        var score = 0
        let matchesDisplay = !normalizedDisplayName.isEmpty && normalizedDisplayName.contains(normalizedQuery)
        let matchesSender = normalizedSender.contains(normalizedQuery)
        let matchesHandle =
            normalizedHandle.contains(compactQuery)
            || normalizedHandle.contains("@\(compactQuery)")

        guard matchesDisplay || matchesSender || matchesHandle else { return nil }

        if normalizedDisplayName == normalizedQuery {
            score += 500
        } else if normalizedDisplayName.hasPrefix(normalizedQuery) {
            score += 380
        } else if matchesDisplay {
            score += 300
        }

        if normalizedSender == normalizedQuery {
            score += 220
        } else if matchesSender {
            score += 140
        }

        if normalizedHandle == compactQuery {
            score += 260
        } else if normalizedHandle.hasPrefix(compactQuery) || normalizedHandle.contains("@\(compactQuery)") {
            score += 180
        } else if normalizedHandle.contains(compactQuery) {
            score += 90
        }

        if handle.range(
            of: "(?:^|[^a-z])(?:no.?reply|do.?not.?reply)(?:[^a-z]|$)",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            score -= 120
        }

        return ResolvedMailSender(
            handle: handle,
            displayName: displayName,
            score: score,
            subject: message.subject,
            dateText: message.dateText
        )
    }

    nonisolated private static func firstEmailAddress(in value: String) -> String? {
        let pattern = "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
            let emailRange = Range(match.range(at: 0), in: value)
        else {
            return nil
        }
        return String(value[emailRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func displayName(fromMailSender sender: String, email: String) -> String {
        let withoutEmail = sender
            .replacingOccurrences(of: "<\\s*\(NSRegularExpression.escapedPattern(for: email))\\s*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: NSRegularExpression.escapedPattern(for: email), with: "", options: .regularExpression)
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " <>\"'"))

        if !withoutEmail.isEmpty {
            return withoutEmail
        }

        let localPart = email.split(separator: "@").first.map(String.init) ?? email
        return localPart.replacingOccurrences(of: ".", with: " ")
    }

    nonisolated private static func normalizedDomain(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "contact", "contacts", "person":
            return "contacts"
        case "mail", "email", "sender":
            return "mail"
        case "calendar", "event", "events":
            return "calendar"
        default:
            return "auto"
        }
    }

    nonisolated private static func normalizedText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9@._+ -]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func normalizedPhoneNumber(_ value: String) -> String {
        value.replacingOccurrences(of: "[^0-9+]+", with: "", options: .regularExpression)
    }

    nonisolated private static func escapeJSONString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
