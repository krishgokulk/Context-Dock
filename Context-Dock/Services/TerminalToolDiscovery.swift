//
//  TerminalToolDiscovery.swift
//  ILauncher
//
//  Lightweight tool discovery for AI prompts
//

import Foundation

struct TerminalToolDiscovery {
    struct ToolInfo {
        let name: String
        let description: String
    }

    private static let knownTools: [ToolInfo] = [
        ToolInfo(name: "brew", description: "Homebrew package manager"),
        ToolInfo(name: "git", description: "Version control"),
        ToolInfo(name: "curl", description: "HTTP requests"),
        ToolInfo(name: "wget", description: "File downloads"),
        ToolInfo(name: "ffmpeg", description: "Audio/video processing"),
        ToolInfo(name: "imagemagick", description: "Image processing (convert/magick)"),
        ToolInfo(name: "sips", description: "macOS image processing"),
        ToolInfo(name: "gs", description: "Ghostscript PDF processing"),
        ToolInfo(name: "pdftk", description: "PDF toolkit"),
        ToolInfo(name: "pandoc", description: "Document conversion"),
        ToolInfo(name: "fastfetch", description: "System summary"),
        ToolInfo(name: "neofetch", description: "System summary"),
        ToolInfo(name: "fdir", description: "Fast file search"),
        ToolInfo(name: "ezNote", description: "Quick notes CLI"),
        ToolInfo(name: "ffl", description: "File finder list CLI"),
        ToolInfo(name: "scmd", description: "System command utilities"),
        ToolInfo(name: "rg", description: "Ripgrep search"),
        ToolInfo(name: "fd", description: "Fast file finder"),
        ToolInfo(name: "jq", description: "JSON processor"),
        ToolInfo(name: "bat", description: "Syntax-highlighted cat"),
        ToolInfo(name: "htop", description: "Process viewer"),
    ]

    static func installedToolsSummary(limit: Int = 40) -> String {
        var lines: [String] = []

        let installedKnown = knownTools.filter { isInstalled($0.name) }
        if !installedKnown.isEmpty {
            lines.append("Known tools:")
            for tool in installedKnown.prefix(limit) {
                lines.append("- \(tool.name): \(tool.description)")
            }
        }

        let extras = discoverCustomExecutables(excluding: Set(installedKnown.map { $0.name }))
        if !extras.isEmpty {
            lines.append("Other executables:")
            for name in extras.prefix(max(0, limit - installedKnown.count)) {
                lines.append("- \(name)")
            }
        }

        return lines.isEmpty ? "None detected." : lines.joined(separator: "\n")
    }

    private static func isInstalled(_ tool: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func discoverCustomExecutables(excluding known: Set<String>) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "\(home)/.local/bin",
            "\(home)/bin"
        ]

        var results: Set<String> = []
        let fm = FileManager.default

        for dir in candidates {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                if item.hasPrefix(".") || item.contains(".app") {
                    continue
                }
                let fullPath = "\(dir)/\(item)"
                if fm.isExecutableFile(atPath: fullPath) && !known.contains(item) {
                    results.insert(item)
                }
            }
        }

        return results.sorted()
    }
}
