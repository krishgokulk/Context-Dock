import Foundation
import SQLite3
import Testing

@testable import Context_Dock

/// A live app's newest rows sit in its -wal until it checkpoints; the snapshot must see them.
@Suite("SQLite snapshot")
struct SQLiteSnapshotTests {
    @Test func seesRowsStillOnlyInTheWriteAheadLog() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("live.db").path

        // The "owning app": WAL mode, no auto-checkpoint, connection held open throughout.
        var writer: OpaquePointer?
        #expect(sqlite3_open(path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        for sql in [
            "PRAGMA journal_mode=WAL", "PRAGMA wal_autocheckpoint=0",
            "CREATE TABLE t(v TEXT)", "INSERT INTO t VALUES('newest')",
        ] {
            #expect(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
        }
        #expect(FileManager.default.fileExists(atPath: path + "-wal"))

        let values = SQLiteSnapshot.read(path) { db -> [String]? in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT v FROM t", -1, &statement, nil) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(statement) }
            var rows: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(String(cString: sqlite3_column_text(statement, 0)))
            }
            return rows
        }
        #expect(values == ["newest"])
    }
}
