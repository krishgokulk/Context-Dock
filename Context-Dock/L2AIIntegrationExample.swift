import SwiftUI
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Sample Integration
// Shows how to integrate L2 AI system into your app
// NOTE: This is an example file - @main is disabled since ILauncherApp is the real entry point

// @main  // DISABLED - ILauncherApp.swift is the actual entry point
struct L2AIApp: App {
    @StateObject private var appSettings = AppSettings()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appSettings)
        }
        
        // L2 AI Window
        Window("L2 AI Assistant", id: "l2-ai") {
            L2AIIntegrationView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .defaultSize(width: 900, height: 700)
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @EnvironmentObject var appSettings: AppSettings
    @StateObject private var terminalBridge = TerminalAIBridge.shared
    
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            terminalView
        }
        .sheet(item: Binding(
            get: { terminalBridge.pendingApproval.map { SheetItem(pending: $0) } },
            set: { _ in }
        )) { item in
            CommandApprovalView(
                command: item.pending.command,
                classification: item.pending.classification,
                purpose: item.pending.purpose,
                onApprove: { command in
                    terminalBridge.approveCommand(command)
                },
                onDeny: {
                    terminalBridge.denyCommand()
                }
            )
        }
    }
    
    // Helper struct to make PendingCommand Identifiable for sheet binding
    private struct SheetItem: Identifiable {
        let id = UUID()
        let pending: TerminalAIBridge.PendingCommand
    }
    
    private var sidebar: some View {
        List {
            Section("AI Features") {
                NavigationLink(destination: L2AIIntegrationView()) {
                    Label("L2 Assistant", systemImage: "brain")
                }
                
                NavigationLink(destination: TaskHistoryView()) {
                    Label("Task History", systemImage: "clock")
                }
                
                NavigationLink(destination: LearningPatternsView()) {
                    Label("Learned Patterns", systemImage: "lightbulb")
                }
            }
            
            Section("Terminal") {
                NavigationLink(destination: TerminalView()) {
                    Label("Terminal", systemImage: "terminal")
                }
                
                NavigationLink(destination: CommandHistoryView()) {
                    Label("Command History", systemImage: "list.bullet")
                }
            }
            
            Section("Settings") {
                NavigationLink(destination: L2ExampleSettingsView()) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("ILauncher")
    }
    
    private var terminalView: some View {
        Text("Terminal View")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Task History View

struct TaskHistoryView: View {
    @StateObject private var taskExecutor = L2AITaskExecutor.shared
    @StateObject private var fileManager = L2AIFileManager.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // File Operations
                if !fileManager.recentOperations.isEmpty {
                    Section {
                        ForEach(fileManager.recentOperations.reversed()) { operation in
                            OperationRow(operation: operation)
                        }
                    } header: {
                        Text("File Operations")
                            .font(.headline)
                    }
                }
                
                // Terminal Commands
                Section {
                    ForEach(TerminalAIBridge.shared.executionHistory.suffix(20).reversed()) { execution in
                        CommandExecutionRow(execution: execution)
                    }
                } header: {
                    Text("Terminal Commands")
                        .font(.headline)
                }
            }
            .padding()
        }
        .navigationTitle("Task History")
    }
}

// MARK: - Command Execution Row View

struct CommandExecutionRow: View {
    let execution: TerminalAIBridge.CommandExecution
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: execution.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(execution.exitCode == 0 ? .green : .red)
                
                Text(execution.command)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(isExpanded ? nil : 1)
                
                Spacer()
                
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Category:")
                            .foregroundStyle(.secondary)
                        Text(execution.category)
                        
                        Text("•")
                            .foregroundStyle(.secondary)
                        
                        Text("Risk:")
                            .foregroundStyle(.secondary)
                        Text(execution.riskLevel)
                        
                        Text("•")
                            .foregroundStyle(.secondary)
                        
