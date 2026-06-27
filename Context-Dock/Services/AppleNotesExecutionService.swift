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
            return "Apple Notes MCP is not enabled. Turn it on in Settings › Apple Notes."
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

// All methods run osascript via Process on a background thread.
// Never call from @MainActor inline — always await.
final class AppleNotesExecutionService {
    static let shared = AppleNotesExecutionService()

    private init() {}

    // MARK: - Core runner (background thread via Process)

    func runScript(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = (String(data: outData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let errText = (String(data: errData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if process.terminationStatus == 0 {
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

    // MARK: - Fetch all note metadata (title, folder, snippet — no full body)

    func fetchAllMetadata() async throws -> [NoteMetadata] {
        let script = """
        set output to ""
        tell application "Notes"
            repeat with n in every note
                set nId to id of n
                set nTitle to name of n
                set rawBody to body of n
                set nFolder to ""
                set nMod to modification date of n
                set nCreated to creation date of n
                try
                    set nFolder to name of container of n
                end try
                set bodyLen to count of rawBody
                if bodyLen > 200 then
                    set nSnippet to text 1 thru 200 of rawBody
                else
                    set nSnippet to rawBody
                end if
                set output to output & nId & "|||" & nTitle & "|||" & nFolder & "|||" \\
                    & (nMod as string) & "|||" & (nCreated as string) & "|||" & nSnippet & "\n"
            end repeat
        end tell
        return output
        """
        let raw = try await runScript(script)
        return parseMetadataLines(raw)
    }

    private func parseMetadataLines(_ raw: String) -> [NoteMetadata] {
        let formatter = AppleScriptDateFormatter.shared
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> NoteMetadata? in
                let parts = String(line).components(separatedBy: "|||")
                guard parts.count >= 6 else { return nil }
                let snippet = parts[5...].joined(separator: "|||").prefix(200)
                return NoteMetadata(
                    id: parts[0],
                    title: parts[1],
                    folder: parts[2],
                    modifiedDate: formatter.date(from: parts[3]) ?? .distantPast,
                    createdDate: formatter.date(from: parts[4]) ?? .distantPast,
                    snippet: stripHTML(String(snippet))
                )
            }
    }

    // MARK: - Read full note body (requires approval upstream)

    func readNote(id: String) async throws -> (title: String, folder: String, body: String, modified: Date) {
        let escapedID = id.replacingOccurrences(of: "\"", with: "\\\"")
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
        let escapedID = id.replacingOccurrences(of: "\"", with: "\\\"")
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
        let escapedID = id.replacingOccurrences(of: "\"", with: "\\\"")
        var setParts: [String] = []
        if let title {
            setParts.append("set name of n to \"\(escapeForAppleScript(title))\"")
        }
        if let body {
            setParts.append("set body of n to \"\(escapeForAppleScript(body))\"")
        }
        guard !setParts.isEmpty else { return }
        let script = """
        tell application "Notes"
            set n to note id "\(escapedID)"
            \(setParts.joined(separator: "\n    "))
        end tell
        """
        _ = try await runScript(script)
    }

    // MARK: - Delete note

    func deleteNote(id: String) async throws {
        let escapedID = id.replacingOccurrences(of: "\"", with: "\\\"")
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
        set output to ""
        tell application "Notes"
            repeat with f in every folder
                set output to output & (name of f) & "\n"
            end repeat
        end tell
        return output
        """
        let raw = try await runScript(script)
        return raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Helpers

    private func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AppleScript date formatter (singleton to avoid repeated construction)

private final class AppleScriptDateFormatter {
    static let shared = AppleScriptDateFormatter()

    private let formatters: [DateFormatter]

    private init() {
        // AppleScript returns locale-sensitive strings; try several common formats
        let formats = [
            "EEEE, MMMM d, yyyy 'at' h:mm:ss a",
            "EEEE, d MMMM yyyy 'at' HH:mm:ss",
            "MMMM d, yyyy 'at' h:mm:ss a",
        ]
        formatters = formats.map { fmt in
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US")
            return f
        }
    }

    func date(from string: String) -> Date? {
        for f in formatters {
            if let d = f.date(from: string) { return d }
        }
        return nil
    }
}
