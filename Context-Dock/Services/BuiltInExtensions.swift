//
//  BuiltInExtensions.swift
//  ILauncher
//
//  Built-in extension actions that work without external scripts
//

import Foundation
import AppKit

enum BuiltInExtension {
    case copy
    case copyPath
    case fileInfo
    case getInfo
    case revealInFinder
    case countWords
    case summarize
    case uppercase
    case lowercase
    case appInfo
    case pasteFromClipboard
    
    func execute(with input: String) async throws -> String {
        switch self {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(input, forType: .string)
            return "Copied to clipboard"
            
        case .copyPath:
            let paths = input.split(separator: "\n").map(String.init).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths, forType: .string)
            return "Path copied to clipboard"
            
        case .fileInfo:
            let urls = input.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            var info: [String] = []
            
            for url in urls {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attrs?[.size] as? Int64 ?? 0
                let fileSizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
                let fileName = url.lastPathComponent
                let fileExt = url.pathExtension.uppercased()
                
                info.append("\(fileName)")
                info.append("Size: \(fileSizeStr)")
                if !fileExt.isEmpty {
                    info.append("Type: \(fileExt)")
                }
            }
            
            return info.joined(separator: "\n")
            
        case .getInfo:
            let url = URL(fileURLWithPath: input.trimmingCharacters(in: .whitespacesAndNewlines))
            NSWorkspace.shared.open(url)
            return "Opened file info"
            
        case .revealInFinder:
            let urls = input.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            if let first = urls.first {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                return "Revealed in Finder"
            }
            return "No files to reveal"
            
        case .countWords:
            let words = input.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            let wordCount = words.count
            let charCount = input.count
            let charNoSpaces = input.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\n", with: "").count
            
            return """
            Words: \(wordCount)
            Characters: \(charCount)
            Characters (no spaces): \(charNoSpaces)
            """
            
        case .summarize:
            // This is a placeholder - you could integrate with Apple Intelligence or other AI services
            let sentences = input.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            if sentences.count <= 3 {
                return "Text is already concise:\n\(input)"
            }
            
            // Simple summarization: take first 2-3 sentences
            let summary = sentences.prefix(3).joined(separator: ". ") + "."
            return "Summary:\n\(summary)"
            
        case .uppercase:
            let result = input.uppercased()
            // Copy result to clipboard
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            return "Converted to uppercase and copied"
            
        case .lowercase:
            let result = input.lowercased()
            // Copy result to clipboard
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            return "Converted to lowercase and copied"
            
        case .appInfo:
            return "App: \(input)"
            
        case .pasteFromClipboard:
            if let clipboardText = NSPasteboard.general.string(forType: .string) {
                return clipboardText
            }
            return "Clipboard is empty"
        }
    }
    
    func toScriptExtension() -> ScriptExtension {
        switch self {
        case .copy:
            return ScriptExtension(
                name: "copy",
                displayName: "Copy",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
            
        case .copyPath:
            return ScriptExtension(
                name: "copy-path",
                displayName: "Copy Path",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
            
        case .fileInfo:
            return ScriptExtension(
                name: "file-info",
                displayName: "File Info",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
            
        case .getInfo:
            return ScriptExtension(
                name: "get-info",
                displayName: "Get Info",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
            
        case .revealInFinder:
            return ScriptExtension(
                name: "reveal-in-finder",
                displayName: "Reveal in Finder",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
            
        case .countWords:
            return ScriptExtension(
                name: "count-words",
                displayName: "Count Words",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
            
        case .summarize:
            return ScriptExtension(
                name: "summarize",
                displayName: "Summarize",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
            
        case .uppercase:
            return ScriptExtension(
                name: "uppercase",
                displayName: "UPPERCASE",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
            
        case .lowercase:
            return ScriptExtension(
                name: "lowercase",
                displayName: "lowercase",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
            
        case .appInfo:
            return ScriptExtension(
                name: "app-info",
                displayName: "App Info",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
            
        case .pasteFromClipboard:
            return ScriptExtension(
                name: "paste-from-clipboard",
                displayName: "Use Clipboard",
                path: "__builtin__",
                type: .shell,
                category: .ai,
                isBuiltIn: true,
                builtInAction: self
            )
        }
    }
}
