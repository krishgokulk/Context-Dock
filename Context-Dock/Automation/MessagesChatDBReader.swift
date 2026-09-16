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

    private static func data(fromHex hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Modern Messages rows frequently leave `message.text` empty and keep the visible
    /// string inside the legacy typedstream stored in `attributedBody`. The archive's text
    /// remains a contiguous UTF-8 run, so extract human-looking runs without attempting to
    /// instantiate an untrusted archived object.
    static func visibleText(textHex: String, attributedHex: String) -> String {
        if let data = data(fromHex: textHex),
            let text = String(data: data, encoding: .utf8), !text.isEmpty
        {
            return text
        }
        guard let data = data(fromHex: attributedHex), !data.isEmpty else { return "" }
        let decoded = String(decoding: data, as: UTF8.self)
        let ignored = [
            "streamtyped", "NSMutableAttributedString", "NSAttributedString", "NSString",
            "NSDictionary", "NSObject", "NSFont", "NSColor", "__kIM", "NSNumber",
        ]
        return decoded
            .components(separatedBy: CharacterSet.controlCharacters
                .union(.illegalCharacters))
            .flatMap { $0.components(separatedBy: "\u{FFFD}") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { candidate in
                candidate.count >= 2
                    && !ignored.contains(where: { candidate.contains($0) })
                    && candidate.rangeOfCharacter(from: .letters.union(.decimalDigits)) != nil
            }
            .max(by: { $0.count < $1.count }) ?? ""
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
            SELECT m.is_from_me, HEX(COALESCE(CAST(m.text AS BLOB),X'')), m.date,
                   COALESCE(h.id,''), HEX(COALESCE(m.attributedBody,X''))
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            \(whereClause)
            ORDER BY m.date DESC
            LIMIT \(capped);
            """
        guard let rows = query(sql) else { return nil }
        return rows.compactMap { cols -> MessageRow? in
            guard cols.count >= 5, let raw = Double(cols[2]) else { return nil }
            return MessageRow(
                fromMe: cols[0] == "1",
                text: visibleText(textHex: cols[1], attributedHex: cols[4]),
                date: date(fromRaw: raw),
                handle: cols[3]
            )
        }
    }

    /// Search message bodies and handles without launching or controlling Messages.
    static func search(_ phrase: String, limit: Int = 30) -> [MessageRow]? {
        let term = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let capped = max(1, min(limit, 100))
        let sql = """
            SELECT m.is_from_me, HEX(COALESCE(CAST(m.text AS BLOB),X'')), m.date,
                   COALESCE(h.id,''), HEX(COALESCE(m.attributedBody,X''))
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            ORDER BY m.date DESC
            LIMIT 10000;
            """
        guard let rows = query(sql) else { return nil }
        return rows.compactMap { cols -> MessageRow? in
            guard cols.count >= 5, let raw = Double(cols[2]) else { return nil }
            let body = visibleText(textHex: cols[1], attributedHex: cols[4])
            guard body.localizedCaseInsensitiveContains(term)
                    || cols[3].localizedCaseInsensitiveContains(term)
            else { return nil }
            return MessageRow(fromMe: cols[0] == "1", text: body,
                              date: date(fromRaw: raw), handle: cols[3])
        }.prefix(capped).map { $0 }
    }

    static func formatted(_ rows: [MessageRow]) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return rows.map { row in
            let who = row.handle.isEmpty ? "(group)" : row.handle
            let direction = row.fromMe ? "you → \(who)" : "\(who) → you"
            return "\(formatter.string(from: row.date)) · \(direction): "
                + row.text.prefix(240)
        }.joined(separator: "\n")
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
