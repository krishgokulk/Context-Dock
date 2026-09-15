// Context-Dock/Services/Plugins/PluginEnvironment.swift
//
// What a plugin's script can see. Pure: inputs in, variables out, no store and no process —
// the runner merges these over the real environment. Spec §8.

import Foundation

struct PluginInputs: Equatable {
    var query: String?
    var selectionText: String?
    var selectionFiles: [String] = []
    var selectionURL: String?
    var selectionImage: String?
    var clipboardText: String?
    var clipboardFiles: [String] = []
    var clipboardImage: String?
    var clipboardHistoryPath: String?
    var frontmostApp: String?
    var rowID: String?
    var rowTitle: String?
    var rowRaw: String?
    var value: PluginValue?

    init() {}
}

enum PluginEnvironment {
    static func build(inputs: PluginInputs, host: PluginPresentation,
                      widthClass: PluginWidthClass) -> [String: String] {
        var env: [String: String] = [
            "CD_HOST": host.rawValue,
            "CD_WIDTH": widthClass.rawValue,
        ]
        // An absent input sets no variable: `[ -n "$CD_TEXT" ]` must be able to tell
        // "nothing was selected" from "empty text was selected".
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            env[key] = value
        }
        func putList(_ key: String, _ paths: [String]) {
            guard !paths.isEmpty else { return }
            env[key] = paths.joined(separator: "\n")
        }
        put("CD_QUERY", inputs.query)
        put("CD_TEXT", inputs.selectionText)
        putList("CD_FILES", inputs.selectionFiles)
        put("CD_URL", inputs.selectionURL)
        put("CD_IMAGE", inputs.selectionImage)
        put("CD_CLIP_TEXT", inputs.clipboardText)
        putList("CD_CLIP_FILES", inputs.clipboardFiles)
        put("CD_CLIP_IMAGE", inputs.clipboardImage)
        put("CD_CLIP_HISTORY", inputs.clipboardHistoryPath)
        put("CD_APP", inputs.frontmostApp)
        put("CD_ROW_ID", inputs.rowID)
        put("CD_ROW_TITLE", inputs.rowTitle)
        put("CD_ROW", inputs.rowRaw)
        put("CD_VALUE", inputs.value.map(string(from:)))
        return env
    }

    /// A number a script can do arithmetic on: `35`, never `35.0`.
    private static func string(from value: PluginValue) -> String {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            return n == n.rounded() ? String(Int(n)) : String(n)
        case .null: return ""
        case .array, .object:
            guard let data = try? JSONEncoder().encode(value) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
