// FinderToolkit.swift
// ILauncher
//
// Discovers shell scripts in ~/.config/ilauncher/finder-tools/*.sh
// and converts them into dock pills + AI system-prompt context.
//
// HOW TO EXTEND:
//   1. Drop a .sh file into ~/.config/ilauncher/finder-tools/
//   2. Add metadata comment headers (see format below)
//   3. ILauncher picks it up on next launch / panel open — no Swift changes needed.
//
// SCRIPT HEADER FORMAT:
//   #!/bin/zsh
//   # ilauncher:name=My Action          (pill label, required)
//   # ilauncher:icon=square.grid.2x2    (SF Symbol name, optional)
//   # ilauncher:desc=Short description  (shown in UI, optional)
//   # ilauncher:ai=command hint text    (injected into AI system prompt, optional)
//   # ilauncher:confirm=yes             (show dry-run output, ask before real run, optional)
//
// SCRIPT ARGUMENTS:
//   $1 = current Finder directory (POSIX path)
//   $2 = selected file path (if any)
//   $3 = user's natural language query (passed when AI calls this script)

import Foundation
import AppKit

// MARK: - Discovered Tool

struct FinderTool: Identifiable {
    let id: UUID = UUID()
    let scriptPath: String      // absolute path to .sh file
    let name: String            // display label
    let icon: String            // SF Symbol
    let description: String     // short description
    let aiHint: String          // injected into AI system prompt
    let requiresConfirm: Bool   // show dry-run output, ask for confirmation

    /// Run the script with the given Finder directory and optional selected file
    func run(dir: String, selectedFile: String? = nil, query: String? = nil) {
        var args = [dir]
        if let f = selectedFile { args.append(f) }
        if let q = query        { args.append(q) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments     = [scriptPath] + args
        proc.environment   = ProcessInfo.processInfo.environment
        Task.detached(priority: .userInitiated) { try? proc.run() }
    }
}

// MARK: - FinderToolkit

final class FinderToolkit {
    static let shared = FinderToolkit()
    private init() {}

    private let toolsDir = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/ilauncher/finder-tools")

    // MARK: - Discover

    /// Parse all .sh scripts in the tools directory and return them sorted by filename.
    func discoverTools() -> [FinderTool] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: toolsDir) else { return [] }

        return files
            .filter { $0.hasSuffix(".sh") }
            .sorted()
            .compactMap { filename -> FinderTool? in
                let path = (toolsDir as NSString).appendingPathComponent(filename)
                return parseScript(at: path)
            }
    }

    private func parseScript(at path: String) -> FinderTool? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n")

        var name     = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var icon     = "terminal"
        var desc     = ""
        var aiHint   = ""
        var confirm  = false

        for line in lines.prefix(20) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("# ilauncher:") else { continue }
            let kv = l.dropFirst("# ilauncher:".count)
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let key = String(kv[kv.startIndex..<eq]).lowercased()
            let val = String(kv[kv.index(after: eq)...])
            switch key {
            case "name":    name    = val
            case "icon":    icon    = val
            case "desc":    desc    = val
            case "ai":      aiHint  = val
            case "confirm": confirm = val.lowercased() == "yes" || val == "1" || val.lowercased() == "true"
            default: break
            }
        }

        guard !name.isEmpty else { return nil }
        return FinderTool(scriptPath: path, name: name, icon: icon,
                          description: desc, aiHint: aiHint, requiresConfirm: confirm)
    }

    // MARK: - AI System Prompt Context

    /// Returns a block of text to inject into the Finder panel AI system prompt.
    /// Contains the command syntax for each installed script, derived from # ilauncher:ai= headers.
    func systemPromptContext() -> String {
        let tools = discoverTools()
        guard !tools.isEmpty else {
            return """
            FINDER TOOLS: No scripts found in ~/.config/ilauncher/finder-tools/.
            Fall back to standard Unix commands: find, ls, du, mv, cp, rm.
            Use run_command for all file operations.
            """
        }

        let dir = toolsDir
        var lines: [String] = [
            "AVAILABLE FINDER TOOLS (user-installed scripts in \(dir)):",
            ""
        ]

        for tool in tools {
            let hint = tool.aiHint.isEmpty ? "run script at \(tool.scriptPath)" : tool.aiHint
            let confirmNote = tool.requiresConfirm ? " [CONFIRM: run with --dry-run first, show output, ask user before real execution]" : ""
            lines.append("• \(tool.name): \(hint)\(confirmNote)")
            lines.append("  Script: run_command(\"\(tool.scriptPath) '<dir>' ['<file>'] ['<query>']\")")
        }

        lines += [
            "",
            "BUILT-IN UNIX COMMANDS (always available, no install needed):",
            "• find <dir> -name '*.pdf' -type f         → list files by extension",
            "• find <dir> -newer <date> -type f          → files modified after date",
            "• find <dir> -size +100M -type f            → files larger than 100MB",
            "• ls -lhS <dir>                             → list by size",
            "• du -sh <dir>/*                            → folder sizes",
            "• mv, cp, rm, mkdir                         → move/copy/delete/create",
            "• open -a 'App Name' <file>                 → open file in specific app",
            "• qlmanage -p <file> &>/dev/null &          → Quick Look preview",
            "• open -R <file>                            → reveal in Finder",
            "",
            "TOOL SELECTION RULES:",
            "- User wants to organize/sort a folder → use the Sort By Type/Date/Ext scripts",
            "- User asks 'how do I X' → use the Find Cmd script (wtf)",
            "- User wants to list specific file types → use find or List by Type script",
            "- User wants to undo → use Undo Last script",
            "- ALWAYS use --dry-run / confirm=yes scripts for destructive operations",
            "- ALWAYS use run_command — never explain without acting",
        ]

        return lines.joined(separator: "\n")
    }

    // MARK: - Dock Pills (PanelAction)

    /// Produce a closure-based action that sends a message to the panel AI chat.
    /// The caller in ContentView can map these to PanelAction items.
    struct PillSpec {
        let name: String
        let icon: String
        let action: (String) -> Void   // takes current dir
    }

    func pillSpecs() -> [PillSpec] {
        let tools = discoverTools()

        // Always add "New Folder" and "Open Terminal Here" — pure AppleScript, no external CLI
        var specs: [PillSpec] = []

        for tool in tools {
            let path = tool.scriptPath
            let confirm = tool.requiresConfirm
            let displayName = tool.name
            specs.append(PillSpec(name: displayName, icon: tool.icon) { dir in
                if confirm {
                    // Fire the script in a visible shell so the AI sees the output
                    FinderToolkit.shared.runScriptVisible(path: path, dir: dir)
                } else {
                    FinderToolkit.shared.runScriptSilent(path: path, dir: dir)
                }
            })
        }
        return specs
    }

    // MARK: - Execution helpers

    func runScriptVisible(path: String, dir: String) {
        // Run in background; ContentView surfaces output via terminal drawer
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = [path, dir]
            proc.environment = ProcessInfo.processInfo.environment
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    func runScriptSilent(path: String, dir: String) {
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = [path, dir]
            proc.environment = ProcessInfo.processInfo.environment
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    // MARK: - Installation Helper

    /// Prints the tools directory path and list of installed scripts (for debugging / UI)
    func installedSummary() -> String {
        let tools = discoverTools()
        if tools.isEmpty { return "No tools installed. Add .sh scripts to \(toolsDir)" }
        return tools.map { "• \($0.name) — \($0.scriptPath)" }.joined(separator: "\n")
    }
}
