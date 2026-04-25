//
//  PromptRunner.swift
//  ILauncher
//
//  Executes AI Prompt extensions for app panels.
//  Responsibilities:
//    • Render {{template variables}} before the prompt reaches the AI
//    • In-memory response cache with per-extension TTL
//    • Export / import prompt templates as .prompt files

import Foundation
import AppKit   // NSPasteboard

// MARK: - Template Variables

/// All variables available inside a prompt template.
/// Insert any of these in the TextEditor and they are replaced at query time.
struct PromptVariable: Identifiable {
    let id = UUID()
    let tag: String         // e.g. "{{query}}"
    let label: String       // shown in UI chip
    let description: String // tooltip / help text
}

extension PromptVariable {
    static let all: [PromptVariable] = [
        .init(tag: "{{query}}",     label: "query",     description: "The user's current message"),
        .init(tag: "{{app}}",       label: "app",       description: "App name, e.g. Reminders"),
        .init(tag: "{{date}}",      label: "date",      description: "Today's date, e.g. Wednesday, March 18 2026"),
        .init(tag: "{{time}}",      label: "time",      description: "Current time, e.g. 2:30 PM"),
        .init(tag: "{{clipboard}}", label: "clipboard", description: "Current clipboard text"),
        .init(tag: "{{weekday}}",   label: "weekday",   description: "Day of week, e.g. Wednesday"),
    ]
}

// MARK: - Prompt Runner

final class PromptRunner {
    static let shared = PromptRunner()
    private init() {}

    // key: "<extId>:<queryHashValue>" → (response, expiry)
    private var cache: [String: (response: String, expiry: Date)] = [:]

    // MARK: - Template Rendering

    /// Replace all {{vars}} in the template with live values.
    func render(template: String, query: String, appLabel: String) -> String {
        let now       = Date()
        let dateStr   = DateFormatter.localizedString(from: now, dateStyle: .full,   timeStyle: .none)
        let timeStr   = DateFormatter.localizedString(from: now, dateStyle: .none,   timeStyle: .short)
        let weekday   = Calendar.current.weekdaySymbols[Calendar.current.component(.weekday, from: now) - 1]
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""

        return template
            .replacingOccurrences(of: "{{query}}",     with: query)
            .replacingOccurrences(of: "{{input}}",     with: query)   // alias
            .replacingOccurrences(of: "{{app}}",       with: appLabel)
            .replacingOccurrences(of: "{{date}}",      with: dateStr)
            .replacingOccurrences(of: "{{time}}",      with: timeStr)
            .replacingOccurrences(of: "{{weekday}}",   with: weekday)
            .replacingOccurrences(of: "{{clipboard}}", with: clipboard)
    }

    // MARK: - Cache

    /// Returns a cached response if one exists and hasn't expired.
    func cachedResponse(for ext: AppToolExtension, query: String) -> String? {
        guard ext.cacheTTLMinutes > 0 else { return nil }
        let key = cacheKey(ext: ext, query: query)
        guard let entry = cache[key], entry.expiry > Date() else {
            cache.removeValue(forKey: key)  // purge stale entry
            return nil
        }
        return entry.response
    }

    /// Store a response in the cache with the extension's TTL.
    func cacheResponse(_ response: String, for ext: AppToolExtension, query: String) {
        guard ext.cacheTTLMinutes > 0, !response.isEmpty else { return }
        let expiry = Date().addingTimeInterval(TimeInterval(ext.cacheTTLMinutes * 60))
        cache[cacheKey(ext: ext, query: query)] = (response, expiry)
    }

    /// Remove all cached entries for a specific extension (e.g. after editing the template).
    func clearCache(for ext: AppToolExtension) {
        cache = cache.filter { !$0.key.hasPrefix(ext.id.uuidString + ":") }
    }

    func clearAllCache() { cache.removeAll() }

    // MARK: - File I/O  (export / import .prompt files)

    /// Save a prompt extension's template to disk as a .prompt file.
    /// Returns the saved file path, or nil on failure.
    func savePromptFile(appKey: String, name: String, template: String) -> String? {
        let fm   = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ILauncher/Prompts/\(appKey)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("\(name).prompt")
        guard (try? template.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        return file.path
    }

    /// Load a template from a .prompt file on disk.
    func loadPromptFile(at path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Helpers

    private func cacheKey(ext: AppToolExtension, query: String) -> String {
        "\(ext.id.uuidString):\(query.hashValue)"
    }
}

// MARK: - Cache TTL Picker Options

struct CacheTTLOption: Identifiable {
    let id = UUID()
    let minutes: Int
    let label: String
}

extension CacheTTLOption {
    static let options: [CacheTTLOption] = [
        .init(minutes: 0,    label: "No cache"),
        .init(minutes: 5,    label: "5 minutes"),
        .init(minutes: 30,   label: "30 minutes"),
        .init(minutes: 60,   label: "1 hour"),
        .init(minutes: 360,  label: "6 hours"),
        .init(minutes: 1440, label: "1 day"),
    ]

    static func label(for minutes: Int) -> String {
        options.first(where: { $0.minutes == minutes })?.label
            ?? "\(minutes) min"
    }
}
