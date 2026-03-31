// AXTriggerRule.swift
// ILauncher
//
// User-defined "when I see X on screen → show pill Y" rules.
//
// Each rule has:
//   • One or more conditions checked against the live AX context
//     (app name, window title, selected text, clipboard, URL, file path…)
//   • AND / OR logic between conditions
//   • One or more pill definitions to surface in the dock
//   • Variable interpolation in labels and action values:
//       {appName}  {windowTitle}  {selectedText}  {clipboard}  {url}  {file}  {bundleId}
//
// Built-in example rules ship with the app so users see the pattern immediately.

import Foundation
import AppKit

// MARK: - Condition field

enum AXConditionField: String, Codable, CaseIterable, Identifiable {
    case appName      = "App Name"
    case bundleId     = "Bundle ID"
    case windowTitle  = "Window Title"
    case selectedText = "Selected Text"
    case clipboardText = "Clipboard"
    case currentURL   = "Current URL"
    case focusedRole  = "Focused Element"
    case filePath     = "Selected File"

    var id: String { rawValue }

    var sfSymbol: String {
        switch self {
        case .appName:       return "app.fill"
        case .bundleId:      return "barcode"
        case .windowTitle:   return "rectangle.topthird.inset.filled"
        case .selectedText:  return "text.cursor"
        case .clipboardText: return "doc.on.clipboard"
        case .currentURL:    return "link"
        case .focusedRole:   return "scope"
        case .filePath:      return "doc.fill"
        }
    }
}

// MARK: - Condition operator

enum AXConditionOperator: String, Codable, CaseIterable, Identifiable {
    case contains    = "contains"
    case notContains = "doesn't contain"
    case equals      = "equals"
    case startsWith  = "starts with"
    case endsWith    = "ends with"
    case matchesRegex = "matches regex"
    case isEmpty     = "is empty"
    case isNotEmpty  = "is not empty"

    var id: String { rawValue }

    /// True if this operator needs a value string to compare against
    var needsValue: Bool {
        switch self {
        case .isEmpty, .isNotEmpty: return false
        default: return true
        }
    }
}

// MARK: - Condition

struct AXTriggerCondition: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var field: AXConditionField
    var op: AXConditionOperator
    var value: String

    init(field: AXConditionField = .appName,
         op: AXConditionOperator = .contains,
         value: String = "") {
        self.id    = UUID()
        self.field = field
        self.op    = op
        self.value = value
    }
}

// MARK: - Rule pill definition

struct AXRulePill: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String          // supports {selectedText}, {appName}, etc.
    var icon: String           // SF Symbol name
    var accentColor: String    // "blue" | "red" | "green" | "orange" | "purple" | "teal" | "gray"
    var actionType: AppShortcut.ActionType
    var actionValue: String    // supports same {variables}

    init(label: String = "Action",
         icon: String = "bolt.fill",
         accentColor: String = "blue",
         actionType: AppShortcut.ActionType = .shellCommand,
         actionValue: String = "") {
        self.id          = UUID()
        self.label       = label
        self.icon        = icon
        self.accentColor = accentColor
        self.actionType  = actionType
        self.actionValue = actionValue
    }
}

// MARK: - AXTriggerRule

struct AXTriggerRule: Codable, Identifiable, Equatable {
    enum ConditionLogic: String, Codable { case all, any }

    var id: UUID = UUID()
    var name: String
    var isEnabled: Bool
    var conditions: [AXTriggerCondition]
    var conditionLogic: ConditionLogic   // .all = AND,  .any = OR
    var pills: [AXRulePill]
    var priority: Int                    // higher → shown earlier in dock

    /// Optional global hotkey that fires the first pill directly, without opening the dock.
    /// Stored as "modifiers:keyChar" e.g. "cmd+shift:d" — nil means no hotkey assigned.
    var hotkeyString: String? = nil

