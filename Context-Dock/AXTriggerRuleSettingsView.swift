// AXTriggerRuleSettingsView.swift
// ILauncher
//
// Settings UI for AX Trigger Rules —
// "when I see X on screen, show pill Y"

import SwiftUI

// MARK: - Main List View

struct AXTriggerRuleSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var editingRule: AXTriggerRule? = nil
    @State private var showAddSheet  = false
    @State private var testResults: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            ruleList
            Divider()
            detailOrEmpty
        }
        .sheet(isPresented: $showAddSheet) {
            AXRuleEditSheet(rule: nil) { newRule in
                settings.addAXRule(newRule)
                editingRule = newRule
            }
        }
        .sheet(item: $editingRule) { rule in
            AXRuleEditSheet(rule: rule) { updated in
                settings.updateAXRule(updated)
            }
        }
    }

    // MARK: Left panel — rule list

    private var ruleList: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Automation Rules")
                    .font(.headline)
                Spacer()
                Button {
                    let blank = AXTriggerRule(name: "New Rule")
                    settings.addAXRule(blank)
                    editingRule = blank
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.blue, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Rule rows
            if settings.axTriggerRules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bolt.badge.clock")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No rules yet")
                        .font(.headline)
                    Text("Rules show context-aware pills\nwhen conditions match your screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Load Examples") {
                        settings.axTriggerRules = AXTriggerRule.builtInExamples
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { editingRule?.id },
                    set: { id in editingRule = settings.axTriggerRules.first { $0.id == id } }
                )) {
                    ForEach($settings.axTriggerRules) { $rule in
                        ruleRow(rule: $rule)
                            .tag(rule.id)
                    }
                    .onMove { from, to in
                        settings.axTriggerRules.move(fromOffsets: from, toOffset: to)
                    }
                    .onDelete { idx in
                        settings.axTriggerRules.remove(atOffsets: idx)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 240)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Rule row

    private func ruleRow(rule: Binding<AXTriggerRule>) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .scaleEffect(0.75)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.wrappedValue.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(ruleSummary(rule.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Hotkey badge
            if let sym = hotkeyDisplaySymbol(rule.wrappedValue.hotkeyString) {
                Text(sym)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 4))
            }

            // Pill count badge
            if !rule.wrappedValue.pills.isEmpty {
                Text("\(rule.wrappedValue.pills.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.blue, in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit") { editingRule = rule.wrappedValue }
            Button("Duplicate") {
                var copy = rule.wrappedValue
                copy.id   = UUID()
                copy.name = copy.name + " (copy)"
                settings.addAXRule(copy)
            }
            Divider()
            Button("Delete", role: .destructive) {
                settings.removeAXRule(rule.wrappedValue)
                if editingRule?.id == rule.wrappedValue.id { editingRule = nil }
            }
        }
    }

    // MARK: Right panel

    @ViewBuilder
    private var detailOrEmpty: some View {
        if let rule = editingRule,
           let idx = settings.axTriggerRules.firstIndex(where: { $0.id == rule.id }) {
            AXRuleDetailView(rule: $settings.axTriggerRules[idx])
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bolt.badge.clock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Select a rule to edit")
                    .foregroundStyle(.secondary)
                Text("Rules evaluate live AX context every time\nthe dock refreshes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Helpers

    private func ruleSummary(_ rule: AXTriggerRule) -> String {
        guard !rule.conditions.isEmpty else { return "No conditions" }
        let logic = rule.conditionLogic == .all ? "AND" : "OR"
        let count = rule.conditions.count
        return "\(count) condition\(count == 1 ? "" : "s") (\(logic)) · \(rule.pills.count) pill\(rule.pills.count == 1 ? "" : "s")"
    }

    /// Converts "cmd+shift:d" → "⌘⇧D", returns nil if hotkeyString is nil.
    func hotkeyDisplaySymbol(_ hotkeyString: String?) -> String? {
        guard let hs = hotkeyString, !hs.isEmpty else { return nil }
        let parts = hs.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return hs }
        let mods = parts[0].split(separator: "+").map(String.init)
        var sym = ""
        if mods.contains("ctrl")  { sym += "⌃" }
        if mods.contains("opt")   { sym += "⌥" }
        if mods.contains("shift") { sym += "⇧" }
        if mods.contains("cmd")   { sym += "⌘" }
        sym += parts[1].uppercased()
        return sym
    }
}

// MARK: - Detail / Inline Editor

struct AXRuleDetailView: View {
    @Binding var rule: AXTriggerRule
    @State private var editingPillIdx: Int? = nil
    @State private var showTestSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Name + priority
                Group {
                    sectionHeader("Rule", icon: "bolt")
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Name").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                            TextField("Rule name", text: $rule.name)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Priority").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                            Stepper("\(rule.priority)", value: $rule.priority, in: 0...100)
                            Text("Higher = shown first").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Enabled").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                            Toggle("", isOn: $rule.isEnabled).labelsHidden()
                        }
                        HStack(alignment: .top) {
                            Text("Hotkey").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                HotkeyRecorderView(hotkeyString: $rule.hotkeyString)
                                Text("Press hotkey from any app to fire the first pill instantly — dock stays hidden.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }

                // Conditions
                Group {
                    HStack {
                        sectionHeader("Conditions", icon: "checklist")
                        Spacer()
                        Picker("", selection: $rule.conditionLogic) {
                            Text("ALL match (AND)").tag(AXTriggerRule.ConditionLogic.all)
                            Text("ANY match (OR)").tag(AXTriggerRule.ConditionLogic.any)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                        Button {
                            rule.conditions.append(AXTriggerCondition())
                        } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }

                    if rule.conditions.isEmpty {
                        Text("No conditions — rule will never fire. Add at least one.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(8)
                    } else {
                        VStack(spacing: 6) {
                            ForEach($rule.conditions) { $cond in
                                ConditionRow(condition: $cond) {
                                    rule.conditions.removeAll { $0.id == cond.id }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                // Pills
                Group {
                    HStack {
                        sectionHeader("Pills", icon: "capsule.fill")
                        Spacer()
                        Button {
                            rule.pills.append(AXRulePill())
                        } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }

                    if rule.pills.isEmpty {
                        Text("No pills — add at least one to show in dock.")
                            .font(.caption).foregroundStyle(.orange).padding(8)
                    } else {
                        VStack(spacing: 6) {
                            ForEach($rule.pills) { $pill in
                                PillRow(pill: $pill) {
                                    rule.pills.removeAll { $0.id == pill.id }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                // Variable reference
                variableReference

                // Test button
                HStack {
                    Spacer()
                    Button {
                        showTestSheet = true
                    } label: {
                        Label("Test Against Current Screen", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showTestSheet) {
            AXRuleTestSheet(rule: rule)
        }
    }

    // MARK: Variable reference card

    private var variableReference: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Available Variables", icon: "curlybraces")
            let vars: [(String, String)] = [
                ("{appName}",      "Frontmost app name"),
                ("{bundleId}",     "App bundle identifier"),
                ("{windowTitle}",  "Current window title"),
                ("{selectedText}", "Text selected via AX API"),
                ("{clipboard}",    "Current clipboard content"),
                ("{url}",          "Browser URL (Safari/Chrome)"),
                ("{encodedURL}",   "URL-encoded browser URL"),
                ("{file}",         "Selected file path (Finder)"),
                ("{encodedText}",  "URL-encoded selected text"),
                ("$CD_*",          "Script File env vars (CD_URL, CD_FILE…)"),
            ]
            VStack(alignment: .leading, spacing: 4) {
                ForEach(vars, id: \.0) { pair in
                    HStack(spacing: 8) {
                        Text(pair.0)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(width: 130, alignment: .leading)
                        Text(pair.1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - Condition Row

struct ConditionRow: View {
    @Binding var condition: AXTriggerCondition
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Field picker
            Picker("", selection: $condition.field) {
                ForEach(AXConditionField.allCases) { f in
                    Label(f.rawValue, systemImage: f.sfSymbol).tag(f)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            // Operator picker
            Picker("", selection: $condition.op) {
                ForEach(AXConditionOperator.allCases) { op in
                    Text(op.rawValue).tag(op)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            // Value field (hidden for isEmpty / isNotEmpty)
            if condition.op.needsValue {
                TextField("value", text: $condition.value)
                    .textFieldStyle(.roundedBorder)
            } else {
                Spacer()
            }

            // Delete
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Pill Row

struct PillRow: View {
    @Binding var pill: AXRulePill
    let onDelete: () -> Void

    private let accentOptions = ["blue","green","red","orange","purple","teal","gray","pink","yellow"]
    private let accentColors: [String: Color] = [
        "blue": .blue, "green": .green, "red": .red, "orange": .orange,
        "purple": .purple, "teal": .teal, "gray": .gray, "pink": .pink, "yellow": .yellow
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Icon
                TextField("SF Symbol", text: $pill.icon)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)

                // Preview
                Image(systemName: pill.icon.isEmpty ? "questionmark" : pill.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(accentColors[pill.accentColor] ?? .blue)

                // Label
                TextField("Pill label  (use {selectedText} etc.)", text: $pill.label)
                    .textFieldStyle(.roundedBorder)

                // Accent color dot picker
                HStack(spacing: 4) {
                    ForEach(accentOptions, id: \.self) { c in
                        Circle()
                            .fill(accentColors[c] ?? .blue)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle().stroke(Color.white.opacity(pill.accentColor == c ? 1 : 0), lineWidth: 2)
                            )
                            .onTapGesture { pill.accentColor = c }
                    }
                }

                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                // Action type picker
                Picker("", selection: $pill.actionType) {
                    Text("Open URL").tag(AppShortcut.ActionType.openURL)
                    Text("Open File").tag(AppShortcut.ActionType.openFile)
                    Text("Shell").tag(AppShortcut.ActionType.shellCommand)
                    Text("AppleScript").tag(AppShortcut.ActionType.appleScript)
                    Text("JXA").tag(AppShortcut.ActionType.jxa)
                    Text("Script File").tag(AppShortcut.ActionType.scriptFile)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
            }

            // Action value row — special UI for scriptFile
            if pill.actionType == .scriptFile {
                scriptFileRow
            } else {
                TextField(actionPlaceholder, text: $pill.actionValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var scriptFileRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("~/Scripts/download.sh", text: $pill.actionValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.title = "Select Script File"
                    panel.allowedContentTypes = []          // allow any file
                    panel.allowsOtherFileTypes = true
                    panel.canChooseDirectories = false
                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            pill.actionValue = url.path
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("New…") {
                    let savePanel = NSSavePanel()
                    savePanel.title = "Create New Script"
                    savePanel.nameFieldStringValue = "script.sh"
                    savePanel.begin { response in
                        if response == .OK, let url = savePanel.url {
                            let starter = """
                            #!/bin/zsh
                            # Context-Dock automation script
                            # Available environment variables:
                            #   CD_APP_NAME      — frontmost app name
                            #   CD_BUNDLE_ID     — frontmost app bundle ID
                            #   CD_WINDOW_TITLE  — current window title
                            #   CD_SELECTED_TEXT — selected text (AX API)
                            #   CD_URL           — current browser URL
                            #   CD_FILE          — selected file path (Finder)
                            #   CD_CLIPBOARD     — clipboard content

                            echo "Running for: $CD_APP_NAME"
                            echo "URL: $CD_URL"
                            """
                            try? starter.write(to: url, atomically: true, encoding: .utf8)
                            try? FileManager.default.setAttributes(
                                [.posixPermissions: 0o755],
                                ofItemAtPath: url.path
                            )
                            pill.actionValue = url.path
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Script preview / edit button
            if !pill.actionValue.isEmpty,
               FileManager.default.fileExists(atPath: (pill.actionValue as NSString).expandingTildeInPath) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text((pill.actionValue as NSString).lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit in Editor") {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: (pill.actionValue as NSString).expandingTildeInPath)
                        )
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.blue)
                }
            }

            // Env vars hint
            Text("Script receives context as $CD_APP_NAME, $CD_URL, $CD_SELECTED_TEXT, $CD_FILE, $CD_WINDOW_TITLE, $CD_CLIPBOARD, $CD_BUNDLE_ID")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionPlaceholder: String {
        switch pill.actionType {
        case .openURL:      return "https://… or scheme://…"
        case .openFile:     return "/Applications/..."
        case .shellCommand: return "echo '{selectedText}' | pbcopy"
        case .appleScript:  return "tell application \"Finder\" to ..."
        case .jxa:          return "Application(\"Safari\").openLocation(\"{url}\")"
        case .scriptFile:   return "~/Scripts/download.sh"
        }
    }
}

// MARK: - Add / Edit Sheet (quick-create from scratch)

struct AXRuleEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let rule: AXTriggerRule?
    let onSave: (AXTriggerRule) -> Void

    @State private var draft: AXTriggerRule

    init(rule: AXTriggerRule?, onSave: @escaping (AXTriggerRule) -> Void) {
        self.rule   = rule
        self.onSave = onSave
        _draft      = State(initialValue: rule ?? AXTriggerRule(
            name: "New Rule",
            conditions: [AXTriggerCondition(field: .appName, op: .equals, value: "")],
            pills: [AXRulePill()]
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(rule == nil ? "New Smart Rule" : "Edit Rule")
                    .font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.isEmpty || draft.conditions.isEmpty || draft.pills.isEmpty)
            }
            .padding(20)

            Divider()

            ScrollView {
                AXRuleDetailView(rule: $draft)
            }
        }
        .frame(width: 700, height: 560)
    }
}

// MARK: - Test Sheet

struct AXRuleTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let rule: AXTriggerRule

    @State private var testOutput: String = "Running…"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Test: \(rule.name)", systemImage: "play.fill")
                    .font(.title3.bold())
                Spacer()
                Button("Close") { dismiss() }
            }

            Divider()

            Text("Current AX Context")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(testOutput)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            Text(matchResult)
                .font(.headline)
                .foregroundStyle(matchPassed ? .green : .red)

            Spacer()
        }
        .padding(20)
        .frame(width: 500, height: 420)
        .onAppear { runTest() }
    }

    @State private var matchPassed = false

    private func runTest() {
        let ctx      = AXContextReader.shared.current
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""

        var lines: [String] = [
            "App Name:      \(ctx.appName)",
            "Bundle ID:     \(ctx.bundleId)",
            "Window Title:  \(ctx.windowTitle ?? "(none)")",
            "Selected Text: \(ctx.selectedText ?? "(none)")",
            "Clipboard:     \(clipboard.prefix(80))",
            "Current URL:   \(ctx.currentURL ?? "(none)")",
            "Focused Role:  \(ctx.focusedElementRole ?? "(none)")",
            "File Path:     \(ctx.selectedFilePaths.first ?? "(none)")",
            "",
            "── Condition Results ──────────────────────────────",
        ]

        let engine = AXTriggerRuleEngine.shared
        var allPassed: [Bool] = []
        for cond in rule.conditions {
            let result = evaluateCondition(cond, ctx: ctx, clipboard: clipboard)
            allPassed.append(result)
            let mark = result ? "✅" : "❌"
            lines.append("\(mark)  \(cond.field.rawValue) \(cond.op.rawValue) \"\(cond.value)\"")
        }

        let ruleMatches: Bool
        if rule.conditionLogic == .all {
            ruleMatches = allPassed.allSatisfy { $0 }
        } else {
            ruleMatches = allPassed.contains { $0 }
        }
        matchPassed = ruleMatches

        lines.append("")
        lines.append("Logic: \(rule.conditionLogic == .all ? "ALL (AND)" : "ANY (OR)")")
        lines.append("Would fire: \(ruleMatches ? "YES — \(rule.pills.count) pill(s) shown" : "NO")")

        testOutput = lines.joined(separator: "\n")
        _ = engine  // suppress unused warning
    }

    private var matchResult: String {
        matchPassed
            ? "✅ Rule matches — \(rule.pills.count) pill(s) will appear in dock"
            : "❌ Rule does not match current screen"
    }

    private func evaluateCondition(_ cond: AXTriggerCondition, ctx: AXContext, clipboard: String) -> Bool {
        let hay: String
        switch cond.field {
        case .appName:       hay = ctx.appName
        case .bundleId:      hay = ctx.bundleId
        case .windowTitle:   hay = ctx.windowTitle ?? ""
        case .selectedText:  hay = ctx.selectedText ?? ""
        case .clipboardText: hay = clipboard
        case .currentURL:    hay = ctx.currentURL ?? ""
        case .focusedRole:   hay = ctx.focusedElementRole ?? ""
        case .filePath:      hay = ctx.selectedFilePaths.first ?? ""
        }
        let h = hay.lowercased(), n = cond.value.lowercased()
        switch cond.op {
        case .contains:      return h.contains(n)
        case .notContains:   return !h.contains(n)
        case .equals:        return h == n
        case .startsWith:    return h.hasPrefix(n)
        case .endsWith:      return h.hasSuffix(n)
        case .matchesRegex:
            return (try? NSRegularExpression(pattern: cond.value, options: .caseInsensitive)
                .firstMatch(in: hay, range: NSRange(hay.startIndex..., in: hay))) != nil
        case .isEmpty:       return hay.isEmpty
        case .isNotEmpty:    return !hay.isEmpty
        }
    }
}

// MARK: - Hotkey Recorder

/// A button that records a single keyboard shortcut (e.g. ⌘⇧D) and stores it
/// in the compact "mod+mod:char" format used by AXTriggerRuleEngine.
struct HotkeyRecorderView: View {
    @Binding var hotkeyString: String?
    @State private var isRecording = false
    @State private var monitor: Any?

    private var displayLabel: String {
        guard let hs = hotkeyString, !hs.isEmpty else { return "Click to record…" }
        // Convert "cmd+shift:d" → "⌘⇧D"
        let parts = hs.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return hs }
        let mods = parts[0].split(separator: "+").map(String.init)
        var sym = ""
        if mods.contains("ctrl")  { sym += "⌃" }
        if mods.contains("opt")   { sym += "⌥" }
        if mods.contains("shift") { sym += "⇧" }
        if mods.contains("cmd")   { sym += "⌘" }
        sym += parts[1].uppercased()
        return sym
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(isRecording ? "Press a key…" : displayLabel) {
                startRecording()
            }
            .buttonStyle(.bordered)
            .foregroundStyle(isRecording ? .orange : (hotkeyString == nil ? .secondary : .primary))
            .controlSize(.small)

            if hotkeyString != nil {
                Button {
                    hotkeyString = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let captured = AXTriggerRuleEngine.eventToHotkeyString(event)
            if !captured.isEmpty {
                hotkeyString = captured
            }
            stopRecording()
            return nil   // consume the key
        }
        // Also stop if user clicks elsewhere
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { stopRecording() }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
