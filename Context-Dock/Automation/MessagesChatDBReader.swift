// MessagesChatDBReader.swift
// Context-Dock
//
// Reads Messages from the local chat.db SQLite store. Modern macOS restricts the
// Messages AppleScript dictionary (name of chat / content of message return
// `missing value`), so AppleScript can no longer read conversations — that's the
// "missing value | snippet:" bug. chat.db is the reliable source used by every
// working Messages tool. Read-only, immutable open, no writes. Requires Full Disk
// Access (the same permission the rest of DoraX's local readers use).

import Foundation

enum MessagesChatDBReader {
    struct MessageRow {
        let fromMe: Bool
        let text: String
        let date: Date
        let handle: String  // the other party (phone/email); empty for group
    }

    static var databaseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Messages/chat.db")
    }

    static var isAccessible: Bool {
        FileManager.default.isReadableFile(atPath: databaseURL.path)
    }

    // Apple epoch (2001-01-01) → Unix epoch. chat.db `date` is nanoseconds since
    // Apple epoch on modern macOS (older builds used seconds — normalize both).
    private static let appleEpochOffset: Double = 978_307_200

    private static func date(fromRaw raw: Double) -> Date {
        let seconds = raw > 1_000_000_000_000 ? raw / 1_000_000_000 : raw
        return Date(timeIntervalSince1970: seconds + appleEpochOffset)
    }

    /// Run a SQL query against a read-only, immutable open of chat.db via the
    /// system sqlite3 CLI. Rows are `|`-separated. Returns nil when unreadable.
    private static func query(_ sql: String) -> [[String]]? {
        guard isAccessible else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly", "-separator", "\u{1}",
            "file:\(databaseURL.path)?immutable=1", sql,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let output = String(data: data, encoding: .utf8)
        else { return nil }
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.components(separatedBy: "\u{1}") }
    }

    /// Recent messages (newest first). Optional case-insensitive handle filter.
    static func recent(limit: Int = 20, contact: String = "") -> [MessageRow]? {
        let capped = max(1, min(limit, 60))
        let filter = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        let whereClause =
            filter.isEmpty
            ? ""
            : "WHERE h.id LIKE '%\(filter.replacingOccurrences(of: "'", with: "''"))%' "
        let sql = """
            SELECT m.is_from_me, COALESCE(m.text,''), m.date, COALESCE(h.id,'')
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            \(whereClause)
            ORDER BY m.date DESC
            LIMIT \(capped);
            """
        guard let rows = query(sql) else { return nil }
        return rows.compactMap { cols -> MessageRow? in
            guard cols.count >= 4, let raw = Double(cols[2]) else { return nil }
            return MessageRow(
                fromMe: cols[0] == "1",
                text: cols[1],
                date: date(fromRaw: raw),
                handle: cols[3]
            )
        }
    }

    /// Messages you SENT since the start of today: total + distinct recipients.
    static func sentToday() -> (count: Int, recipients: [String])? {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let appleSeconds = startOfDay.timeIntervalSince1970 - appleEpochOffset
        // Compare in seconds regardless of ns/seconds storage.
        let sql = """
            SELECT COUNT(*), COALESCE(GROUP_CONCAT(DISTINCT h.id),'')
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.is_from_me = 1
              AND (CASE WHEN m.date > 1000000000000 THEN m.date/1000000000 ELSE m.date END) >= \(Int(appleSeconds));
            """
        guard let rows = query(sql), let first = rows.first, first.count >= 2,
            let count = Int(first[0])
        else { return nil }
        let recipients =
            first[1].isEmpty
            ? []
            : first[1].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        return (count, recipients)
    }
}
