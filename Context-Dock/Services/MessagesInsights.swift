// MessagesInsights.swift
// Context-Dock
//
// Counting, which none of the Messages tools could do.
//
// Asked "who do I talk to most", the turn ran the CLI, got a list of recent conversations
// with most contact names missing, and said it could not tell. It was right. Every tool
// Messages had — `imsg chats`, the MCP "List Recent Messages Conversations", "Search in
// Messages" — answers "what happened lately". None of them counts anything, and "most" is a
// count. The model was asked to rank from a list that carries no ranking, and the honest
// outcome of that is exactly the shrug the user saw.
//
// So the capability that was missing gets written rather than the prompt tuned. This reads
// the message database directly, groups by the other party and orders by volume, which is the
// question as asked.
//
// It also fails loudly. chat.db needs Full Disk Access, and without it the read is refused by
// the system — an answer of "I can't tell" for a permission problem sends the user looking for
// the wrong thing entirely.

import Contacts
import Foundation

enum MessagesInsights {

    struct Correspondent {
        /// The phone number or email the messages are with.
        let handle: String
        /// The person's name, when Contacts knows them.
        let name: String?
        let messageCount: Int
        let sentByUser: Int
        let lastMessage: Date?

        var display: String { name ?? handle }
    }

    enum Failure: Error {
        /// The database exists and macOS refused the read.
        case needsFullDiskAccess
        case unreadable(String)
    }

    static var databaseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Messages/chat.db")
    }

    /// Who the user exchanges the most messages with, busiest first.
    ///
    /// - Parameter days: how far back to count. Nil counts everything, which is the right
    ///   default for "most often" and the wrong one for "lately".
    static func topCorrespondents(limit: Int = 10, days: Int? = nil) throws -> [Correspondent] {
        let database = databaseURL
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw Failure.unreadable("No Messages database on this Mac.")
        }
        guard FileManager.default.isReadableFile(atPath: database.path) else {
            throw Failure.needsFullDiskAccess
        }

        // Apple stores message dates as nanoseconds since 2001-01-01.
        let cutoffClause: String
        if let days {
            let seconds = Date().addingTimeInterval(-Double(days) * 86_400)
                .timeIntervalSinceReferenceDate
            cutoffClause = "WHERE m.date > \(Int(seconds)) * 1000000000"
        } else {
            cutoffClause = ""
        }

        let query = """
            SELECT h.id,
                   COUNT(*),
                   SUM(m.is_from_me),
                   MAX(m.date)
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            \(cutoffClause)
            GROUP BY h.id
            ORDER BY COUNT(*) DESC
            LIMIT \(max(1, min(limit, 50)));
            """

        // Opened read-only through a file: URI, so a question about the user's messages can
        // never write to the store that holds them.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly", "-separator", "\u{1}", database.path, query,
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            // "authorization denied" is what macOS says when the app lacks Full Disk Access,
            // and it is the single most likely reason this fails on a working Mac.
            if errorText.lowercased().contains("authorization denied")
                || errorText.lowercased().contains("unable to open")
            {
                throw Failure.needsFullDiskAccess
            }
            throw Failure.unreadable(errorText.isEmpty ? "sqlite3 failed" : errorText)
        }

        let names = contactNames()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .compactMap { line -> Correspondent? in
                let parts = line.split(separator: "\u{1}", omittingEmptySubsequences: false)
                guard parts.count >= 4, let count = Int(parts[1]) else { return nil }
                let handle = String(parts[0])
                let appleDate = Double(parts[3]) ?? 0
                return Correspondent(
                    handle: handle,
                    name: names[normalized(handle)],
                    messageCount: count,
                    sentByUser: Int(parts[2]) ?? 0,
                    lastMessage: appleDate > 0
                        ? Date(timeIntervalSinceReferenceDate: appleDate / 1_000_000_000) : nil)
            }
    }

    /// A readable answer, or a readable reason there isn't one.
    static func topCorrespondentsReport(limit: Int = 10, days: Int? = nil) -> String {
        do {
            let people = try topCorrespondents(limit: limit, days: days)
            guard !people.isEmpty else {
                return "No messages found in the period asked about."
            }
            let period = days.map { "the last \($0) days" } ?? "the whole history"
            var lines = ["Most-messaged contacts, by message count over \(period):"]
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            for (index, person) in people.enumerated() {
                let last = person.lastMessage.map { " · last on \(formatter.string(from: $0))" } ?? ""
                let identified = person.name == nil ? " (not in Contacts)" : ""
                lines.append(
                    "\(index + 1). \(person.display)\(identified) — \(person.messageCount) messages"
                        + " (\(person.sentByUser) from you)\(last)")
            }
            return lines.joined(separator: "\n")
        } catch Failure.needsFullDiskAccess {
            // Named precisely, because "I can't tell" sends the user hunting for the wrong
            // problem. This one is two clicks away from fixed.
            return "Messages counts need Full Disk Access: macOS refuses to let DoraX read "
                + "~/Library/Messages/chat.db without it. Grant it in System Settings → "
                + "Privacy & Security → Full Disk Access, then ask again. Do not guess a "
                + "ranking from a list of recent conversations — recency is not frequency."
        } catch {
            return "Could not read the Messages database: \(error.localizedDescription)"
        }
    }

    // MARK: - Names

    /// Phone numbers and emails to names, from the user's own address book.
    ///
    /// Without this the answer is a list of phone numbers, which is a correct ranking of
    /// people the user cannot recognise.
    private static func contactNames() -> [String: String] {
        let store = CNContactStore()
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [:] }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        var map: [String: String] = [:]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard !name.isEmpty else { return }
            for number in contact.phoneNumbers {
                map[normalized(number.value.stringValue)] = name
            }
            for email in contact.emailAddresses {
                map[normalized(email.value as String)] = name
            }
        }
        return map
    }

    /// Handles arrive as "+44 7700 900123", "+447700900123" and "name@example.com"; the
    /// address book stores them however the user typed them.
    private static func normalized(_ handle: String) -> String {
        let lowered = handle.lowercased()
        if lowered.contains("@") { return lowered }
        return lowered.filter(\.isNumber).suffix(10).description
    }
}
