// SQLiteSnapshot.swift
// Context-Dock
//
// Reads another app's live SQLite database (Safari History.db, Messages chat.db,
// browser histories) as of right now. Those apps keep their newest rows in the
// `-wal` file until they checkpoint, which Safari and Messages do rarely, and an
// `immutable=1` open of the live file ignores it — "today" found nothing, the newest
// Safari visit read being a day old (owner 2026-10-18). So: copy the database and its
// write-ahead log into a fresh folder, open the copy read-write so SQLite applies the
// log, delete the folder afterwards. The copy never locks the owning app's file, and
// on APFS `copyItem` clones, so even a large chat.db costs next to nothing.

import Foundation
import SQLite3

enum SQLiteSnapshot {
    /// Runs `body` with the path of a fresh copy of `path` plus its `-wal`.
    /// Nil when the database is missing or cannot be copied.
    // ponytail: the two copies are not atomic; a checkpoint landing between them can
    // drop the newest rows from that one read (never corrupts — SQLite checks WAL salts).
    nonisolated static func withCopy<T>(of path: String, _ body: (String) -> T?) -> T? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let folder = fm.temporaryDirectory.appendingPathComponent(
            "sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(atPath: path, toPath: copy)
            if fm.fileExists(atPath: path + "-wal") {
                try fm.copyItem(atPath: path + "-wal", toPath: copy + "-wal")
            }
        } catch {
            return nil
        }
        return body(copy)
    }

    /// Runs `body` with an open connection to a fresh copy of `path` (see `withCopy`).
    nonisolated static func read<T>(_ path: String, _ body: (OpaquePointer) -> T?) -> T? {
        withCopy(of: path) { copy in
            var db: OpaquePointer?
            guard sqlite3_open_v2(copy, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db
            else {
                sqlite3_close(db)
                return nil
            }
            defer { sqlite3_close(db) }
            return body(db)
        }
    }
}
