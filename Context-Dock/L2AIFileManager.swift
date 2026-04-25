import Foundation
import SwiftUI
import Combine

// MARK: - L2 AI File Manager
// Intelligent file management system similar to VS Code AI features:
// 1. Analyzes files and suggests improvements
// 2. Creates new files with AI generation
// 3. Edits existing files with diff preview
// 4. Refactors code across multiple files
// 5. Learns patterns and creates templates

@MainActor
class L2AIFileManager: ObservableObject {
    static let shared = L2AIFileManager()
    
    // MARK: - Published State
    
    @Published var isAnalyzing = false
    @Published var currentOperation: FileOperation?
    @Published var pendingChanges: [FileChange] = []
    @Published var learningPatterns: [LearningPattern] = []
    @Published var recentOperations: [CompletedOperation] = []
    
    // MARK: - Types
    
    struct FileOperation: Identifiable {
        let id = UUID()
        let type: OperationType
        let files: [URL]
        let userQuery: String
        var status: OperationStatus = .planning
        var proposedChanges: [FileChange] = []
        var aiReasoning: String?
        var error: String?
        
        enum OperationType {
            case create(template: String?)
            case edit(changes: [FileDiff])
            case delete(safe: Bool)
            case refactor(scope: RefactorScope)
            case analyze
            case optimize
        }
        
        enum OperationStatus {
            case planning
            case awaitingApproval
            case executing
            case completed
            case failed
            case cancelled
        }
        
        enum RefactorScope {
            case file
            case folder
            case project
        }
    }
    
    struct FileChange: Identifiable, Codable {
        let id: UUID
        let fileURL: URL
        let changeType: ChangeType
        var originalContent: String?
        var newContent: String?
        var diff: FileDiff?
        let reasoning: String
        var approved: Bool = false
        
        enum ChangeType: String, Codable {
            case create = "Create"
            case modify = "Modify"
            case delete = "Delete"
            case rename = "Rename"
        }
        
        var displayTitle: String {
            "\(changeType.rawValue): \(fileURL.lastPathComponent)"
        }
        
        var canPreview: Bool {
            changeType == .modify || changeType == .create
        }
        
        init(id: UUID = UUID(), fileURL: URL, changeType: ChangeType, originalContent: String? = nil, newContent: String? = nil, diff: FileDiff? = nil, reasoning: String, approved: Bool = false) {
            self.id = id
            self.fileURL = fileURL
            self.changeType = changeType
            self.originalContent = originalContent
            self.newContent = newContent
            self.diff = diff
            self.reasoning = reasoning
            self.approved = approved
        }
    }
    
    struct FileDiff: Codable {
        let hunks: [DiffHunk]
        
        struct DiffHunk: Codable {
            let originalRange: LineRange
            let newRange: LineRange
            let lines: [DiffLine]
            
            struct LineRange: Codable {
                let start: Int
                let count: Int
            }
        }
        
        struct DiffLine: Codable {
            let content: String
            let type: LineType
            
            enum LineType: String, Codable {
                case context = " "
                case addition = "+"
                case deletion = "-"
            }
        }
        
        var addedLines: Int {
            hunks.flatMap { $0.lines }.filter { $0.type == .addition }.count
        }
        
        var deletedLines: Int {
            hunks.flatMap { $0.lines }.filter { $0.type == .deletion }.count
        }
        
        var summary: String {
            "+\(addedLines) -\(deletedLines)"
        }
    }
    
    struct LearningPattern: Identifiable, Codable {
        let id: UUID
        let name: String
        let description: String
        let triggerContext: TriggerContext
        let template: String
        let usage: Int
        let lastUsed: Date
        let successRate: Double
        
        struct TriggerContext: Codable {
            let fileType: String?
            let keywords: [String]
            let projectType: String?
        }
        
        init(id: UUID = UUID(), name: String, description: String, triggerContext: TriggerContext, template: String, usage: Int = 0, lastUsed: Date = Date(), successRate: Double = 1.0) {
            self.id = id
            self.name = name
            self.description = description
            self.triggerContext = triggerContext
            self.template = template
            self.usage = usage
            self.lastUsed = lastUsed
            self.successRate = successRate
        }
    }
    
