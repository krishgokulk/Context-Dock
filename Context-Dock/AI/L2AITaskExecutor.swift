import Foundation
import SwiftUI
import Combine

// MARK: - L2 AI Task Executor
// Intelligent task execution system that:
// 1. Analyzes user queries and creates todo lists
// 2. Detects installed terminal tools
// 3. Suggests & installs missing tools via Homebrew
// 4. Executes tasks and learns from them
// 5. Creates reusable extensions for future use

@MainActor
class L2AITaskExecutor: ObservableObject {
    static let shared = L2AITaskExecutor()
    
    // MARK: - Published State
    
    @Published var isAnalyzing = false
    @Published var currentTask: TaskExecution?
    @Published var installedTools: [TerminalTool] = []
    @Published var suggestedExtensions: [SuggestedExtension] = []
    @Published var pendingToolChoice: PendingToolChoice?
    
    // MARK: - Types
    
    struct TaskExecution: Identifiable {
        let id = UUID()
        let query: String
        let context: FileContext?
        var todoList: [TaskStep] = []
        var currentStepIndex: Int = 0
        var status: TaskStatus = .planning
        var result: String?
        var error: String?
        var suggestedExtension: ExtensionSuggestion?
        
        var currentStep: TaskStep? {
            todoList.indices.contains(currentStepIndex) ? todoList[currentStepIndex] : nil
        }
        
        var isComplete: Bool {
            status == .completed || status == .failed
        }
        
        var progress: Double {
            guard !todoList.isEmpty else { return 0 }
            return Double(currentStepIndex) / Double(todoList.count)
        }
    }
    
    struct TaskStep: Identifiable, Codable {
        let id = UUID()
        let description: String
        let requiredTool: String?
        let toolOptions: [String]?
        let command: String?
        var status: StepStatus = .pending
        var output: String?
        var error: String?
        
        enum StepStatus: String, Codable {
            case pending
            case checkingTool
            case installingTool
            case executing
            case completed
            case failed
            case skipped
        }
    }
    
    enum TaskStatus: String {
        case planning
        case executingSteps
        case completed
        case failed
    }
    
    struct FileContext {
        let selectedFiles: [URL]
        let fileTypes: Set<String>
        let totalSize: Int64
        
        var primaryFileType: String? {
            fileTypes.first
        }
        
        var description: String {
            let fileCount = selectedFiles.count
            let typeStr = fileTypes.joined(separator: ", ")
            return "\(fileCount) file(s) (\(typeStr))"
        }
    }
    
    struct TerminalTool: Identifiable, Codable {
        let id = UUID()
        let name: String
        let path: String
        let version: String?
        let installedViaHomebrew: Bool
        let capabilities: [String]
        
        static func isInstalled(_ toolName: String) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [toolName]
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
        
