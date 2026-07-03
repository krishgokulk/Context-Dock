import Foundation

// MARK: - Errors

enum AppleNotesError: LocalizedError {
    case notEnabled
    case permissionDenied(String)
    case scriptFailed(String)
    case noteNotFound(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Apple Notes MCP is not enabled. Turn it on in Settings › App Adapters › Notes › Tools."
        case .permissionDenied(let reason):
            return "Apple Notes MCP permission denied: \(reason)"
        case .scriptFailed(let msg):
            return "Notes script error: \(msg)"
        case .noteNotFound(let id):
            return "Note not found: \(id)"
        case .parseError(let msg):
            return "Could not parse Notes response: \(msg)"
        }
    }
}

// MARK: - Service

// All methods run osascript via a temp-file approach on a background thread.
// Never call from @MainActor inline — always await.
final class AppleNotesExecutionService {
    static let shared = AppleNotesExecutionService()

    private init() {}

    // MARK: - Core runner

    // Writes script to a temp file and runs `osascript <file>`.
    // This is more reliable than -e for multi-line scripts and avoids
    // shell escaping issues with line continuations.
    func runScript(_ script: String, timeout: TimeInterval = 30) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("notes_mcp_\(UUID().uuidString).applescript")
                do {
                    try script.write(to: tmpURL, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: tmpURL) }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = [tmpURL.path]
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
                    try process.run()
                    // Hard timeout — a hung osascript (e.g. pending automation-permission
                    // dialog) must never leave the chat spinner running forever.
                    var timedOut = false
                    let killer = DispatchWorkItem {
                        if process.isRunning {
                            timedOut = true
                            process.terminate()
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                    // Drain both pipes WHILE the process runs — output larger than the 64KB
                    // pipe buffer otherwise deadlocks: osascript blocks writing stdout while
                    // we block in waitUntilExit.
                    var outData = Data()
                    var errData = Data()
                    let drainGroup = DispatchGroup()
                    drainGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                        drainGroup.leave()
                    }
                    drainGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        drainGroup.leave()
                    }
                    process.waitUntilExit()
                    drainGroup.wait()
                    killer.cancel()
                    let output = (String(data: outData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let errText = (String(data: errData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if timedOut {
                        continuation.resume(
                            throwing: AppleNotesError.scriptFailed(
                                "Notes did not respond within \(Int(timeout))s. "
                                + "Check Automation permission for Notes in System Settings › Privacy."
                            )
                        )
                    } else if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(
                            throwing: AppleNotesError.scriptFailed(errText.isEmpty ? output : errText)
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Instant note count (single Apple Event — no metadata refresh)

    func noteCount() async throws -> Int {
        let raw = try await runScript(
            "tell application \"Notes\" to return (count of notes) as string",
            timeout: 10
        )
        guard let count = Int(raw) else { throw AppleNotesError.parseError(raw) }
        return count
    }

    // MARK: - Fetch all note metadata (title, folder, snippet — no full body)

    /// Batched: each `... of every note` is ONE Apple Event returning a whole list.
    /// The old per-note loop cost one Apple Event per property per note (plus a full
    /// HTML `body` render each) — minutes for large libraries; this is 5–6 events total.
    /// Snippets come from `plaintext` (cheap, no HTML render); if that property is
    /// unavailable the notes still index with empty snippets.
    func fetchAllMetadata() async throws -> [NoteMetadata] {
        let script = """
        set recSep to character id 30
        tell application "Notes"
            set idList to id of every note
            set nameList to name of every note
            set modList to modification date of every note
            set createdList to creation date of every note
            try
                set folderList to name of container of every note
            on error
                set folderList to {}
            end try
            try
                set bodyList to plaintext of every note
            on error
                set bodyList to {}
            end try
        end tell
        set lineItems to {}
        set n to count of idList
        repeat with i from 1 to n
            set nFolder to ""
            if (count of folderList) is greater than or equal to i then
                set fv to item i of folderList
                if fv is not missing value then set nFolder to fv as string
            end if
            set nSnippet to ""
            if (count of bodyList) is greater than or equal to i then
                set rawBody to item i of bodyList
                if (count of rawBody) > 200 then
                    set nSnippet to text 1 thru 200 of rawBody
                else
                    set nSnippet to rawBody
                end if
            end if
            set end of lineItems to (item i of idList) & "|||" & (item i of nameList) & "|||" & nFolder & "|||" & ((item i of modList) as string) & "|||" & ((item i of createdList) as string) & "|||" & nSnippet
        end repeat
        set AppleScript's text item delimiters to recSep
        set output to lineItems as string
        set AppleScript's text item delimiters to ""
        return output
        """
        let raw = try await runScript(script, timeout: 60)
        return parseMetadataLines(raw)
    }

    // MARK: - Deep body search (case-insensitive, scans full note text — slower than index search)

    func deepSearchBodies(query: String, maxResults: Int = 20) async throws -> [NoteMetadata] {
        let safeQuery = escapeForAppleScript(query)
        let script = """
        set recSep to character id 30
        set qry to "\(safeQuery)"
        set lineItems to {}
        set resultCount to 0
        tell application "Notes"
            repeat with n in every note
                if resultCount is greater than or equal to \(maxResults) then exit repeat
                set matched to false
                ignoring case
                    if (name of n) contains qry then set matched to true
                    if not matched then
                        try
                            if (plaintext of n) contains qry then set matched to true
                        on error
                            if (body of n) contains qry then set matched to true
                        end try
                    end if
                end ignoring
                if matched then
                    set nFolder to ""
                    try
                        set nFolder to name of container of n
                    end try
                    set rawBody to ""
                    try
                        set rawBody to plaintext of n
                    end try
                    if (count of rawBody) > 200 then set rawBody to text 1 thru 200 of rawBody
                    set end of lineItems to (id of n) & "|||" & (name of n) & "|||" & nFolder & "|||" & ((modification date of n) as string) & "|||" & ((creation date of n) as string) & "|||" & rawBody
                    set resultCount to resultCount + 1
                end if
            end repeat
        end tell
        set AppleScript's text item delimiters to recSep
        set output to lineItems as string
        set AppleScript's text item delimiters to ""
        return output
        """
        let raw = try await runScript(script, timeout: 120)
        return parseMetadataLines(raw)
    }

    private func parseMetadataLines(_ raw: String) -> [NoteMetadata] {
        let formatter = AppleScriptDateFormatter.shared
        let recordSeparator = Character(UnicodeScalar(30))
        return raw
            .split(separator: recordSeparator, omittingEmptySubsequences: true)
            .compactMap { line -> NoteMetadata? in
                let parts = String(line).components(separatedBy: "|||")
                guard parts.count >= 6 else { return nil }
                // plaintext snippets can contain newlines — flatten for the one-line index
                let snippet = parts[5...].joined(separator: "|||")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(200)
                return NoteMetadata(
                    id: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    title: parts[1],
                    folder: parts[2],
                    modifiedDate: formatter.date(from: parts[3]) ?? .distantPast,
                    createdDate: formatter.date(from: parts[4]) ?? .distantPast,
                    snippet: stripHTML(String(snippet))
                )
            }
    }

    // MARK: - Read full note body

    func readNote(id: String) async throws -> (title: String, folder: String, body: String, modified: Date) {
        let escapedID = escapeForAppleScript(id)
        let script = """
        tell application "Notes"
            set n to note id "\(escapedID)"
            set nTitle to name of n
            set nBody to body of n
            set nMod to modification date of n
            set nFolder to ""
            try
                set nFolder to name of container of n
            end try
            return nTitle & "|||" & nFolder & "|||" & (nMod as string) & "|||" & nBody
        end tell
        """
        let raw = try await runScript(script)
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 4 else { throw AppleNotesError.parseError(raw) }
        let body = parts.dropFirst(3).joined(separator: "|||")
        return (
            title: parts[0],
            folder: parts[1],
            body: body,
            modified: AppleScriptDateFormatter.shared.date(from: parts[2]) ?? Date()
        )
    }

    // MARK: - Create note

    func createNote(title: String, body: String, folder: String?) async throws -> String {
        let safeTitle = escapeForAppleScript(title)
        let safeBody = escapeForAppleScript(body)
        let script: String
        if let folder, !folder.isEmpty {
            let safeFolder = escapeForAppleScript(folder)
            script = """
            tell application "Notes"
                set targetFolder to first folder whose name is "\(safeFolder)"
                set newNote to make new note in targetFolder with properties {name:"\(safeTitle)", body:"\(safeBody)"}
                return id of newNote
            end tell
            """
        } else {
            script = """
            tell application "Notes"
                set newNote to make new note with properties {name:"\(safeTitle)", body:"\(safeBody)"}
                return id of newNote
            end tell
            """
        }
        return try await runScript(script)
    }

    // MARK: - Append to note

    func appendToNote(id: String, text: String) async throws {
        let escapedID = escapeForAppleScript(id)
        let safeText = escapeForAppleScript(text)
        let script = """
        tell application "Notes"
            set n to note id "\(escapedID)"
            set existingBody to body of n
            set body of n to existingBody & "<br>\(safeText)"
        end tell
        """
        _ = try await runScript(script)
    }

    // MARK: - Update note

    func updateNote(id: String, title: String?, body: String?) async throws {
        let escapedID = escapeForAppleScript(id)
        var statements: [String] = []
        if let title {
            statements.append("set name of n to \"\(escapeForAppleScript(title))\"")
        }
        if let body {
            statements.append("set body of n to \"\(escapeForAppleScript(body))\"")
        }
        guard !statements.isEmpty else { return }
        let script = """
        tell application "Notes"
            set n to note id "\(escapedID)"
            \(statements.joined(separator: "\n    "))
        end tell
        """
        _ = try await runScript(script)
    }

    // MARK: - Delete note

    func deleteNote(id: String) async throws {
        let escapedID = escapeForAppleScript(id)
        let script = """
        tell application "Notes"
            delete (note id "\(escapedID)")
        end tell
        """
        _ = try await runScript(script)
    }

    // MARK: - List folders

    func listFolders() async throws -> [String] {
        let script = """
        set lf to (ASCII character 10)
        set output to ""
        tell application "Notes"
            repeat with f in every folder
                set output to output & (name of f) & lf
            end repeat
        end tell
        return output
        """
        let raw = try await runScript(script)
        return raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Helpers

    func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    func stripHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Date formatter (locale-tolerant)

private final class AppleScriptDateFormatter {
    static let shared = AppleScriptDateFormatter()
    private let formatters: [DateFormatter]

    private init() {
        let formats = [
            "EEEE, MMMM d, yyyy 'at' h:mm:ss a",
            "EEEE, d MMMM yyyy 'at' HH:mm:ss",
            "MMMM d, yyyy 'at' h:mm:ss a",
            "d MMMM yyyy 'at' HH:mm:ss",
            "M/d/yy, h:mm a",
            "d/M/yy, HH:mm",
        ]
        var fmts: [DateFormatter] = []
        for fmt in formats {
            for locale in [Locale(identifier: "en_US"), Locale.current] {
                let f = DateFormatter()
                f.dateFormat = fmt
                f.locale = locale
                fmts.append(f)
            }
        }
        formatters = fmts
    }

    func date(from string: String) -> Date? {
        for f in formatters {
            if let d = f.date(from: string) { return d }
        }
        return nil
    }
}