    struct CompletedOperation: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let operationType: String
        let filesAffected: Int
        let userQuery: String
        let success: Bool
        let duration: TimeInterval
        
        init(id: UUID = UUID(), timestamp: Date = Date(), operationType: String, filesAffected: Int, userQuery: String, success: Bool, duration: TimeInterval) {
            self.id = id
            self.timestamp = timestamp
            self.operationType = operationType
            self.filesAffected = filesAffected
            self.userQuery = userQuery
            self.success = success
            self.duration = duration
        }
    }
    
    // MARK: - Main Interface
    
    /// Process a file-related query from the user
    func processQuery(_ query: String, files: [URL], aiProvider: AIProviderProtocol) async throws {
        isAnalyzing = true
        defer { isAnalyzing = false }
        
        let startTime = Date()
        
        // Analyze user intent
        let intent = try await analyzeIntent(query: query, files: files, aiProvider: aiProvider)
        
        // Create operation
        let operation = FileOperation(
            type: intent.operationType,
            files: files,
            userQuery: query,
            status: .planning
        )
        currentOperation = operation
        
        // Generate proposed changes
        let changes = try await generateChanges(for: operation, aiProvider: aiProvider)
        
        var updatedOperation = operation
        updatedOperation.proposedChanges = changes
        updatedOperation.status = .awaitingApproval
        currentOperation = updatedOperation
        pendingChanges = changes
        
        // Wait for user approval (handled by UI)
        // Execution will happen when user calls approveChanges()
    }
    
    /// Approve and execute pending changes
    func approveChanges() async throws {
        guard var operation = currentOperation else { return }
        
        let startTime = Date()
        operation.status = .executing
        currentOperation = operation
        
        do {
            // Execute each approved change
            for change in pendingChanges where change.approved {
                try await executeChange(change)
            }
            
            operation.status = .completed
            currentOperation = operation
            
            // Record successful operation
            let completed = CompletedOperation(
                operationType: describeOperationType(operation.type),
                filesAffected: pendingChanges.filter(\.approved).count,
                userQuery: operation.userQuery,
                success: true,
                duration: Date().timeIntervalSince(startTime)
            )
            recentOperations.append(completed)
            
            // Learn from this operation
            try await learnFromOperation(operation)
            
            // Clear pending
            pendingChanges.removeAll()
            currentOperation = nil
            
        } catch {
            operation.status = .failed
            operation.error = error.localizedDescription
            currentOperation = operation
            throw error
        }
    }
    
    /// Cancel pending changes
    func cancelChanges() {
        guard var operation = currentOperation else { return }
        operation.status = .cancelled
        currentOperation = nil
        pendingChanges.removeAll()
    }
    
    // MARK: - Intent Analysis
    
    private struct UserIntent {
        let operationType: FileOperation.OperationType
        let reasoning: String
        let confidence: Double
    }
    
    private func analyzeIntent(query: String, files: [URL], aiProvider: AIProviderProtocol) async throws -> UserIntent {
        let prompt = buildIntentPrompt(query: query, files: files)
        let response = try await aiProvider.sendQuery(prompt)
        
        // Parse AI response
        guard let jsonData = extractJSON(from: response)?.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(IntentResponse.self, from: jsonData) else {
            throw L2Error.intentAnalysisFailed
        }
        
        // Map to operation type
        let operationType: FileOperation.OperationType
        switch parsed.intent {
        case "create":
            operationType = .create(template: parsed.template)
        case "edit":
            operationType = .edit(changes: [])
        case "delete":
            operationType = .delete(safe: true)
        case "refactor":
            let scope: FileOperation.RefactorScope = files.count == 1 ? .file : .folder
            operationType = .refactor(scope: scope)
        case "analyze":
            operationType = .analyze
        case "optimize":
            operationType = .optimize
        default:
            operationType = .analyze
        }
        
        return UserIntent(
            operationType: operationType,
            reasoning: parsed.reasoning,
            confidence: parsed.confidence
        )
    }
    
    private func buildIntentPrompt(query: String, files: [URL]) -> String {
        let fileList = files.map { "- \($0.lastPathComponent) (\($0.pathExtension))" }.joined(separator: "\n")
        
        return """
        Analyze this user query about files and determine the intent.
        
        USER QUERY: \(query)
        
        SELECTED FILES:
        \(fileList)
        
        Determine the user's intent from these options:
        - "create": User wants to create new files
        - "edit": User wants to modify existing files
        - "delete": User wants to remove files
        - "refactor": User wants to restructure/improve code
        - "analyze": User wants analysis/suggestions without changes
        - "optimize": User wants to improve performance/quality
        
        Respond with JSON:
        {
          "intent": "create|edit|delete|refactor|analyze|optimize",
          "reasoning": "Why you chose this intent",
          "confidence": 0.95,
          "template": "optional template name if creating files"
        }
        """
    }
    
    // MARK: - Change Generation
    
    private func generateChanges(for operation: FileOperation, aiProvider: AIProviderProtocol) async throws -> [FileChange] {
        switch operation.type {
        case .create(let template):
            return try await generateCreationChanges(for: operation, template: template, aiProvider: aiProvider)
        case .edit:
            return try await generateEditChanges(for: operation, aiProvider: aiProvider)
        case .delete(let safe):
            return try await generateDeletionChanges(for: operation, safe: safe)
        case .refactor:
            return try await generateRefactorChanges(for: operation, aiProvider: aiProvider)
        case .analyze:
            return try await generateAnalysisResults(for: operation, aiProvider: aiProvider)
        case .optimize:
            return try await generateOptimizations(for: operation, aiProvider: aiProvider)
        }
    }
    
    private func generateCreationChanges(for operation: FileOperation, template: String?, aiProvider: AIProviderProtocol) async throws -> [FileChange] {
        let prompt = buildCreationPrompt(query: operation.userQuery, template: template, context: operation.files)
        let response = try await aiProvider.sendQuery(prompt)
        
        guard let jsonData = extractJSON(from: response)?.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(CreationResponse.self, from: jsonData) else {
            throw L2Error.changeGenerationFailed
        }
        
        return parsed.files.map { fileData in
            let fileURL = operation.files.first?.deletingLastPathComponent().appendingPathComponent(fileData.filename) ??
                         URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path)
                            .appendingPathComponent(fileData.filename)
            
            return FileChange(
                fileURL: fileURL,
                changeType: .create,
                newContent: fileData.content,
                reasoning: fileData.reasoning
            )
        }
    }
    
    private func generateEditChanges(for operation: FileOperation, aiProvider: AIProviderProtocol) async throws -> [FileChange] {
        var changes: [FileChange] = []
        
        for fileURL in operation.files {
            let originalContent = try String(contentsOf: fileURL, encoding: .utf8)
            let prompt = buildEditPrompt(query: operation.userQuery, file: fileURL, content: originalContent)
            let response = try await aiProvider.sendQuery(prompt)
            
            guard let jsonData = extractJSON(from: response)?.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(EditResponse.self, from: jsonData) else {
                continue
            }
            
            // Generate diff
            let diff = generateDiff(original: originalContent, new: parsed.newContent)
            
            changes.append(FileChange(
                fileURL: fileURL,
                changeType: .modify,
                originalContent: originalContent,
                newContent: parsed.newContent,
                diff: diff,
                reasoning: parsed.reasoning
            ))
        }
        
        return changes
    }
    
    private func generateDeletionChanges(for operation: FileOperation, safe: Bool) async throws -> [FileChange] {
        return operation.files.map { fileURL in
            FileChange(
                fileURL: fileURL,
                changeType: .delete,
                reasoning: safe ? "Safe deletion (will be moved to Trash)" : "Permanent deletion"
            )
        }
    }
    
    private func generateRefactorChanges(for operation: FileOperation, aiProvider: AIProviderProtocol) async throws -> [FileChange] {
        // Similar to edit but with refactoring focus
        return try await generateEditChanges(for: operation, aiProvider: aiProvider)
    }
    
    private func generateAnalysisResults(for operation: FileOperation, aiProvider: AIProviderProtocol) async throws -> [FileChange] {
        // Analysis doesn't create actual changes, just suggestions
        return []
    }
    
    private func generateOptimizations(for operation: FileOperation, aiProvider: AIProviderProtocol) async throws -> [FileChange] {
        // Similar to refactor but optimization-focused
        return try await generateEditChanges(for: operation, aiProvider: aiProvider)
    }
    
    // MARK: - Prompt Building
    
    private func buildCreationPrompt(query: String, template: String?, context: [URL]) -> String {
        """
        Create new files based on this user request.
        
        USER REQUEST: \(query)
        TEMPLATE: \(template ?? "none")
        CONTEXT DIRECTORY: \(context.first?.deletingLastPathComponent().path ?? "current directory")
        
        Generate the file(s) with appropriate content.
        
        Respond with JSON:
        {
          "files": [
            {
              "filename": "MyFile.swift",
              "content": "// File content here\\n...",
              "reasoning": "Why this file is needed"
            }
          ]
        }
        """
    }
    
    private func buildEditPrompt(query: String, file: URL, content: String) -> String {
        """
        Modify this file based on the user's request.
        
        USER REQUEST: \(query)
        FILE: \(file.lastPathComponent)
        
        CURRENT CONTENT:
        ```
        \(content.prefix(2000))\(content.count > 2000 ? "\n... (truncated)" : "")
        ```
        
        Provide the complete new file content after modifications.
        
        Respond with JSON:
        {
          "newContent": "Complete new file content here",
          "reasoning": "What changes were made and why",
          "summary": "Brief summary of changes"
        }
        """
    }
    
    // MARK: - Diff Generation
    
    private func generateDiff(original: String, new: String) -> FileDiff {
        let originalLines = original.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        
        // Simple line-by-line diff
        var hunks: [FileDiff.DiffHunk] = []
        var currentHunk: [FileDiff.DiffLine] = []
        var originalIndex = 0
        var newIndex = 0
        var hunkStartOriginal = 0
        var hunkStartNew = 0
        
        while originalIndex < originalLines.count || newIndex < newLines.count {
            if originalIndex < originalLines.count && newIndex < newLines.count &&
               originalLines[originalIndex] == newLines[newIndex] {
                // Context line
                if !currentHunk.isEmpty {
                    currentHunk.append(FileDiff.DiffLine(content: originalLines[originalIndex], type: .context))
                }
                originalIndex += 1
                newIndex += 1
            } else if originalIndex < originalLines.count && (newIndex >= newLines.count || originalLines[originalIndex] != newLines[newIndex]) {
                // Deletion
                if currentHunk.isEmpty {
                    hunkStartOriginal = originalIndex
                    hunkStartNew = newIndex
                }
                currentHunk.append(FileDiff.DiffLine(content: originalLines[originalIndex], type: .deletion))
                originalIndex += 1
            } else if newIndex < newLines.count {
                // Addition
                if currentHunk.isEmpty {
                    hunkStartOriginal = originalIndex
                    hunkStartNew = newIndex
                }
                currentHunk.append(FileDiff.DiffLine(content: newLines[newIndex], type: .addition))
                newIndex += 1
            }
            
            // Create hunk if we have enough context
            if currentHunk.count > 0 && (originalIndex >= originalLines.count || newIndex >= newLines.count ||
                                          (originalIndex < originalLines.count && newIndex < newLines.count &&
                                           originalLines[originalIndex] == newLines[newIndex])) {
                let hunk = FileDiff.DiffHunk(
                    originalRange: FileDiff.DiffHunk.LineRange(start: hunkStartOriginal, count: currentHunk.filter { $0.type != .addition }.count),
                    newRange: FileDiff.DiffHunk.LineRange(start: hunkStartNew, count: currentHunk.filter { $0.type != .deletion }.count),
                    lines: currentHunk
                )
                hunks.append(hunk)
                currentHunk.removeAll()
            }
        }
        
        return FileDiff(hunks: hunks)
    }
    
    // MARK: - Change Execution
    
    private func executeChange(_ change: FileChange) async throws {
        switch change.changeType {
        case .create:
            guard let content = change.newContent else {
                throw L2Error.missingContent
            }
            try content.write(to: change.fileURL, atomically: true, encoding: .utf8)
            
        case .modify:
            guard let content = change.newContent else {
                throw L2Error.missingContent
            }
            // Create backup
            let backupURL = change.fileURL.appendingPathExtension("backup")
            if FileManager.default.fileExists(atPath: change.fileURL.path) {
                try FileManager.default.copyItem(at: change.fileURL, to: backupURL)
            }
            try content.write(to: change.fileURL, atomically: true, encoding: .utf8)
            
        case .delete:
            try FileManager.default.trashItem(at: change.fileURL, resultingItemURL: nil)
            
        case .rename:
            // Not yet implemented
            break
        }
    }
    
    // MARK: - Learning System
    
    private func learnFromOperation(_ operation: FileOperation) async throws {
        // Analyze the operation and create a learning pattern if it's reusable
        if shouldCreatePattern(from: operation) {
            let pattern = createLearningPattern(from: operation)
            learningPatterns.append(pattern)
            saveLearningPatterns()
        }
    }
    
    private func shouldCreatePattern(from operation: FileOperation) -> Bool {
        // Create patterns for successful file creations and refactors
        guard operation.status == .completed else { return false }
        
        switch operation.type {
        case .create, .refactor:
            return true
        default:
            return false
        }
    }
    
    private func createLearningPattern(from operation: FileOperation) -> LearningPattern {
        let fileTypes = Set(operation.files.map { $0.pathExtension })
        let keywords = extractKeywords(from: operation.userQuery)
        
        let triggerContext = LearningPattern.TriggerContext(
            fileType: fileTypes.first,
            keywords: keywords,
            projectType: detectProjectType(from: operation.files)
        )
        
        // Extract template from first created file
        let template = operation.proposedChanges.first(where: { $0.changeType == .create })?.newContent ?? ""
        
        return LearningPattern(
            name: "Pattern from: \(operation.userQuery.prefix(50))",
            description: operation.aiReasoning ?? "Learned pattern",
            triggerContext: triggerContext,
            template: template
        )
    }
    
    private func extractKeywords(from query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 }
            .prefix(5)
            .map { String($0) }
    }
    
    private func detectProjectType(from files: [URL]) -> String? {
        let directory = files.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: ".")
        let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        
        if contents?.contains(where: { $0.lastPathComponent == "Package.swift" }) == true {
            return "SwiftPackage"
        }
        if contents?.contains(where: { $0.pathExtension == "xcodeproj" }) == true {
            return "Xcode"
        }
        if contents?.contains(where: { $0.lastPathComponent == "package.json" }) == true {
            return "Node"
        }
        
        return nil
    }
    
    // MARK: - Persistence
    
    private func saveLearningPatterns() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(learningPatterns) {
            UserDefaults.standard.set(data, forKey: "l2_learning_patterns")
        }
    }
    
    private func loadLearningPatterns() {
        if let data = UserDefaults.standard.data(forKey: "l2_learning_patterns"),
           let patterns = try? JSONDecoder().decode([LearningPattern].self, from: data) {
            learningPatterns = patterns
        }
    }
    
    // MARK: - Helpers
    
    private func extractJSON(from text: String) -> String? {
        if let startIndex = text.range(of: "{")?.lowerBound,
           let endIndex = text.range(of: "}", options: .backwards)?.upperBound {
            return String(text[startIndex..<endIndex])
        }
        return nil
    }
    
    private func describeOperationType(_ type: FileOperation.OperationType) -> String {
        switch type {
        case .create: return "Create"
        case .edit: return "Edit"
        case .delete: return "Delete"
        case .refactor: return "Refactor"
        case .analyze: return "Analyze"
        case .optimize: return "Optimize"
        }
    }
    
    // MARK: - Response Types
    
    struct IntentResponse: Codable {
        let intent: String
        let reasoning: String
        let confidence: Double
        let template: String?
    }
    
    struct CreationResponse: Codable {
        let files: [FileData]
        
        struct FileData: Codable {
            let filename: String
            let content: String
            let reasoning: String
        }
    }
    
    struct EditResponse: Codable {
        let newContent: String
        let reasoning: String
        let summary: String
    }
    
    // MARK: - Errors
    
    enum L2Error: LocalizedError {
        case intentAnalysisFailed
        case changeGenerationFailed
        case missingContent
        case executionFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .intentAnalysisFailed:
                return "Failed to analyze user intent"
            case .changeGenerationFailed:
                return "Failed to generate file changes"
            case .missingContent:
                return "Missing file content for operation"
            case .executionFailed(let reason):
                return "Execution failed: \(reason)"
            }
        }
    }
    
    // MARK: - Initialization
    
    init() {
        loadLearningPatterns()
    }
}
