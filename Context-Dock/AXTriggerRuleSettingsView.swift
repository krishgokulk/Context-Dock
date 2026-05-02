// AXTriggerRuleSettingsView.swift
// Context-Dock
//
// Sheet for creating a new AXTriggerRule and a detail editor for an existing rule.

import SwiftUI

// MARK: - AXRuleEditSheet

struct AXRuleEditSheet: View {
    let rule: AXTriggerRule?
    let onCreate: (AXTriggerRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isEnabled: Bool
    @State private var conditionLogic: AXTriggerRule.ConditionLogic
    @State private var conditions: [AXTriggerCondition]
    @State private var pills: [AXRulePill]
    @State private var priority: Int
    @State private var scopeBundleId: String   // "" = global
    @State private var scopeAppName: String

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !($0.localizedName ?? "").isEmpty }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    init(rule: AXTriggerRule?, onCreate: @escaping (AXTriggerRule) -> Void) {
        self.rule = rule
        self.onCreate = onCreate
        _name           = State(initialValue: rule?.name           ?? "New Rule")
        _isEnabled      = State(initialValue: rule?.isEnabled      ?? true)
        _conditionLogic = State(initialValue: rule?.conditionLogic ?? .all)
        _conditions     = State(initialValue: rule?.conditions     ?? [AXTriggerCondition()])
        _pills          = State(initialValue: rule?.pills          ?? [AXRulePill()])
        _priority       = State(initialValue: rule?.priority       ?? 0)
        _scopeBundleId  = State(initialValue: rule?.bundleId       ?? "")
        _scopeAppName   = State(initialValue: rule?.appName        ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(rule == nil ? "New Trigger Rule" : "Edit Rule")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save") {
                    var r = rule ?? AXTriggerRule()
                    r.name           = name
                    r.isEnabled      = isEnabled
                    r.conditionLogic = conditionLogic
                    r.conditions     = conditions
                    r.pills          = pills
                    r.priority       = priority
                    r.bundleId       = scopeBundleId.isEmpty ? nil : scopeBundleId
                    r.appName        = scopeAppName.isEmpty  ? nil : scopeAppName
                    onCreate(r)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic info
                    GroupBox("Rule") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Name").frame(width: 80, alignment: .trailing)
                                TextField("e.g. GitHub Repo Detected", text: $name)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("Priority").frame(width: 80, alignment: .trailing)
                                Stepper("\(priority)", value: $priority, in: 0...100)
                            }
                            HStack {
                                Text("Enabled").frame(width: 80, alignment: .trailing)
                                Toggle("", isOn: $isEnabled).labelsHidden()
                            }
                            Divider()
                            // App scope — nil = global, bundleId = app-only
                            HStack(alignment: .top, spacing: 0) {
                                Text("App Scope").frame(width: 80, alignment: .trailing)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Menu {
                                        Button("Global (all apps)") {
                                            scopeBundleId = ""
                                            scopeAppName  = ""
                                        }
                                        Divider()
                                        ForEach(runningApps, id: \.processIdentifier) { app in
                                            Button(action: {
                                                scopeBundleId = app.bundleIdentifier ?? ""
                                                scopeAppName  = app.localizedName    ?? ""
                                            }) {
                                                Text(app.localizedName ?? app.bundleIdentifier ?? "")
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            if scopeBundleId.isEmpty {
                                                Image(systemName: "globe")
                                                    .foregroundStyle(.secondary)
                                                Text("Global — matches any app")
                                                    .foregroundStyle(.secondary)
                                            } else {
                                                AppBundleIconView(
                                                    bundleId: scopeBundleId,
                                                    fallbackSymbol: "app.fill",
                                                    size: 16, cornerRadius: 3
                                                )
                                                Text(scopeAppName.isEmpty ? scopeBundleId : scopeAppName)
                                            }
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()

                                    if !scopeBundleId.isEmpty {
                                        Text("Only triggers in \(scopeAppName.isEmpty ? scopeBundleId : scopeAppName). App-scoped rules are evaluated before global rules.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Evaluates in every app. Use app-scoped rules to avoid false matches.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.leading, 8)
                            }
                        }
                        .padding(8)
                    }

                    // Conditions
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Match")
                                Picker("", selection: $conditionLogic) {
                                    Text("ALL conditions").tag(AXTriggerRule.ConditionLogic.all)
                                    Text("ANY condition").tag(AXTriggerRule.ConditionLogic.any)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 220)
                                Spacer()
                                Button { conditions.append(AXTriggerCondition()) } label: {
                                    Label("Add", systemImage: "plus")
                                }
                                .controlSize(.small)
                            }
                            ForEach($conditions) { $cond in
                                conditionRow($cond) {
                                    conditions.removeAll { $0.id == cond.id }
                                }
                            }
                        }
                        .padding(8)
                    } label: {
                        Text("Conditions")
                    }

                    // Pills
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Spacer()
                                Button { pills.append(AXRulePill()) } label: {
                                    Label("Add Pill", systemImage: "plus")
                                }
                                .controlSize(.small)
                            }
                            ForEach($pills) { $pill in
                                pillRow($pill) {
                                    pills.removeAll { $0.id == pill.id }
                                }
                            }
                        }
                        .padding(8)
                    } label: {
                        Text("Pills")
                    }
                }
                .padding()
            }
        }
        .frame(width: 560, height: 600)
    }

    @ViewBuilder
    private func conditionRow(_ cond: Binding<AXTriggerCondition>, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: cond.field) {
                ForEach(AXConditionField.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Picker("", selection: cond.op) {
                ForEach(AXConditionOperator.allCases) { o in
                    Text(o.rawValue).tag(o)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            if cond.wrappedValue.op.needsValue {
                TextField("value", text: cond.value)
                    .textFieldStyle(.roundedBorder)
            } else {
                Spacer()
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func pillRow(_ pill: Binding<AXRulePill>, onDelete: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Label", text: pill.label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                TextField("SF Symbol", text: pill.icon)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Picker("", selection: pill.actionType) {
                    Text("Open URL").tag(AppShortcut.ActionType.openURL)
                    Text("Shell").tag(AppShortcut.ActionType.shellCommand)
                    Text("AppleScript").tag(AppShortcut.ActionType.appleScript)
                    Text("JXA").tag(AppShortcut.ActionType.jxa)
                    Text("Script File").tag(AppShortcut.ActionType.scriptFile)
                }
                .labelsHidden()
                .frame(width: 120)
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            switch pill.wrappedValue.actionType {
            case .shellCommand, .appleScript, .jxa:
                TextEditor(text: pill.actionValue)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 100)
                    .border(Color.secondary.opacity(0.3), width: 0.5)
            case .scriptFile:
                HStack(spacing: 6) {
                    TextField("~/Scripts/my-script.sh", text: pill.actionValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsOtherFileTypes = true
                        if panel.runModal() == .OK, let url = panel.url {
                            pill.actionValue.wrappedValue = url.path
                        }
                    }
                    .controlSize(.small)
                }
            default:
                TextField("Action value  — use {variables} to insert context", text: pill.actionValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    private var availableVariablesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                let vars: [(String, String)] = [
                    ("{appName}",      "Frontmost app name"),
                    ("{bundleId}",     "App bundle identifier"),
                    ("{windowTitle}",  "Current window title"),
                    ("{selectedText}", "Text selected via AX API"),
                    ("{clipboard}",    "Current clipboard content"),
                    ("{url}",          "Browser URL (Safari/Chrome)"),
                    ("{file}",         "Selected file path (Finder)"),
                    ("{encodedText}",  "URL-encoded selected text"),
                    ("{encodedURL}",   "URL-encoded current URL"),
                ]
                ForEach(vars, id: \.0) { name, desc in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(name)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(width: 150, alignment: .leading)
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Available Variables", systemImage: "curlybraces")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AXRuleDetailView

struct AXRuleDetailView: View {
    @Binding var rule: AXTriggerRule
    @ObservedObject private var settings = AppSettings.shared
    @State private var showEditSheet = false
    @State private var testResults: [(field: String, liveValue: String, matched: Bool)]? = nil
    @State private var isTesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name).font(.title2.bold())
                        Text("\(rule.conditions.count) condition\(rule.conditions.count == 1 ? "" : "s") · \(rule.pills.count) pill\(rule.pills.count == 1 ? "" : "s") · priority \(rule.priority)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: $rule.isEnabled)
                        .toggleStyle(.switch)
                    Button("Edit") { showEditSheet = true }
                        .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        settings.removeAXRule(rule)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                // Conditions
                GroupBox("Conditions (\(rule.conditionLogic == .all ? "ALL must match" : "ANY must match"))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rule.conditions) { cond in
                            HStack {
                                Image(systemName: cond.field.sfSymbol)
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                Text(cond.field.rawValue)
                                    .frame(width: 110, alignment: .leading)
                                Text(cond.op.rawValue)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .leading)
                                if cond.op.needsValue {
                                    Text(cond.value)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(8)
                }

                // Test Against Current Screen
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button {
                                isTesting = true
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let results = AXTriggerRuleEngine.shared.testAgainstCurrentScreen(rule: rule)
                                    DispatchQueue.main.async {
                                        testResults = results
                                        isTesting = false
                                    }
                                }
                            } label: {
                                Label(isTesting ? "Testing…" : "Test Against Current Screen", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isTesting)

                            if testResults != nil {
                                Button("Clear") { testResults = nil }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }

                        if let results = testResults {
                            Divider()
                            let allMatched = results.allSatisfy { $0.matched }
                            let anyMatched = results.contains { $0.matched }
                            let overallMatch = rule.conditionLogic == .all ? allMatched : anyMatched
                            HStack(spacing: 6) {
                                Image(systemName: overallMatch ? "checkmark.seal.fill" : "xmark.seal.fill")
                                    .foregroundStyle(overallMatch ? .green : .red)
                                Text(overallMatch ? "Rule would trigger" : "Rule would NOT trigger")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(overallMatch ? .green : .red)
                            }
                            .padding(.bottom, 4)

                            ForEach(results, id: \.field) { r in
                                HStack(spacing: 8) {
                                    Image(systemName: r.matched ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(r.matched ? .green : .red)
                                        .frame(width: 18)
                                    Text(r.field)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 110, alignment: .leading)
                                    Text(r.liveValue.isEmpty ? "(empty)" : r.liveValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Live Test", systemImage: "waveform.path.ecg")
                }

                // Pills
                GroupBox("Pills") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rule.pills) { pill in
                            HStack(spacing: 10) {
                                Image(systemName: pill.icon)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pill.label).font(.subheadline)
                                    Text(pill.actionValue)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(pill.actionType.rawValue)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.15))
                                    .cornerRadius(4)
                            }
                            .padding(6)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                        }
                    }
                    .padding(8)
                }

                // Available Variables reference
                availableVariablesSection
            }
            .padding()
        }
        .sheet(isPresented: $showEditSheet) {
            AXRuleEditSheet(rule: rule) { updated in
                settings.updateAXRule(updated)
            }
        }
    }

    private var availableVariablesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                let vars: [(String, String)] = [
                    ("{appName}",      "Frontmost app name"),
                    ("{bundleId}",     "App bundle identifier"),
                    ("{windowTitle}",  "Current window title"),
                    ("{selectedText}", "Text selected via AX API"),
                    ("{clipboard}",    "Current clipboard content"),
                    ("{url}",          "Browser URL (Safari/Chrome)"),
                    ("{file}",         "Selected file path (Finder)"),
                    ("{encodedText}",  "URL-encoded selected text"),
                    ("{encodedURL}",   "URL-encoded current URL"),
                ]
                ForEach(vars, id: \.0) { name, desc in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(name)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(width: 150, alignment: .leading)
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("Available Variables", systemImage: "curlybraces")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }
}