    init(name: String = "New Rule",
         isEnabled: Bool = true,
         conditions: [AXTriggerCondition] = [],
         conditionLogic: ConditionLogic = .all,
         pills: [AXRulePill] = [],
         priority: Int = 0,
         hotkeyString: String? = nil) {
        self.id             = UUID()
        self.name           = name
        self.isEnabled      = isEnabled
        self.conditions     = conditions
        self.conditionLogic = conditionLogic
        self.pills          = pills
        self.priority       = priority
        self.hotkeyString   = hotkeyString
    }

    // MARK: Built-in example rules

    static let builtInExamples: [AXTriggerRule] = [

        // ── Messages: payment keyword ─────────────────────────────────
        AXTriggerRule(
            name: "Messages — Payment Request",
            isEnabled: true,
            conditions: [
                AXTriggerCondition(field: .appName,      op: .equals,    value: "Messages"),
                AXTriggerCondition(field: .selectedText, op: .contains,  value: "send"),
            ],
            conditionLogic: .all,
            pills: [
                AXRulePill(label: "Pay via UPI",
                           icon: "indianrupeesign.circle.fill",
                           accentColor: "green",
                           actionType: .openURL,
                           actionValue: "upi://pay"),
                AXRulePill(label: "Copy Amount",
                           icon: "doc.on.doc",
                           accentColor: "blue",
                           actionType: .shellCommand,
                           actionValue: "echo '{selectedText}' | pbcopy"),
            ],
            priority: 10
        ),

        // ── Safari / Browser: GitHub repo ────────────────────────────
        AXTriggerRule(
            name: "Browser — GitHub Repo",
            isEnabled: true,
            conditions: [
                AXTriggerCondition(field: .currentURL, op: .contains, value: "github.com"),
            ],
            conditionLogic: .all,
            pills: [
                AXRulePill(label: "Clone Repo",
                           icon: "arrow.down.circle",
                           accentColor: "purple",
                           actionType: .shellCommand,
                           actionValue: "osascript -e 'tell application \"Terminal\" to do script \"git clone {url}\"'"),
                AXRulePill(label: "Open in Xcode",
                           icon: "hammer.fill",
                           accentColor: "blue",
                           actionType: .openURL,
                           actionValue: "xcode://clone?url={url}"),
                AXRulePill(label: "Copy URL",
                           icon: "link",
                           accentColor: "gray",
                           actionType: .shellCommand,
                           actionValue: "echo '{url}' | pbcopy"),
            ],
            priority: 8
        ),

        // ── Xcode: compile error visible ─────────────────────────────
        AXTriggerRule(
            name: "Xcode — Error Selected",
            isEnabled: true,
            conditions: [
                AXTriggerCondition(field: .appName,      op: .equals,   value: "Xcode"),
                AXTriggerCondition(field: .selectedText, op: .contains, value: "error:"),
            ],
            conditionLogic: .all,
            pills: [
                AXRulePill(label: "Fix with AI",
                           icon: "sparkles",
                           accentColor: "purple",
                           actionType: .shellCommand,
                           actionValue: "echo 'Fix this Swift error: {selectedText}' | pbcopy"),
                AXRulePill(label: "Search Forums",
                           icon: "magnifyingglass",
                           accentColor: "orange",
                           actionType: .openURL,
                           actionValue: "https://forums.swift.org/search?q={selectedText}"),
            ],
            priority: 9
        ),

        // ── Any app: URL on clipboard ─────────────────────────────────
        AXTriggerRule(
            name: "Clipboard — URL Detected",
            isEnabled: true,
            conditions: [
                AXTriggerCondition(field: .clipboardText, op: .startsWith, value: "http"),
            ],
            conditionLogic: .all,
            pills: [
                AXRulePill(label: "Open URL",
                           icon: "safari",
                           accentColor: "blue",
                           actionType: .openURL,
                           actionValue: "{clipboard}"),
                AXRulePill(label: "Save to Bear",
                           icon: "note.text",
                           accentColor: "orange",
                           actionType: .openURL,
                           actionValue: "bear://x-callback-url/create?text={clipboard}"),
            ],
            priority: 5
        ),

        // ── Finder: file selected ──────────────────────────────────────
        AXTriggerRule(
            name: "Finder — File Selected",
            isEnabled: true,
            conditions: [
                AXTriggerCondition(field: .appName,   op: .equals,    value: "Finder"),
                AXTriggerCondition(field: .filePath,  op: .isNotEmpty, value: ""),
            ],
            conditionLogic: .all,
            pills: [
                AXRulePill(label: "Open in VS Code",
                           icon: "chevron.left.forwardslash.chevron.right",
                           accentColor: "blue",
                           actionType: .openURL,
                           actionValue: "vscode://file/{file}"),
                AXRulePill(label: "Copy Path",
                           icon: "doc.on.doc",
                           accentColor: "gray",
                           actionType: .shellCommand,
                           actionValue: "echo '{file}' | pbcopy"),
            ],
            priority: 7
        ),
    ]
}

