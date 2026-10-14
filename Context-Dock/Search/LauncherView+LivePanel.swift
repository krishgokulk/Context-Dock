import AppKit
import Foundation
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI

extension LauncherView {
    // MARK: - Live Panel (slides in from right like Claude's artifact panel)





    /// Helper — show panel with a specific mode + slide-in animation
    func showLivePanel(_ mode: LivePanelMode) {
        livePanelMode = mode
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            livePanelVisible = true
        }
    }














    /// Strips raw tool-call syntax that the AI accidentally echoes as plain text.
    static func stripLeakedToolCalls(_ text: String) -> String {
        var result = text
        let patterns = [
            // Function-call style: run_command(...) or spawn_worker(...)
            #"run_command\s*\([\s\S]*?\)"#,
            #"spawn_worker\s*\([\s\S]*?\)"#,
            // Any JSON object with a "name" key — catches invented tool names like {"name":"remind",...}
            #"\{[\s\S]*?"name"\s*:\s*"[^"]*"[\s\S]*?"parameters"[\s\S]*?\}"#,
            #"\{[\s\S]*?"name"\s*:\s*"[^"]*"[\s\S]*?"input"[\s\S]*?\}"#,
            // Also catch preamble lines like "I will call the X tool with..."
            #"(?m)^.*?I will (call|use|invoke).*?(tool|function|script).*\n?"#,
            #"(?m)^.*?(function call|tool call|following call).*\n?"#,
            // Fenced code blocks that are just tool calls
            #"```json[\s\S]*?```"#,
            #"```[\s\S]*?```"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators])
            {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect if a shell command created/wrote an output file.
    /// Returns the URL if found and the file exists.
    func detectCreatedFile(command: String, output: String) -> URL? {
        let expandPath: (String) -> URL? = { raw in
            guard !raw.isEmpty else { return nil }
            let path = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        // -o flag: pandoc -o out.pdf, ffmpeg -o out.mp4, etc.
        if let range = command.range(of: #"-o\s+(\S+)"#, options: .regularExpression) {
            let full = String(command[range])
            let parts = full.components(separatedBy: .whitespaces)
            if parts.count >= 2, let url = expandPath(parts[1]) { return url }
        }

        // Shell redirect: cmd > file.txt
        if let range = command.range(of: #">\s*(\S+)"#, options: .regularExpression) {
            let full = String(command[range])
            let parts = full.components(separatedBy: .whitespaces)
            if parts.count >= 2, let url = expandPath(parts[1]) { return url }
        }

        // Common "saved to PATH" / "written to PATH" phrases in output
        for marker in [
            "saved to ", "created: ", "written to ", "output: ", "→ ", "=> ", "exported to ",
        ] {
            if let idx = output.range(of: marker, options: .caseInsensitive)?.upperBound {
                let after = String(output[idx...])
                let candidate = after.components(separatedBy: .whitespacesAndNewlines).first ?? ""
                if let url = expandPath(candidate) { return url }
            }
        }

        // Any absolute path in the output that is a file (not a directory)
        let pathPattern = #"(/[^\s\"']+\.[a-zA-Z0-9]{1,8})"#
        if let matches = output.range(of: pathPattern, options: .regularExpression) {
            let candidate = String(output[matches])
            if let url = expandPath(candidate),
                !url.hasDirectoryPath
            {
                return url
            }
        }

        return nil
    }

    /// Master dispatcher: routes command output to the right panel parser based on panel type.
    func parseCommandOutputForPanel(command: String, output: String, panelKey: String)
        -> [LivePanelMode.ResultEntry]
    {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let cmd = command.trimmingCharacters(in: .whitespaces).lowercased()

        // ── Reminders (rem CLI) ─────────────────────────────────────────
        if panelKey == "reminders" || cmd.hasPrefix("rem ") {
            return parseRemOutput(output)
        }

        // ── Process list (ps, pgrep, top -l 1 | grep) ──────────────────
        if cmd.hasPrefix("ps ") || cmd.hasPrefix("ps\n") || cmd == "ps"
            || cmd.hasPrefix("pgrep") || cmd.contains("| ps")
        {
            return parseProcessOutput(output)
        }

        // ── Network (netstat, lsof -i, nmap) ───────────────────────────
        if cmd.hasPrefix("netstat") || cmd.hasPrefix("lsof -i") || cmd.hasPrefix("nmap") {
            return parseNetworkOutput(command: command, output: output)
        }

        // ── Brew (brew list, brew outdated, brew search) ────────────────
        if cmd.hasPrefix("brew ") {
            return parseBrewOutput(command: command, output: output)
        }

        // ── Git (git log, git status, git branch, git diff --stat) ─────
        if cmd.hasPrefix("git ") {
            return parseGitOutput(command: command, output: output)
        }

        // ── Generic line list (any output with ≥3 lines that isn't JSON) ─
        // Falls through to file parser first, then generic
        let fileEntries = parseOutputForFileResults(command: command, output: output)
        if !fileEntries.isEmpty { return fileEntries }

        return parseGenericListOutput(command: command, output: output, panelKey: panelKey)
    }

    // ── Reminders parser ───────────────────────────────────────────────

    func parseRemOutput(_ output: String) -> [LivePanelMode.ResultEntry] {
        // rem list output: "[ ] Buy milk   due: tomorrow" or "[x] Call mom"
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("No reminders") && !$0.hasPrefix("---") }
        guard !lines.isEmpty else { return [] }

        return lines.compactMap { line -> LivePanelMode.ResultEntry? in
            let isDone =
                line.hasPrefix("[x]") || line.hasPrefix("[X]") || line.hasPrefix("✓")
                || line.hasPrefix("✅")
            let isPending = line.hasPrefix("[ ]") || line.hasPrefix("○") || line.hasPrefix("•")

            guard isDone || isPending else {
                // Still treat plain lines as reminder entries if they look like tasks
                if line.count < 3 || line.hasPrefix("{") { return nil }
                return LivePanelMode.ResultEntry(
                    name: line, path: "", subtitle: "", icon: "checkmark.circle")
            }

            var text = line
            // Strip leading marker
            for prefix in ["[x] ", "[X] ", "[ ] ", "✓ ", "✅ ", "○ ", "• "] {
                if text.hasPrefix(prefix) {
                    text = String(text.dropFirst(prefix.count))
                    break
                }
            }

            // Extract "due: ..." from end
            var subtitle = ""
            if let dueRange = text.range(of: #"\s+due:\s*.+"#, options: .regularExpression) {
                subtitle = String(text[dueRange]).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "due: ", with: "Due: ")
                text = String(text[..<dueRange.lowerBound])
            }

            let icon = isDone ? "checkmark.circle.fill" : "circle"
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return LivePanelMode.ResultEntry(name: name, path: "", subtitle: subtitle, icon: icon)
        }
    }

    // ── Process parser ─────────────────────────────────────────────────

    func parseProcessOutput(_ output: String) -> [LivePanelMode.ResultEntry] {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return [] }

        var entries: [LivePanelMode.ResultEntry] = []
        // Detect header line (PID USER %CPU %MEM COMMAND etc.)
        let hasHeader =
            lines.first?.uppercased().contains("PID") == true
            || lines.first?.uppercased().contains("COMMAND") == true

        for (i, line) in lines.enumerated() {
            if i == 0 && hasHeader { continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            // Standard ps -ef format: UID PID PPID C STIME TTY TIME CMD
            // ps aux format: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
            let pid: String
            let cmdName: String
            var subtitle = ""

            if let pidInt = Int(parts[1]) {
                // ps aux: USER PID %CPU %MEM ... COMMAND
                pid = "\(pidInt)"
                let cpu = parts.count > 2 ? parts[2] : ""
                let mem = parts.count > 3 ? parts[3] : ""
                cmdName =
                    parts.count > 10
                    ? (parts[10...].joined(separator: " ") as NSString).lastPathComponent : parts[1]
                if !cpu.isEmpty { subtitle = "CPU: \(cpu)%  MEM: \(mem)%" }
            } else if let pidInt = Int(parts[0]) {
                // simple format: PID NAME
                pid = "\(pidInt)"
                cmdName =
                    parts.count > 1
                    ? (parts[1...].joined(separator: " ") as NSString).lastPathComponent : line
            } else {
                // last column is command
                let rawCmd = parts.last ?? line
                cmdName = (rawCmd as NSString).lastPathComponent
                pid = parts.count > 1 ? parts[1] : ""
                subtitle = pid.isEmpty ? "" : "PID \(pid)"
            }

            let name = (cmdName as NSString).lastPathComponent
            guard !name.isEmpty, name != "0", name.count > 1 else { continue }
            if subtitle.isEmpty && !pid.isEmpty { subtitle = "PID \(pid)" }

            entries.append(
                LivePanelMode.ResultEntry(
                    name: name, path: "", subtitle: subtitle,
                    icon: "cpu"))
        }
        return entries
    }

    // ── Network parser ─────────────────────────────────────────────────

    func parseNetworkOutput(command: String, output: String) -> [LivePanelMode.ResultEntry]
    {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Proto") && !$0.hasPrefix("Active") }

        return lines.prefix(30).compactMap { line -> LivePanelMode.ResultEntry? in
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 4 else { return nil }
            // netstat: Proto RecvQ SendQ LocalAddr ForeignAddr State
            let local = parts.count > 3 ? parts[3] : parts[1]
            let state = parts.last ?? ""
            return LivePanelMode.ResultEntry(
                name: local, path: "", subtitle: state,
                icon: "network")
        }
    }

    // ── Brew parser ────────────────────────────────────────────────────

    func parseBrewOutput(command: String, output: String) -> [LivePanelMode.ResultEntry] {
        let cmd = command.lowercased()
        let isOutdated = cmd.contains("outdated")
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.hasPrefix("Warning") }
        guard !lines.isEmpty else { return [] }

        return lines.compactMap { line -> LivePanelMode.ResultEntry? in
            let parts = line.components(separatedBy: .whitespaces)
            let name = parts.first ?? line
            guard !name.isEmpty, name.count > 1 else { return nil }
            let subtitle: String
            if isOutdated && parts.count >= 3 {
                subtitle = "\(parts[1]) → \(parts[2])"  // current → latest
            } else if parts.count > 1 {
                subtitle = parts.dropFirst().joined(separator: " ")
            } else {
                subtitle = ""
            }
            return LivePanelMode.ResultEntry(
                name: name, path: "",
                subtitle: subtitle,
                icon: isOutdated ? "arrow.up.circle" : "shippingbox")
        }
    }

    // ── Git parser ─────────────────────────────────────────────────────

    func parseGitOutput(command: String, output: String) -> [LivePanelMode.ResultEntry] {
        let cmd = command.lowercased()
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        if cmd.contains("git log") {
            // "abc1234 Fix bug in login" or "commit abc1234\n Author: ...\n    message"
            return lines.prefix(20).compactMap { line -> LivePanelMode.ResultEntry? in
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { return nil }
                let hash = String(parts[0].prefix(7))
                let msg = parts.dropFirst().joined(separator: " ")
                return LivePanelMode.ResultEntry(
                    name: msg, path: "", subtitle: hash, icon: "arrow.triangle.branch")
            }
        } else if cmd.contains("git branch") {
            return lines.compactMap { line -> LivePanelMode.ResultEntry? in
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                guard !name.isEmpty else { return nil }
                let isCurrent = line.hasPrefix("*")
                return LivePanelMode.ResultEntry(
                    name: name, path: "",
                    subtitle: isCurrent ? "current" : "",
                    icon: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
            }
        } else if cmd.contains("git diff --stat") || cmd.contains("git status") {
            return lines.compactMap { line -> LivePanelMode.ResultEntry? in
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard let name = parts.first, name.contains(".") || name.contains("/") else {
                    return nil
                }
                let stat = parts.dropFirst().joined(separator: " ")
                return LivePanelMode.ResultEntry(
                    name: name, path: "", subtitle: stat,
                    icon: "doc.badge.ellipsis")
            }
        }
        return parseGenericListOutput(command: command, output: output, panelKey: "git")
    }

    // ── Generic list parser ────────────────────────────────────────────

    func parseGenericListOutput(command: String, output: String, panelKey: String)
        -> [LivePanelMode.ResultEntry]
    {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Don't show generic results for conversational / single-line outputs
        guard lines.count >= 3 else { return [] }
        // Skip JSON blobs
        if output.trimmingCharacters(in: .whitespaces).hasPrefix("{") { return [] }
        if output.trimmingCharacters(in: .whitespaces).hasPrefix("[") { return [] }

        // Pick icon based on panel key
        let icon: String = {
            switch panelKey {
            case "calendar": return "calendar"
            case "notes": return "note.text"
            case "mail": return "envelope"
            case "contacts": return "person.crop.circle"
            case "music": return "music.note"
            default: return "list.bullet"
            }
        }()

        return lines.prefix(50).compactMap { line -> LivePanelMode.ResultEntry? in
            // Skip separator lines and very short lines
            guard line.count > 2,
                !line.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "─" }),
                !line.hasPrefix("---"), !line.hasPrefix("===")
            else { return nil }

            // Split "name: detail" or "name — detail" into name + subtitle
            let separators = ["\t", " — ", " - ", ": "]
            for sep in separators {
                if let range = line.range(of: sep) {
                    let name = String(line[..<range.lowerBound]).trimmingCharacters(
                        in: .whitespaces)
                    let sub = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        return LivePanelMode.ResultEntry(
                            name: name, path: "", subtitle: sub, icon: icon)
                    }
                }
            }
            return LivePanelMode.ResultEntry(name: line, path: "", subtitle: "", icon: icon)
        }
    }

    /// Parses shell command output for file/path lists to display in the live panel.
    func parseOutputForFileResults(command: String, output: String) -> [LivePanelMode
        .ResultEntry]
    {
        let cmd = command.trimmingCharacters(in: .whitespaces).lowercased()

        // du is a size-query command, not a file lister — keep result in chat only
        if cmd.hasPrefix("du ") || cmd == "du" { return [] }
        // stat, wc, grep -c, etc. — single-line summaries, not file lists
        if cmd.hasPrefix("stat ") || cmd.hasPrefix("wc ") { return [] }

        let isListCommand =
            cmd.hasPrefix("find ") || cmd.hasPrefix("ls") || cmd.hasPrefix("locate ")
            || cmd.contains(" find ") || cmd.contains("| find") || cmd.contains("| ls")
            || cmd.contains("-name ") || cmd.contains("-type f")

        let rawLines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Detect `ls -l` / `ls -lt` format: lines like "-rw-r--r-- 1 user staff 123456 Mar 10 file.jpg"
        let isLsLongFormat =
            rawLines.first?.range(of: #"^[-dlrwxst]{10}\s"#, options: .regularExpression) != nil
            || rawLines.first?.lowercased().hasPrefix("total") == true

        // Extract context folder path for resolving relative names
        let contextFolder: String? = {
            // From the command itself: find /path ... → /path
            if cmd.hasPrefix("find /") || cmd.hasPrefix("find ~/") {
                let parts = command.components(separatedBy: " ")
                if parts.count > 1 {
                    let p =
                        parts[1].hasPrefix("~")
                        ? NSHomeDirectory() + parts[1].dropFirst() : parts[1]
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir),
                        isDir.boolValue
                    {
                        return p
                    }
                }
            }
            // From ls command: ls /path or ls -lt /path
            if cmd.hasPrefix("ls") {
                let parts = command.components(separatedBy: " ").filter {
                    !$0.hasPrefix("-") && !$0.isEmpty
                }
                let pathPart = parts.dropFirst().first ?? ""
                let p =
                    pathPart.hasPrefix("~") ? NSHomeDirectory() + pathPart.dropFirst() : pathPart
                if !p.isEmpty {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir),
                        isDir.boolValue
                    {
                        return p
                    }
                }
            }
            return nil
        }()

        // Also activate if output lines are mostly file paths
        let pathLikeLines = rawLines.filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }.count
        let looksLikePaths = rawLines.count > 1 && pathLikeLines >= rawLines.count / 2

        guard isListCommand || looksLikePaths, !rawLines.isEmpty, rawLines.count <= 500 else {
            return []
        }

        let fm = FileManager.default
        var entries: [LivePanelMode.ResultEntry] = []
        var seen = Set<String>()

        func makeEntry(path: String) {
            guard !seen.contains(path) else { return }
            seen.insert(path)
            guard fm.fileExists(atPath: path) else { return }

            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)

            let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            let size = attrs[.size] as? Int ?? 0
            let modified = attrs[.modificationDate] as? Date
            let ext = url.pathExtension.lowercased()

            let icon: String = {
                if isDir.boolValue { return "folder.fill" }
                switch ext {
                case "pdf": return "doc.richtext"
                case "png", "jpg", "jpeg", "gif", "heic",
                    "webp", "tiff", "raw", "arw", "cr2":
                    return "photo"
                case "mp4", "mov", "mkv", "avi", "m4v": return "film"
                case "mp3", "aac", "flac", "wav", "m4a",
                    "ogg", "opus":
                    return "waveform"
                case "zip", "gz", "tar", "7z", "rar", "bz2": return "archivebox"
                case "swift", "py", "js", "ts", "sh", "rb",
                    "go", "rs", "cpp", "c", "java":
                    return "chevron.left.forwardslash.chevron.right"
                case "md", "txt", "rtf": return "doc.text"
                case "json", "yaml", "yml", "toml", "xml": return "curlybraces"
                default: return "doc"
                }
            }()

            // Subtitle: file size + relative time if available
            var subtitle = ""
            if size > 0 {
                subtitle = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            }
            if let mod = modified {
                let rel = RelativeDateTimeFormatter().localizedString(for: mod, relativeTo: Date())
                subtitle = subtitle.isEmpty ? rel : "\(subtitle) · \(rel)"
            }
            if subtitle.isEmpty { subtitle = isDir.boolValue ? "Folder" : ext.uppercased() }

            entries.append(
                LivePanelMode.ResultEntry(
                    name: url.lastPathComponent, path: path,
                    subtitle: subtitle, icon: icon))
        }

        for line in rawLines {
            // Skip ls -l header and permission strings
            if line.lowercased().hasPrefix("total") { continue }
            if line.range(of: #"^[-dlrwxst]{10}\s"#, options: .regularExpression) != nil {
                // ls -l line: last whitespace-separated token is the filename
                if isLsLongFormat, let folder = contextFolder {
                    // Handle ls -l output: extract filename (last column, may contain spaces after arrow)
                    // Format: perms links user group size mon day time/year name
                    // Split on 2+ spaces or use fixed column approach
                    let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 9 {
                        // name starts at index 8, join remaining (handles spaces in names via -> symlink)
                        let namePart =
                            parts[8...].joined(separator: " ").components(separatedBy: " -> ").first
                            ?? parts[8]
                        let fullPath = folder + "/" + namePart
                        makeEntry(path: fullPath)
                    }
                }
                continue
            }

            // du output: "size\tpath"
            var candidate = line
            if let tab = line.range(of: "\t") {
                candidate = String(line[tab.upperBound...])
            }
            // Expand ~
            if candidate.hasPrefix("~") {
                candidate = NSHomeDirectory() + String(candidate.dropFirst())
            }

            if candidate.hasPrefix("/") {
                makeEntry(path: candidate)
            } else if let folder = contextFolder, !candidate.isEmpty,
                !candidate.hasPrefix("-") && !candidate.hasPrefix("#")
            {
                // Relative name — resolve against context folder
                makeEntry(path: folder + "/" + candidate)
            }
        }

        return entries
    }






    // MARK: - Panel Welcome / Onboarding View






    /// Extract only genuine assistant clarifications, such as “1. Scan first” /
    /// “2. Clean immediately”. Ordinary numbered output remains plain text.





}