        static func detect(_ toolName: String) -> TerminalTool? {
            guard isInstalled(toolName) else { return nil }
            
            // Get path
            let pathProcess = Process()
            pathProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            pathProcess.arguments = [toolName]
            let pathPipe = Pipe()
            pathProcess.standardOutput = pathPipe
            
            var path = "/usr/bin/\(toolName)"
            do {
                try pathProcess.run()
                pathProcess.waitUntilExit()
                if let output = String(data: pathPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                    path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {}
            
            // Get version
            var version: String?
            let versionProcess = Process()
            versionProcess.executableURL = URL(fileURLWithPath: path)
            versionProcess.arguments = ["--version"]
            let versionPipe = Pipe()
            versionProcess.standardOutput = versionPipe
            versionProcess.standardError = versionPipe
            
            do {
                try versionProcess.run()
                versionProcess.waitUntilExit()
                if let output = String(data: versionPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                    version = output.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {}
            
            // Check if installed via Homebrew
            let isBrewInstalled = path.contains("/opt/homebrew/") || path.contains("/usr/local/Cellar/")
            
            // Map tool capabilities
            let capabilities = ToolCapabilities.get(for: toolName)
            
            return TerminalTool(
                name: toolName,
                path: path,
                version: version,
                installedViaHomebrew: isBrewInstalled,
                capabilities: capabilities
            )
        }
    }
    
    struct ExtensionSuggestion: Identifiable {
        let id = UUID()
        let name: String
        let description: String
        let script: String
        let triggers: [String] // File types that trigger this extension
        let reason: String
    }

    struct PendingToolChoice: Identifiable {
        let id = UUID()
        let stepDescription: String
        let tools: [String]
        let continuation: CheckedContinuation<String?, Never>
    }
    
    // MARK: - Tool Capabilities Database
    
    struct ToolCapabilities {
        static func get(for tool: String) -> [String] {
            let mapping: [String: [String]] = [
                // Image tools
                "imagemagick": ["convert", "resize", "compress", "format conversion", "watermark"],
                "convert": ["image conversion", "resize", "compress"],
                "sips": ["image processing", "resize", "format conversion"],
                "pngquant": ["PNG compression", "reduce colors"],
                "jpegoptim": ["JPEG compression", "optimize"],
                "optipng": ["PNG optimization"],
                
                // PDF tools
                "gs": ["PDF compression", "merge", "split", "convert"],
                "pdftk": ["PDF merge", "split", "rotate", "encrypt"],
                "qpdf": ["PDF linearization", "compression", "encryption"],
                "pdfunite": ["PDF merge"],
                "pdfseparate": ["PDF split"],
                
                // Video tools
                "ffmpeg": ["video conversion", "compression", "trim", "merge", "extract audio"],
                "ffprobe": ["video metadata", "duration", "codec info"],
                
                // Archive tools
                "zip": ["compress files", "create archives"],
                "unzip": ["extract archives"],
                "tar": ["create archives", "extract"],
                "7z": ["compress", "extract", "supports multiple formats"],
                
                // Document tools
                "pandoc": ["convert documents", "markdown to PDF", "format conversion"],
                "textutil": ["convert text formats", "RTF to TXT"],
                
                // Network tools
                "curl": ["download files", "HTTP requests", "API calls"],
                "wget": ["download files", "mirror websites"],
                
                // Development tools
                "git": ["version control", "clone", "commit", "push"],
                "node": ["run JavaScript", "npm packages"],
                "python": ["run scripts", "data processing"],
                "ruby": ["run scripts", "automation"],
                
                // System tools
                "brew": ["package management", "install tools", "update software"],
                "mas": ["Mac App Store CLI", "install apps"],
                "defaults": ["system preferences", "plist manipulation"],
                
                // Text processing
                "jq": ["JSON parsing", "data extraction"],
                "yq": ["YAML parsing", "data manipulation"],
                "sed": ["text substitution", "stream editing"],
                "awk": ["text processing", "data extraction"],
                "grep": ["search text", "pattern matching"],
            ]
            
            return mapping[tool] ?? ["general purpose tool"]
        }
        
        static func recommend(for task: String, fileType: String?) -> [String] {
            let taskLower = task.lowercased()
            
            // Image tasks
            if taskLower.contains("image") || taskLower.contains("compress") && fileType == "image" {
                if taskLower.contains("compress") || taskLower.contains("optimize") {
                    return ["imagemagick", "pngquant", "jpegoptim"]
                }
                if taskLower.contains("resize") || taskLower.contains("scale") {
                    return ["imagemagick", "sips"]
                }
                if taskLower.contains("convert") || taskLower.contains("format") {
                    return ["imagemagick", "sips"]
                }
                return ["imagemagick"]
            }
            
            // PDF tasks
            if taskLower.contains("pdf") || fileType == "pdf" {
                if taskLower.contains("compress") || taskLower.contains("reduce size") {
                    return ["gs", "qpdf"]
                }
                if taskLower.contains("merge") || taskLower.contains("combine") {
                    return ["pdftk", "pdfunite"]
                }
                if taskLower.contains("split") || taskLower.contains("extract") {
                    return ["pdftk", "pdfseparate"]
                }
                return ["pdftk", "gs"]
            }
            
            // Video tasks
            if taskLower.contains("video") || fileType == "video" {
                return ["ffmpeg"]
            }
            
            // Archive tasks
            if taskLower.contains("zip") || taskLower.contains("compress") || taskLower.contains("archive") {
                return ["zip", "tar", "7z"]
            }
            
            // Document conversion
            if taskLower.contains("convert") && (taskLower.contains("doc") || taskLower.contains("markdown")) {
                return ["pandoc"]
            }
            
            // Download tasks
            if taskLower.contains("download") || taskLower.contains("fetch") {
                return ["curl", "wget"]
            }
            
            return []
        }
    }
    
    // MARK: - Main Execution Flow
    
    func executeTask(query: String, context: FileContext?, aiProvider: AIProviderProtocol) async throws -> TaskExecution {
        isAnalyzing = true
        defer { isAnalyzing = false }
        
        // Step 1: Create task execution
        var task = TaskExecution(query: query, context: context)
        currentTask = task
        
        // Step 2: Analyze query and create todo list
        #if DEBUG
        print("📋 [L2] Analyzing query: \(query)")
        #endif
        let todoList = try await analyzePlan(query: query, context: context, aiProvider: aiProvider)
        task.todoList = todoList
        task.status = .executingSteps
        currentTask = task
        
        #if DEBUG
        print("📋 [L2] Created todo list with \(todoList.count) steps")
        #endif
        
        // Step 3: Execute each step
        for (index, var step) in todoList.enumerated() {
            task.currentStepIndex = index
            currentTask = task
            
            #if DEBUG
            print("🔄 [L2] Step \(index + 1)/\(todoList.count): \(step.description)")
            #endif
            
            // Check if tool is required
            var selectedTool = step.requiredTool
            if selectedTool == nil, let options = step.toolOptions, !options.isEmpty {
                selectedTool = await chooseTool(for: step, options: options)
                if let tool = selectedTool {
                    step = TaskStep(
                        description: "\(step.description) (Using \(tool))",
                        requiredTool: tool,
                        toolOptions: step.toolOptions,
                        command: step.command?.replacingOccurrences(of: "{{tool}}", with: tool).replacingOccurrences(of: "{tool}", with: tool)
                    )
                } else {
                    step.status = .failed
                    step.error = "Tool selection cancelled"
                    task.todoList[index] = step
                    task.status = .failed
                    currentTask = task
                    throw TaskError.toolSelectionCancelled
                }
            }

            if let requiredTool = selectedTool {
                step.status = .checkingTool
                task.todoList[index] = step
                currentTask = task
                
                if !TerminalTool.isInstalled(requiredTool) {
                    // Tool not installed - ask to install
                    #if DEBUG
                    print("📦 [L2] Tool '\(requiredTool)' not installed - suggesting Homebrew installation")
                    #endif
                    step.status = .installingTool
                    task.todoList[index] = step
                    currentTask = task
                    
                    let installed = try await installTool(requiredTool)
                    if !installed {
                        step.status = .failed
                        step.error = "User declined tool installation"
                        task.todoList[index] = step
                        task.status = .failed
                        currentTask = task
                        throw TaskError.toolInstallationDeclined(requiredTool)
                    }
                }
            }
            
            // Execute command
            if let command = step.command {
                step.status = .executing
                task.todoList[index] = step
                currentTask = task
                
                do {
                    let (success, output) = try await executeCommand(command)
                    step.output = output
                    step.status = success ? .completed : .failed
                    if !success {
                        step.error = output
                    }
                    task.todoList[index] = step
                    currentTask = task
                    
                    if !success && !step.description.contains("optional") {
                        throw TaskError.commandFailed(command, output)
                    }
                } catch {
                    step.status = .failed
                    step.error = error.localizedDescription
                    task.todoList[index] = step
                    task.status = .failed
                    currentTask = task
                    throw error
                }
            }
        }
        
        // Step 4: Task completed successfully
        task.status = .completed
        task.result = "Task completed successfully!"
        
        // Step 5: Generate extension suggestion if applicable
        if shouldSuggestExtension(for: task) {
            let suggestion = try await generateExtensionSuggestion(for: task, aiProvider: aiProvider)
            task.suggestedExtension = suggestion
        }
        
        currentTask = task
        return task
    }
    
    // MARK: - Private Methods
    
    private func analyzeQuery(query: String, context: FileContext?, aiProvider: AIProviderProtocol) async throws -> TaskExecution {
        // Use AI to understand query and create plan
        let prompt = buildPlanningPrompt(query: query, context: context)
        let response = try await aiProvider.sendQuery(prompt)
        
        // Parse AI response to extract todo list
        let todoList = parseTodoList(from: response)
        
        return TaskExecution(query: query, context: context, todoList: todoList)
    }
    
    private func analyzePlan(query: String, context: FileContext?, aiProvider: AIProviderProtocol) async throws -> [TaskStep] {
        let prompt = buildPlanningPrompt(query: query, context: context)
        let response = try await aiProvider.sendQuery(prompt)
        return parseTodoList(from: response)
    }
    
    private func buildPlanningPrompt(query: String, context: FileContext?) -> String {
        var prompt = """
        You are a macOS terminal task planner. Analyze this user query and create a detailed todo list.
        
        USER QUERY: \(query)
        
        """
        
        if let context = context {
            prompt += """
            
            SELECTED FILES:
            \(context.description)
            File types: \(context.fileTypes.joined(separator: ", "))
            
            """
        }
        
        // Add installed tools info
        prompt += """
        
        AVAILABLE TOOLS:
        \(getInstalledToolsList())
        
        YOUR TASK:
        1. Break down the query into clear, executable steps
        2. Identify which terminal tools are needed for each step
        3. Suggest tools if they're not installed (available via Homebrew)
        4. Create specific terminal commands for each step
        5. Prefer the best installed tool; if multiple tools fit, pick one and mention it in the step description
        
        RESPONSE FORMAT (JSON):
        {
          "steps": [
            {
              "description": "Clear description of what this step does",
              "requiredTool": "tool_name or null if not needed",
              "toolOptions": ["tool_a", "tool_b"],
              "command": "actual terminal command to execute (use {tool} if toolOptions provided)"
            }
          ]
        }
        
        EXAMPLE for "compress this image":
        {
          "steps": [
            {
              "description": "Check if ImageMagick is installed",
              "requiredTool": "imagemagick",
              "toolOptions": null,
              "command": null
            },
            {
              "description": "Compress image using ImageMagick",
              "requiredTool": "imagemagick",
              "toolOptions": null,
              "command": "convert INPUT_FILE -quality 85 -strip OUTPUT_FILE"
            }
          ]
        }
        
        Now analyze the user query and respond with JSON only.
        """
        
        return prompt
    }
    
    private func getInstalledToolsList() -> String {
        return TerminalToolDiscovery.installedToolsSummary()
    }
    
    private func parseTodoList(from response: String) -> [TaskStep] {
        // Try to extract JSON from response
        guard let jsonData = extractJSON(from: response)?.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(TodoListResponse.self, from: jsonData) else {
            // Fallback: create simple step
            return [TaskStep(description: "Execute task", requiredTool: nil, toolOptions: nil, command: nil)]
        }
        
        return parsed.steps.map { stepData in
            TaskStep(
                description: stepData.description,
                requiredTool: stepData.requiredTool,
                toolOptions: stepData.toolOptions,
                command: stepData.command
            )
        }
    }
    
    private func extractJSON(from text: String) -> String? {
        // Look for JSON block
        if let startIndex = text.range(of: "{")?.lowerBound,
           let endIndex = text.range(of: "}", options: .backwards)?.upperBound {
            return String(text[startIndex..<endIndex])
        }
        return nil
    }

    private func chooseTool(for step: TaskStep, options: [String]) async -> String? {
        let uniqueOptions = Array(NSOrderedSet(array: options)).compactMap { $0 as? String }
        guard !uniqueOptions.isEmpty else { return nil }
        if uniqueOptions.count == 1 {
            return uniqueOptions[0]
        }

        return await withCheckedContinuation { continuation in
            pendingToolChoice = PendingToolChoice(
                stepDescription: step.description,
                tools: uniqueOptions,
                continuation: continuation
            )
        }
    }

    func approveToolChoice(_ tool: String) {
        guard let pending = pendingToolChoice else { return }
        pending.continuation.resume(returning: tool)
        pendingToolChoice = nil
    }

    func denyToolChoice() {
        guard let pending = pendingToolChoice else { return }
        pending.continuation.resume(returning: nil)
        pendingToolChoice = nil
    }
    
    private func installTool(_ toolName: String) async throws -> Bool {
        // Ask user approval via TerminalAIBridge
        let command = "brew install \(toolName)"
        let purpose = "Install \(toolName) to complete your task"
        
        let (success, _, _) = await TerminalCommandExecutor.shared.run(command, purpose: purpose)
        
        if success {
            // Detect and cache the tool
            if let tool = TerminalTool.detect(toolName) {
                installedTools.append(tool)
            }
        }
        
        return success
    }
    
    private func executeCommand(_ command: String) async throws -> (success: Bool, output: String) {
        let result = await TerminalCommandExecutor.shared.run(command, purpose: "Execute task step")
        return (result.success, result.output)
    }
    
    private func shouldSuggestExtension(for task: TaskExecution) -> Bool {
        // Suggest extension if:
        // 1. Task completed successfully
        // 2. Task operates on files (context exists)
        // 3. Task has reusable steps
        return task.status == .completed &&
               task.context != nil &&
               task.todoList.count >= 2
    }
    
    private func generateExtensionSuggestion(for task: TaskExecution, aiProvider: AIProviderProtocol) async throws -> ExtensionSuggestion {
        let stepsDescription = task.todoList.enumerated().map { index, step in
            "\(index + 1). \(step.description) - \(step.command ?? "N/A")"
        }.joined(separator: "\n")
        
        let prompt = """
        Create a reusable extension script for this completed task:
        
        QUERY: \(task.query)
        FILE TYPES: \(task.context?.fileTypes.joined(separator: ", ") ?? "any")
        
        STEPS EXECUTED:
        \(stepsDescription)
        
        Generate a bash script that can be reused for similar files. Use $1, $2, etc. for file arguments.
        Respond with JSON:
        {
          "name": "Extension Name",
          "description": "What it does",
          "script": "#!/bin/bash\\nactual script here",
          "triggers": ["pdf", "jpg"] // File extensions
        }
        """
        
        let response = try await aiProvider.sendQuery(prompt)
        
        // Parse response
        guard let jsonData = extractJSON(from: response)?.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ExtensionResponse.self, from: jsonData) else {
            throw TaskError.extensionGenerationFailed
        }
        
        return ExtensionSuggestion(
            name: parsed.name,
            description: parsed.description,
            script: parsed.script,
            triggers: parsed.triggers,
            reason: "Based on your recent task: \(task.query)"
        )
    }
    
    // MARK: - Helper Types
    
    struct TodoListResponse: Codable {
        let steps: [StepData]
        
        struct StepData: Codable {
            let description: String
            let requiredTool: String?
            let toolOptions: [String]?
            let command: String?
        }
    }
    
    struct ExtensionResponse: Codable {
        let name: String
        let description: String
        let script: String
        let triggers: [String]
    }
    
    enum TaskError: LocalizedError {
        case toolInstallationDeclined(String)
        case toolSelectionCancelled
        case commandFailed(String, String)
        case extensionGenerationFailed
        
        var errorDescription: String? {
            switch self {
            case .toolInstallationDeclined(let tool):
                return "Installation of '\(tool)' was declined"
            case .toolSelectionCancelled:
                return "Tool selection was cancelled"
            case .commandFailed(let command, let output):
                return "Command failed: \(command)\nOutput: \(output)"
            case .extensionGenerationFailed:
                return "Failed to generate extension suggestion"
            }
        }
    }
}

// MARK: - AI Provider Protocol

protocol AIProviderProtocol {
    func sendQuery(_ query: String) async throws -> String
    func sendQuery(_ query: String, context: UserContext, conversationHistory: [ChatMessage]) async throws -> String
}

// Default implementation for backward compatibility
extension AIProviderProtocol {
    func sendQuery(_ query: String) async throws -> String {
        try await sendQuery(query, context: .none, conversationHistory: [])
    }
}

// MARK: - Extension for Settings AI Provider

extension AppSettings {
    func createAIProvider() -> AIProviderProtocol {
        return SettingsAIProvider(settings: self)
    }
}

struct SettingsAIProvider: AIProviderProtocol {
    let settings: AppSettings

    func sendQuery(_ query: String) async throws -> String {
        try await sendQuery(query, context: .none, conversationHistory: [])
    }

    func sendQuery(_ query: String, context: UserContext, conversationHistory: [ChatMessage]) async throws -> String {
        // Use the real AI provider from settings
        let provider = settings.selectedAIProvider
        let apiKey = settings.getAPIKey(for: provider)

        // Use AIProviderService to send the query with full context
        let response = try await AIProviderService.shared.sendMessage(
            query,
            context: context,
            provider: provider,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            conversationHistory: conversationHistory
        )

        return response
    }
}