                        Text("Duration:")
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2fs", execution.duration))
                    }
                    .font(.caption)
                    
                    if !execution.output.isEmpty {
                        GroupBox {
                            ScrollView {
                                Text(execution.output)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                        } label: {
                            Text("Output")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }
        .padding()
        .background(SwiftUI.Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Learning Patterns View

struct LearningPatternsView: View {
    @StateObject private var fileManager = L2AIFileManager.shared
    @State private var selectedPattern: L2AIFileManager.LearningPattern?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if fileManager.learningPatterns.isEmpty {
                    emptyState
                } else {
                    ForEach(fileManager.learningPatterns) { pattern in
                        PatternDetailView(pattern: pattern)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Learned Patterns")
        .toolbar {
            ToolbarItem {
                Button(action: exportPatterns) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            
            Text("No Patterns Learned Yet")
                .font(.title2)
                .foregroundStyle(.secondary)
            
            Text("Use L2 AI to perform operations, and I'll learn patterns automatically")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private func exportPatterns() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "learned_patterns.json"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    let data = try JSONEncoder().encode(fileManager.learningPatterns)
                    try data.write(to: url)
                } catch {
                    print("Export failed: \(error)")
                }
            }
        }
    }
}

struct PatternDetailView: View {
    let pattern: L2AIFileManager.LearningPattern
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(pattern.name)
                        .font(.headline)
                    
                    Text(pattern.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                        Text("\(Int(pattern.successRate * 100))%")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    
                    Text("Used \(pattern.usage) times")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up.circle" : "chevron.down.circle")
                }
                .buttonStyle(.plain)
            }
            
            if isExpanded {
                Divider()
                
                // Trigger context
                VStack(alignment: .leading, spacing: 8) {
                    Text("Triggers")
                        .font(.subheadline.weight(.semibold))
                    
                    if let fileType = pattern.triggerContext.fileType {
                        Label("File type: .\(fileType)", systemImage: "doc")
                            .font(.caption)
                    }
                    
                    if !pattern.triggerContext.keywords.isEmpty {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("Keywords: \(pattern.triggerContext.keywords.joined(separator: ", "))")
                        }
                        .font(.caption)
                    }
                    
                    if let projectType = pattern.triggerContext.projectType {
                        Label("Project type: \(projectType)", systemImage: "folder")
                            .font(.caption)
                    }
                }
                .padding(.vertical, 8)
                
                // Template preview
                GroupBox {
                    ScrollView {
                        Text(pattern.template.prefix(500))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                } label: {
                    Text("Template")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding()
        .background(SwiftUI.Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - L2 Settings View (Example)

struct L2ExampleSettingsView: View {
    @EnvironmentObject var appSettings: AppSettings
    
    var body: some View {
        Form {
            Section("AI Provider") {
                // Your existing AI provider settings
                Text("AI provider configuration here")
            }
            
            Section("L2 Behavior") {
                Toggle("Auto-execute safe commands", isOn: .constant(true))
                Toggle("Learn from operations", isOn: .constant(true))
                Toggle("Show detailed reasoning", isOn: .constant(true))
            }
            
            Section("Safety") {
                Toggle("Require approval for medium risk", isOn: .constant(true))
                Toggle("Block high risk commands", isOn: .constant(true))
                Toggle("Maintain audit log", isOn: .constant(true))
                
                Button("View Audit Log") {
                    openAuditLog()
                }
            }
            
            Section("Data") {
                Button("Export Learning Patterns") {
                    exportPatterns()
                }
                
                Button("Clear Command History") {
                    clearHistory()
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("L2 Settings")
    }
    
    private func openAuditLog() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ILauncher/terminal_audit.log")
        NSWorkspace.shared.open(logURL)
    }
    
    private func exportPatterns() {
        // Export logic
    }
    
    private func clearHistory() {
        TerminalAIBridge.shared.executionHistory.removeAll()
    }
}

// MARK: - Command History View

struct CommandHistoryView: View {
    @StateObject private var bridge = TerminalAIBridge.shared
    @State private var searchText = ""
    
    var filteredHistory: [TerminalAIBridge.CommandExecution] {
        if searchText.isEmpty {
            return Array(bridge.executionHistory.reversed())
        } else {
            return bridge.executionHistory.reversed().filter {
                $0.command.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                
                TextField("Search commands...", text: $searchText)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background(SwiftUI.Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Commands list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredHistory) { execution in
                        CommandExecutionRow(execution: execution)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
        .navigationTitle("Command History")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Export to CSV") {
                        exportToCSV()
                    }
                    Button("Export to JSON") {
                        exportToJSON()
                    }
                    Divider()
                    Button("Clear All", role: .destructive) {
                        bridge.executionHistory.removeAll()
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
    
    private func exportToCSV() {
        // CSV export logic
    }
    
    private func exportToJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "command_history.json"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    let data = try JSONEncoder().encode(bridge.executionHistory)
                    try data.write(to: url)
                } catch {
                    print("Export failed: \(error)")
                }
            }
        }
    }
}

// MARK: - Terminal View Placeholder

struct TerminalView: View {
    var body: some View {
        Text("Terminal View")
            .font(.title)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Note about AppSettings properties
// The following properties should be added to AppSettings.swift instead of here:
// - autoExecuteSafeCommands
// - enableLearning
// - showDetailedReasoning
// - requireMediumRiskApproval
// - blockHighRisk
// - maintainAuditLog