// MARK: - Resolved pill (flat, app-agnostic)

struct AXResolvedPill {
    let id: String
    let name: String
    let icon: String
    let accentColor: String
    let execute: () -> Void
}

// MARK: - AXTriggerRuleEngine

@MainActor
final class AXTriggerRuleEngine {
    static let shared = AXTriggerRuleEngine()

    private var ruleHotkeyMonitor: Any?

    private init() {
        startRuleHotkeyMonitor()
    }

    // MARK: - Global rule hotkey monitor

    /// Listens for any keyDown globally. When a key combo matches a rule's hotkeyString,
    /// refreshes AX context from the frontmost app and fires the first pill immediately —
    /// the dock never opens.
    func startRuleHotkeyMonitor() {
        ruleHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let rules = AppSettings.shared.axTriggerRules.filter { $0.isEnabled && $0.hotkeyString != nil && !$0.pills.isEmpty }
            guard !rules.isEmpty else { return }

            let pressed = Self.eventToHotkeyString(event)
            guard !pressed.isEmpty else { return }

            for rule in rules {
                guard rule.hotkeyString == pressed else { continue }
                // Evaluate rule against live context from the currently active app
                Task { @MainActor in
                    guard let frontApp = NSWorkspace.shared.frontmostApplication,
                          frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                    AXContextReader.shared.refresh(from: frontApp)
                    let ctx = AXContextReader.shared.current
                    let clipboard = NSPasteboard.general.string(forType: .string)
                    // Execute the first matching pill directly — no dock open
                    let pillDef = rule.pills[0]
                    let action = self.interpolate(pillDef.actionValue, context: ctx, clipboard: clipboard)
                    let envVars: [String: String] = [
                        "CD_APP_NAME":      ctx.appName,
                        "CD_BUNDLE_ID":     ctx.bundleId,
                        "CD_WINDOW_TITLE":  ctx.windowTitle  ?? "",
                        "CD_SELECTED_TEXT": ctx.selectedText ?? "",
                        "CD_URL":           ctx.currentURL   ?? "",
                        "CD_FILE":          ctx.selectedFilePaths.first ?? "",
                        "CD_CLIPBOARD":     clipboard ?? "",
                    ]
                    self.run(type: pillDef.actionType, value: action, envVars: envVars)
                }
                break
            }
        }
    }

    /// Converts an NSEvent keyDown to the same "mod+mod:char" format stored in hotkeyString.
    static func eventToHotkeyString(_ event: NSEvent) -> String {
        guard let ch = event.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty else { return "" }
        var parts: [String] = []
        if event.modifierFlags.contains(.command) { parts.append("cmd") }
        if event.modifierFlags.contains(.shift)   { parts.append("shift") }
        if event.modifierFlags.contains(.option)  { parts.append("opt") }
        if event.modifierFlags.contains(.control) { parts.append("ctrl") }
        return parts.joined(separator: "+") + ":" + ch
    }

    /// Evaluate all enabled rules against the current context,
    /// return resolved pills ordered by rule priority (highest first).
    func evaluate(context: AXContext) -> [AXResolvedPill] {
        let clipboard = NSPasteboard.general.string(forType: .string)
        let rules = AppSettings.shared.axTriggerRules
            .filter { $0.isEnabled && !$0.conditions.isEmpty && !$0.pills.isEmpty }
            .sorted { $0.priority > $1.priority }

        var result: [AXResolvedPill] = []
        for rule in rules {
            guard matches(rule: rule, context: context, clipboard: clipboard) else { continue }
            for pillDef in rule.pills {
                result.append(makePill(pillDef, context: context, clipboard: clipboard))
            }
        }
        return result
    }

    // MARK: - Matching

    private func matches(rule: AXTriggerRule, context: AXContext, clipboard: String?) -> Bool {
        guard !rule.conditions.isEmpty else { return false }
        let results = rule.conditions.map { eval(condition: $0, context: context, clipboard: clipboard) }
        return rule.conditionLogic == .all
            ? results.allSatisfy { $0 }
            : results.contains   { $0 }
    }

    private func eval(condition: AXTriggerCondition, context: AXContext, clipboard: String?) -> Bool {
        let fieldVal = value(of: condition.field, context: context, clipboard: clipboard)
        return apply(op: condition.op, to: fieldVal, against: condition.value)
    }

    private func value(of field: AXConditionField, context: AXContext, clipboard: String?) -> String {
        switch field {
        case .appName:       return context.appName
        case .bundleId:      return context.bundleId
        case .windowTitle:   return context.windowTitle  ?? ""
        case .selectedText:  return context.selectedText ?? ""
        case .clipboardText: return clipboard            ?? ""
        case .currentURL:    return context.currentURL   ?? ""
        case .focusedRole:   return context.focusedElementRole ?? ""
        case .filePath:      return context.selectedFilePaths.first ?? ""
        }
    }

    private func apply(op: AXConditionOperator, to haystack: String, against needle: String) -> Bool {
        let h = haystack.lowercased()
        let n = needle.lowercased()
        switch op {
        case .contains:     return h.contains(n)
        case .notContains:  return !h.contains(n)
        case .equals:       return h == n
        case .startsWith:   return h.hasPrefix(n)
        case .endsWith:     return h.hasSuffix(n)
        case .matchesRegex:
            guard !n.isEmpty else { return false }
            return (try? NSRegularExpression(pattern: needle, options: .caseInsensitive)
                .firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack))) != nil
        case .isEmpty:      return haystack.isEmpty
        case .isNotEmpty:   return !haystack.isEmpty
        }
    }

    // MARK: - Pill construction

    private func makePill(_ def: AXRulePill, context: AXContext, clipboard: String?) -> AXResolvedPill {
        let label  = interpolate(def.label,       context: context, clipboard: clipboard)
        let action = interpolate(def.actionValue, context: context, clipboard: clipboard)
        let type   = def.actionType
        // Snapshot context vars now so the closure captures fixed values, not live AX state
        let envVars: [String: String] = [
            "CD_APP_NAME":      context.appName,
            "CD_BUNDLE_ID":     context.bundleId,
            "CD_WINDOW_TITLE":  context.windowTitle  ?? "",
            "CD_SELECTED_TEXT": context.selectedText ?? "",
            "CD_URL":           context.currentURL   ?? "",
            "CD_FILE":          context.selectedFilePaths.first ?? "",
            "CD_CLIPBOARD":     clipboard ?? "",
        ]
        return AXResolvedPill(
            id: "axrule-\(def.id)",
            name: label,
            icon: def.icon,
            accentColor: def.accentColor,
            execute: { AXTriggerRuleEngine.shared.run(type: type, value: action, envVars: envVars) }
        )
    }

    private func interpolate(_ template: String, context: AXContext, clipboard: String?) -> String {
        let encoded = (context.selectedText ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedURL = (context.currentURL ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return template
            .replacingOccurrences(of: "{appName}",      with: context.appName)
            .replacingOccurrences(of: "{bundleId}",     with: context.bundleId)
            .replacingOccurrences(of: "{windowTitle}",  with: context.windowTitle  ?? "")
            .replacingOccurrences(of: "{selectedText}", with: context.selectedText ?? "")
            .replacingOccurrences(of: "{encodedText}",  with: encoded)
            .replacingOccurrences(of: "{clipboard}",    with: clipboard ?? "")
            .replacingOccurrences(of: "{encodedURL}",   with: encodedURL)
            .replacingOccurrences(of: "{url}",          with: context.currentURL ?? "")
            .replacingOccurrences(of: "{file}",         with: context.selectedFilePaths.first ?? "")
    }

    // MARK: - Execution

    func run(type: AppShortcut.ActionType, value: String, envVars: [String: String] = [:]) {
        switch type {
        case .openURL:
            if let url = URL(string: value) { NSWorkspace.shared.open(url) }

        case .openFile:
            NSWorkspace.shared.open(URL(fileURLWithPath: value))

        case .shellCommand:
            let shortLabel = String(value.prefix(60))
            Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-lc", value]
                var env = ProcessInfo.processInfo.environment
                envVars.forEach { env[$0] = $1 }
                proc.environment = env
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError  = pipe
                try? proc.run()
                proc.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let success = proc.terminationStatus == 0
                await MainActor.run {
                    ILauncherNotificationManager.shared.post(
                        title: success ? "Done" : "Shell error",
                        body: output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              ? shortLabel
                              : String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
                        icon: success ? "checkmark.circle.fill" : "xmark.circle.fill",
                        accentColor: success ? "green" : "red"
                    )
                }
            }

        case .appleScript:
            if let script = NSAppleScript(source: value) { script.executeAndReturnError(nil) }

        case .jxa:
            Task.detached(priority: .userInitiated) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("axrule_\(UUID().uuidString).js")
                try? value.write(to: tmp, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-l", "JavaScript", tmp.path]
                try? proc.run()
                proc.waitUntilExit()
            }

        case .scriptFile:
            // Execute an external script file with context injected as environment variables.
            // Determines interpreter from file extension (.sh → zsh, .py → python3, .js → node, .rb → ruby).
            let scriptPath = (value as NSString).expandingTildeInPath
            let fileName = (scriptPath as NSString).lastPathComponent
            Task.detached(priority: .userInitiated) {
                guard FileManager.default.isExecutableFile(atPath: scriptPath) ||
                      FileManager.default.fileExists(atPath: scriptPath) else {
                    await MainActor.run {
                        ILauncherNotificationManager.shared.post(
                            title: "Script not found",
                            body: scriptPath,
                            icon: "xmark.circle.fill",
                            accentColor: "red"
                        )
                    }
                    return
                }
                let ext = (scriptPath as NSString).pathExtension.lowercased()
                let interpreter: String
                switch ext {
                case "py":  interpreter = "/usr/bin/env python3"
                case "js":  interpreter = "/usr/bin/env node"
                case "rb":  interpreter = "/usr/bin/env ruby"
                default:    interpreter = "/bin/zsh"   // .sh or no extension
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-lc", "\(interpreter) \"\(scriptPath)\""]
                var env = ProcessInfo.processInfo.environment
                envVars.forEach { env[$0] = $1 }
                proc.environment = env
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError  = pipe
                try? proc.run()
                proc.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let success = proc.terminationStatus == 0
                await MainActor.run {
                    ILauncherNotificationManager.shared.post(
                        title: success ? fileName : "\(fileName) failed",
                        body: output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              ? (success ? "Completed" : "Exit code \(proc.terminationStatus)")
                              : String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
                        icon: success ? "checkmark.circle.fill" : "xmark.circle.fill",
                        accentColor: success ? "green" : "red"
                    )
                }
            }
        }
    }
}
