import SwiftUI

// MARK: - L2 AI Integration View
// Main interface for L2 AI features - combines file management and task execution

struct L2AIIntegrationView: View {
    @StateObject private var fileManager = L2AIFileManager.shared
    @StateObject private var taskExecutor = L2AITaskExecutor.shared
    @StateObject private var terminalBridge = TerminalAIBridge.shared
    
    @State private var query: String = ""
    @State private var selectedFiles: [URL] = []
    @State private var mode: L2Mode = .ask
    @State private var showingFileChanges = false
    @State private var showingTaskExecution = false
    @State private var isProcessing = false
    
    enum L2Mode: String, CaseIterable {
        case ask = "Ask"
        case edit = "Edit Files"
        case execute = "Execute Task"
        case learn = "Learn"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Mode selector
            modeSelector
            
            Divider()
            
            // Main content
            ScrollView {
                VStack(spacing: 20) {
                    // Query input
                    querySection
                    
                    // File selection
                    if mode == .edit {
                        fileSelectionSection
                    }
                    
                    // Recent operations
                    if mode == .learn {
                        learningSection
                    } else {
                        recentOperationsSection
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Action bar
            actionBar
        }
        .frame(minWidth: 600, minHeight: 400)
        .sheet(isPresented: $showingFileChanges) {
            FileChangesApprovalView(
                fileManager: fileManager,
                onApprove: {
                    showingFileChanges = false
                },
                onDeny: {
                    fileManager.cancelChanges()
                    showingFileChanges = false
                }
            )
        }
        .sheet(isPresented: $showingTaskExecution) {
            TaskExecutionView(
                taskExecutor: taskExecutor,
                onComplete: {
                    showingTaskExecution = false
                }
            )
        }
        .sheet(item: $taskExecutor.pendingToolChoice) { pending in
            ToolSelectionView(
                pending: pending,
                onSelect: { tool in
                    taskExecutor.approveToolChoice(tool)
                },
                onCancel: {
                    taskExecutor.denyToolChoice()
                }
            )
        }
        .sheet(item: $terminalBridge.pendingApproval) { pending in
            CommandApprovalView(
                command: pending.command,
                classification: pending.classification,
                purpose: pending.purpose,
                onApprove: { command in
                    terminalBridge.approveCommand(command)
                },
                onDeny: {
                    terminalBridge.denyCommand()
                }
            )
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(spacing: 12) {
            // Logo
            Image(systemName: "brain.head.profile")
                .font(.system(size: 32))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.purple, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text("L2 AI Assistant")
                    .font(.title2.weight(.bold))
                
                Text("Intelligent file management and task automation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Status indicator
            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Processing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Mode Selector
    
    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(L2Mode.allCases, id: \.self) { modeOption in
                Button(action: {
                    mode = modeOption
                }) {
                    Text(modeOption.rawValue)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(mode == modeOption ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Query Section
    
    private var querySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What would you like me to do?", systemImage: "text.bubble")
                .font(.headline)
            
            ZStack(alignment: .topLeading) {
                if query.isEmpty {
                    Text(placeholderText)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                }
                
                TextEditor(text: $query)
                    .font(.body)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
            
            // Suggestions
            suggestionChips
        }
    }
    
    private var placeholderText: String {
        switch mode {
        case .ask:
            return "Ask me anything about your project..."
        case .edit:
            return "Describe the changes you want to make...\nExample: \"Add error handling to all network calls\""
        case .execute:
            return "Describe the task you want to execute...\nExample: \"Compress all images in this folder\""
        case .learn:
            return "I can learn patterns from your operations and suggest improvements"
        }
    }
    
    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        query = suggestion
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
    
    private var suggestions: [String] {
        switch mode {
        case .ask:
            return [
                "Analyze my code structure",
                "Find potential bugs",
                "Suggest optimizations"
            ]
        case .edit:
            return [
                "Add documentation comments",
                "Refactor this function",
                "Update to latest Swift syntax"
            ]
        case .execute:
            return [
                "Compress all images",
                "Convert videos to MP4",
                "Create a backup"
            ]
        case .learn:
            return []
        }
    }
    
    // MARK: - File Selection
    
    private var fileSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Selected Files", systemImage: "folder")
                    .font(.headline)
                
                Spacer()
                
                Button("Choose Files...") {
                    chooseFiles()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            if selectedFiles.isEmpty {
                emptyFilesState
            } else {
                filesList
            }
        }
    }
    
    private var emptyFilesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            
            Text("No files selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text("Choose files to apply AI changes")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var filesList: some View {
        VStack(spacing: 8) {
            ForEach(selectedFiles, id: \.path) { fileURL in
                HStack {
                    Image(systemName: iconForFile(fileURL))
                        .foregroundStyle(.blue)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileURL.lastPathComponent)
                            .font(.body)
                        
                        Text(fileURL.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        selectedFiles.removeAll { $0 == fileURL }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    
    // MARK: - Recent Operations
    
    private var recentOperationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recent Operations", systemImage: "clock")
                .font(.headline)
            
            if fileManager.recentOperations.isEmpty {
                Text("No recent operations")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(fileManager.recentOperations.suffix(5).reversed()) { operation in
                    OperationRow(operation: operation)
                }
            }
        }
    }
    
    // MARK: - Learning Section
    
    private var learningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Learned Patterns", systemImage: "brain")
                .font(.headline)
            
            if fileManager.learningPatterns.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    
                    Text("No patterns learned yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("I'll learn from your successful operations")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(fileManager.learningPatterns) { pattern in
                    PatternRow(pattern: pattern)
                }
            }
        }
    }
    
    // MARK: - Action Bar
    
    private var actionBar: some View {
        HStack {
            // Context info
            if mode == .edit && !selectedFiles.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "doc.fill")
                    Text("\(selectedFiles.count) file(s)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Action button
            Button(action: processQuery) {
                HStack {
                    Image(systemName: actionIcon)
                    Text(actionTitle)
                }
                .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .disabled(query.isEmpty || (mode == .edit && selectedFiles.isEmpty))
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var actionTitle: String {
        switch mode {
        case .ask: return "Ask L2"
        case .edit: return "Generate Changes"
        case .execute: return "Execute Task"
        case .learn: return "Analyze Patterns"
        }
    }
    
    private var actionIcon: String {
        switch mode {
        case .ask: return "brain"
        case .edit: return "wand.and.stars"
        case .execute: return "play.fill"
        case .learn: return "brain.head.profile"
        }
    }
    
    // MARK: - Actions
    
    private func processQuery() {
        Task {
            isProcessing = true
            defer { isProcessing = false }

            // Use AppSettings.shared directly instead of looking in app delegate
            let settings = AppSettings.shared
            let aiProvider = settings.createAIProvider()

            do {
                switch mode {
                case .ask:
                    // Use L2UnifiedAssistant for intelligent query processing
                    let context: UserContext = selectedFiles.isEmpty ? .none : .filesSelected(selectedFiles)
                    let response = await L2UnifiedAssistant.shared.process(query, context: context)
                    // The response is now available via L2UnifiedAssistant.shared.lastResponse
                    print("L2 Response: \(response.message)")

                case .edit:
                    // Process file editing request
                    try await fileManager.processQuery(query, files: selectedFiles, aiProvider: aiProvider)
                    showingFileChanges = true

                case .execute:
                    // Execute task using L2UnifiedAssistant first to parse intent
                    let context = L2AITaskExecutor.FileContext(
                        selectedFiles: selectedFiles,
                        fileTypes: Set(selectedFiles.map { $0.pathExtension }),
                        totalSize: selectedFiles.compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 }.reduce(0, +)
                    )

                    _ = try await taskExecutor.executeTask(query: query, context: context, aiProvider: aiProvider)
                    showingTaskExecution = true

                case .learn:
                    // Analyze patterns using workflow engine
                    let workflows = L2WorkflowEngine.shared.findMatchingWorkflows(query: query)
                    print("Found \(workflows.count) matching workflows")
                }
            } catch {
                print("Error: \(error)")
            }
        }
    }
    
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        panel.begin { response in
            if response == .OK {
                selectedFiles = panel.urls
            }
        }
    }
    
    private func iconForFile(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "py": return "doc.text"
        case "js", "ts": return "doc.text"
        case "json": return "curlybraces"
        case "md": return "doc.richtext"
        case "jpg", "png", "gif": return "photo"
        case "mp4", "mov": return "video"
        default: return "doc"
        }
    }
}

// MARK: - Operation Row

struct OperationRow: View {
    let operation: L2AIFileManager.CompletedOperation
    
    var body: some View {
        HStack {
            Image(systemName: operation.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(operation.success ? .green : .red)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.userQuery)
                    .font(.body)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(operation.operationType)
                        .font(.caption)
                    
                    Text("•")
                        .font(.caption)
                    
                    Text("\(operation.filesAffected) file(s)")
                        .font(.caption)
                    
                    Text("•")
                        .font(.caption)
                    
                    Text(operation.timestamp, style: .relative)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Pattern Row

struct PatternRow: View {
    let pattern: L2AIFileManager.LearningPattern
    
    var body: some View {
        HStack {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(pattern.name)
                    .font(.body)
                
                Text(pattern.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text("Used \(pattern.usage)×")
                    .font(.caption)
                
                Text("\(Int(pattern.successRate * 100))% success")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Task Execution View

struct TaskExecutionView: View {
    @ObservedObject var taskExecutor: L2AITaskExecutor
    let onComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            if let task = taskExecutor.currentTask {
                Text("Task: \(task.query)")
                    .font(.headline)
                
                ProgressView(value: task.progress)
                
                if let step = task.currentStep {
                    Text("Step: \(step.description)")
                        .font(.body)
                }
                
                Button("Close") {
                    onComplete()
                }
            }
        }
        .padding()
        .frame(width: 500, height: 300)
    }
}

// MARK: - Tool Selection View

struct ToolSelectionView: View {
    let pending: L2AITaskExecutor.PendingToolChoice
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select a tool")
                .font(.headline)
            Text(pending.stepDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List {
                ForEach(pending.tools, id: \.self) { tool in
                    Button {
                        onSelect(tool)
                    } label: {
                        HStack {
                            Text(tool)
                            Spacer()
                            if !L2AITaskExecutor.TerminalTool.isInstalled(tool) {
                                Text("Install")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 180)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 420, height: 360)
    }
}

// MARK: - Preview

#Preview {
    L2AIIntegrationView()
}
