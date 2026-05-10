//
//  L2WorkflowEngine.swift
//  ILauncher
//
//  Smart workflow engine for complex multi-step operations
//  Combines data from Calendar, Contacts, Files, Photos, and Terminal
//

import Foundation
import SwiftUI
import Combine

// MARK: - Workflow Definition

struct L2Workflow: Identifiable, Codable {
    let id: UUID
    let name: String
    let description: String
    let trigger: WorkflowTrigger
    let steps: [WorkflowStep]
    var isEnabled: Bool

    init(name: String, description: String, trigger: WorkflowTrigger, steps: [WorkflowStep], isEnabled: Bool = true) {
        self.id = UUID()
        self.name = name
        self.description = description
        self.trigger = trigger
        self.steps = steps
        self.isEnabled = isEnabled
    }

    enum WorkflowTrigger: Codable, Equatable {
        case manual
        case fileType(extensions: [String])
        case timeOfDay(hour: Int, minute: Int)
        case keyword(words: [String])
        case contextChange(contextType: String)
    }

    struct WorkflowStep: Identifiable, Codable {
        let id: UUID
        let name: String
        let action: WorkflowAction
        let condition: StepCondition?
        var inputMapping: [String: String] // Map variables from previous steps

        init(name: String, action: WorkflowAction, condition: StepCondition? = nil, inputMapping: [String: String] = [:]) {
            self.id = UUID()
            self.name = name
            self.action = action
            self.condition = condition
            self.inputMapping = inputMapping
        }

        enum StepCondition: Codable, Equatable {
            case always
            case ifPreviousSuccess
            case ifFileExists(path: String)
            case ifContactFound
            case ifEventExists
        }
    }

    enum WorkflowAction: Codable {
        // Data retrieval
        case getCalendarEvents(days: Int)
        case getReminders(includeDone: Bool)
        case searchContacts(query: String)
        case getSelectedFiles
        case searchPhotos(query: String)

        // Data processing
        case filterByDate(dateRange: String)
        case filterByKeyword(keyword: String)
        case sortResults(by: String)
        case limitResults(count: Int)

        // Terminal operations
        case runCommand(command: String)
        case installTool(name: String)
        case compressFiles(quality: Int)
        case convertFormat(format: String)
        case resizeImages(width: Int, height: Int)

        // Calendar operations
        case createEvent(titleTemplate: String)
        case findRelatedEvents(keyword: String)

        // Contact operations
        case getContactEmail(nameVariable: String)
        case getContactPhone(nameVariable: String)

        // Output operations
        case showNotification(title: String, message: String)
        case openInApp(appName: String)
        case copyToClipboard
        case saveToFile(path: String)
        case sendEmail(toVariable: String, subjectTemplate: String, bodyTemplate: String)

        // AI operations
        case askAI(prompt: String)
        case summarize
        case generateReport
    }
}

// MARK: - Workflow Execution Context

class WorkflowExecutionContext {
    var variables: [String: Any] = [:]
    var stepResults: [UUID: WorkflowStepResult] = [:]
    var currentStepIndex: Int = 0
    var isRunning: Bool = false
    var errors: [String] = []

    struct WorkflowStepResult {
        let stepId: UUID
        let success: Bool
        let output: Any?
        let error: String?
        let duration: TimeInterval
    }

    func setVariable(_ name: String, value: Any) {
        variables[name] = value
    }

    func getVariable(_ name: String) -> Any? {
        return variables[name]
    }

    func resolveTemplate(_ template: String) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: String(describing: value))
        }
        return result
    }
}

// MARK: - Workflow Engine

@MainActor
class L2WorkflowEngine: ObservableObject {
    static let shared = L2WorkflowEngine()

    // Dependencies
    private let assistant = L2UnifiedAssistant.shared
    private let appleAppsAPI = AppleAppsAPI.shared
    private let terminalBridge = TerminalAIBridge.shared
    private let settings = AppSettings.shared

    // State
    @Published var workflows: [L2Workflow] = []
    @Published var isExecuting: Bool = false
    @Published var currentWorkflow: L2Workflow?
    @Published var executionProgress: Double = 0
    @Published var executionLog: [String] = []

    private var savedWorkflowsKey = "l2_saved_workflows"

    private init() {
        loadWorkflows()
        registerBuiltInWorkflows()
    }

    // MARK: - Built-in Workflows

    private func registerBuiltInWorkflows() {
        // Only add if no workflows exist
        guard workflows.isEmpty else { return }

        // 1. Daily Briefing Workflow
        let dailyBriefing = L2Workflow(
            name: "Daily Briefing",
            description: "Get a summary of today's events, reminders, and suggested actions",
            trigger: .manual,
            steps: [
                L2Workflow.WorkflowStep(
                    name: "Get Today's Events",
                    action: .getCalendarEvents(days: 1)
                ),
                L2Workflow.WorkflowStep(
                    name: "Get Pending Reminders",
                    action: .getReminders(includeDone: false)
                ),
                L2Workflow.WorkflowStep(
                    name: "Generate Summary",
                    action: .generateReport
                )
            ]
        )

        // 2. Meeting Prep Workflow
        let meetingPrep = L2Workflow(
            name: "Meeting Preparation",
            description: "Prepare for your next meeting with related documents and contact info",
            trigger: .keyword(words: ["prepare", "meeting", "prep"]),
            steps: [
                L2Workflow.WorkflowStep(
                    name: "Get Next Meeting",
                    action: .getCalendarEvents(days: 1)
                ),
                L2Workflow.WorkflowStep(
                    name: "Find Attendee Contacts",
                    action: .searchContacts(query: "{{attendees}}")
                ),
                L2Workflow.WorkflowStep(
                    name: "Find Related Files",
                    action: .runCommand(command: "mdfind 'kMDItemTextContent == \"{{meetingTitle}}\"' | head -10")
                ),
                L2Workflow.WorkflowStep(
                    name: "Generate Prep Notes",
                    action: .askAI(prompt: "Prepare a brief for the meeting '{{meetingTitle}}' with {{attendeeNames}}")
                )
            ]
        )

        // 3. Image Batch Processing
        let imageProcessing = L2Workflow(
            name: "Batch Image Compression",
            description: "Compress all selected images to reduce file size",
            trigger: .fileType(extensions: ["jpg", "jpeg", "png", "heic"]),
            steps: [
                L2Workflow.WorkflowStep(
                    name: "Get Selected Files",
                    action: .getSelectedFiles
                ),
                L2Workflow.WorkflowStep(
                    name: "Compress Images",
                    action: .compressFiles(quality: 85)
                ),
                L2Workflow.WorkflowStep(
                    name: "Show Notification",
                    action: .showNotification(title: "Images Compressed", message: "{{fileCount}} images processed")
                )
            ]
        )

        // 4. PDF Optimization
        let pdfOptimization = L2Workflow(
            name: "PDF Optimization",
            description: "Reduce PDF file size while maintaining quality",
            trigger: .fileType(extensions: ["pdf"]),
            steps: [
                L2Workflow.WorkflowStep(
                    name: "Get Selected PDFs",
                    action: .getSelectedFiles
                ),
                L2Workflow.WorkflowStep(
                    name: "Compress PDFs",
                    action: .runCommand(command: "gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/ebook -dNOPAUSE -dQUIET -dBATCH -sOutputFile=\"{{outputPath}}\" \"{{inputPath}}\"")
                ),
                L2Workflow.WorkflowStep(
                    name: "Show Result",
                    action: .showNotification(title: "PDF Optimized", message: "Reduced from {{originalSize}} to {{newSize}}")
                )
            ]
        )

        // 5. Downloads Cleanup
        let downloadsCleanup = L2Workflow(
            name: "Organize Downloads",
            description: "Sort Downloads folder by file type into subfolders",
            trigger: .manual,
            steps: [
                L2Workflow.WorkflowStep(
                    name: "Create Folders",
                    action: .runCommand(command: "mkdir -p ~/Downloads/{Images,Documents,Videos,Archives,Other}")
                ),
                L2Workflow.WorkflowStep(
                    name: "Move Images",
                    action: .runCommand(command: "find ~/Downloads -maxdepth 1 -type f \\( -name '*.jpg' -o -name '*.png' -o -name '*.gif' -o -name '*.heic' \\) -exec mv {} ~/Downloads/Images/ \\;")
                ),
                L2Workflow.WorkflowStep(
                    name: "Move Documents",
                    action: .runCommand(command: "find ~/Downloads -maxdepth 1 -type f \\( -name '*.pdf' -o -name '*.doc*' -o -name '*.txt' -o -name '*.md' \\) -exec mv {} ~/Downloads/Documents/ \\;")
                ),
                L2Workflow.WorkflowStep(
                    name: "Move Videos",
                    action: .runCommand(command: "find ~/Downloads -maxdepth 1 -type f \\( -name '*.mp4' -o -name '*.mov' -o -name '*.avi' -o -name '*.mkv' \\) -exec mv {} ~/Downloads/Videos/ \\;")
                ),
                L2Workflow.WorkflowStep(
                    name: "Move Archives",
                    action: .runCommand(command: "find ~/Downloads -maxdepth 1 -type f \\( -name '*.zip' -o -name '*.tar*' -o -name '*.7z' -o -name '*.rar' \\) -exec mv {} ~/Downloads/Archives/ \\;")
                ),
                L2Workflow.WorkflowStep(
                    name: "Done",
                    action: .showNotification(title: "Downloads Organized", message: "Files sorted into subfolders")
                )
            ]
        )

        // 6. Contact Quick Email
        let contactEmail = L2Workflow(
            name: "Quick Email to Contact",
            description: "Find a contact and compose an email",
            trigger: .keyword(words: ["email", "send", "contact"]),
            steps: [
                L2Workflow.WorkflowStep(
                    name: "Find Contact",
                    action: .searchContacts(query: "{{contactName}}")
                ),
                L2Workflow.WorkflowStep(
                    name: "Get Email",
                    action: .getContactEmail(nameVariable: "contactName")
                ),
                L2Workflow.WorkflowStep(
                    name: "Open Email",
                    action: .sendEmail(toVariable: "contactEmail", subjectTemplate: "{{subject}}", bodyTemplate: "")
                )
            ]
        )

        // 7. Screenshot and Share
        let screenshotShare = L2Workflow(
            name: "Screenshot and Share",
            description: "Take a screenshot, optimize it, and copy to clipboard",
            trigger: .manual,
            steps: [
                L2Workflow.WorkflowStep(
                    name: "Take Screenshot",
                    action: .runCommand(command: "screencapture -i /tmp/screenshot_$(date +%s).png")
                ),
                L2Workflow.WorkflowStep(
                    name: "Optimize Image",
                    action: .compressFiles(quality: 80)
                ),
                L2Workflow.WorkflowStep(
                    name: "Copy to Clipboard",
                    action: .copyToClipboard
                ),
                L2Workflow.WorkflowStep(
                    name: "Notify",
                    action: .showNotification(title: "Screenshot Ready", message: "Copied to clipboard")
                )
            ]
        )

        // 8. Photo Export Workflow
        let photoExport = L2Workflow(
            name: "Export Recent Photos",
            description: "Export photos from the last week to a folder",
            trigger: .manual,
            steps: [
                L2Workflow.WorkflowStep(
                    name: "Search Recent Photos",
                    action: .searchPhotos(query: "")
                ),
                L2Workflow.WorkflowStep(
                    name: "Filter by Date",
                    action: .filterByDate(dateRange: "last_week")
                ),
                L2Workflow.WorkflowStep(
                    name: "Export",
                    action: .saveToFile(path: "~/Desktop/PhotoExport_{{date}}")
                ),
                L2Workflow.WorkflowStep(
                    name: "Notify",
                    action: .showNotification(title: "Photos Exported", message: "{{photoCount}} photos saved")
                )
            ]
        )

        workflows = [
            dailyBriefing,
            meetingPrep,
            imageProcessing,
            pdfOptimization,
            downloadsCleanup,
            contactEmail,
            screenshotShare,
            photoExport
        ]

        saveWorkflows()
    }

    // MARK: - Workflow Execution

    func executeWorkflow(_ workflow: L2Workflow, initialVariables: [String: Any] = [:]) async -> Bool {
        guard !isExecuting else {
            executionLog.append("Cannot start workflow: another workflow is running")
            return false
        }

        isExecuting = true
        currentWorkflow = workflow
        executionProgress = 0
        executionLog = ["Starting workflow: \(workflow.name)"]

        let context = WorkflowExecutionContext()

        // Set initial variables
        for (key, value) in initialVariables {
            context.setVariable(key, value: value)
        }

        var allSuccess = true

        for (index, step) in workflow.steps.enumerated() {
            context.currentStepIndex = index
            executionProgress = Double(index) / Double(workflow.steps.count)
            executionLog.append("Step \(index + 1)/\(workflow.steps.count): \(step.name)")

            let startTime = Date()
            let result = await executeStep(step, context: context)
            let duration = Date().timeIntervalSince(startTime)

            context.stepResults[step.id] = WorkflowExecutionContext.WorkflowStepResult(
                stepId: step.id,
                success: result.success,
                output: result.output,
                error: result.error,
                duration: duration
            )

            if result.success {
                executionLog.append("  Completed in \(String(format: "%.2f", duration))s")
                if let output = result.output {
                    // Store output as variable for next steps
                    context.setVariable("step_\(index)_output", value: output)
                    context.setVariable("lastOutput", value: output)
                }
            } else {
                executionLog.append("  Failed: \(result.error ?? "Unknown error")")
                context.errors.append("Step \(index + 1) (\(step.name)): \(result.error ?? "Unknown error")")
                allSuccess = false

                // Check if we should continue on error
                if step.condition == nil || step.condition == .ifPreviousSuccess {
                    executionLog.append("  Stopping workflow due to step failure")
                    break
                }
            }
        }

        executionProgress = 1.0
        executionLog.append("Workflow completed: \(allSuccess ? "Success" : "With errors")")

        isExecuting = false
        currentWorkflow = nil

        return allSuccess
    }

    private func executeStep(_ step: L2Workflow.WorkflowStep, context: WorkflowExecutionContext) async -> (success: Bool, output: Any?, error: String?) {
        // Check condition
        if let condition = step.condition {
            switch condition {
            case .ifPreviousSuccess:
                if context.currentStepIndex > 0 {
                    let previousStepId = currentWorkflow?.steps[context.currentStepIndex - 1].id
                    if let prevResult = context.stepResults[previousStepId ?? UUID()], !prevResult.success {
                        return (false, nil, "Skipped: previous step failed")
                    }
                }
            case .ifFileExists(let path):
                let expandedPath = context.resolveTemplate(path)
                if !FileManager.default.fileExists(atPath: NSString(string: expandedPath).expandingTildeInPath) {
                    return (false, nil, "Skipped: file does not exist")
                }
            default:
                break
            }
        }

        // Execute action
        switch step.action {
        case .getCalendarEvents(let days):
            let events = appleAppsAPI.getCalendarEvents(limit: 20)
            context.setVariable("events", value: events)
            context.setVariable("eventCount", value: events.count)
            return (true, events, nil)

        case .getReminders(let includeDone):
            let reminders = appleAppsAPI.getReminders(limit: 20)
            let filtered = includeDone ? reminders : reminders.filter { !($0["isCompleted"] as? Bool ?? false) }
            context.setVariable("reminders", value: filtered)
            context.setVariable("reminderCount", value: filtered.count)
            return (true, filtered, nil)

        case .searchContacts(let query):
            let resolvedQuery = context.resolveTemplate(query)
            let contacts = appleAppsAPI.searchContacts(query: resolvedQuery)
            context.setVariable("contacts", value: contacts)
            context.setVariable("contactCount", value: contacts.count)
            if let first = contacts.first {
                context.setVariable("firstContactName", value: first["fullName"] ?? "")
                context.setVariable("firstContactEmail", value: first["email"] ?? "")
            }
            return (true, contacts, nil)

        case .getSelectedFiles:
            let files = appleAppsAPI.getSelectedFiles()
            context.setVariable("selectedFiles", value: files)
            context.setVariable("fileCount", value: files.count)
            return (true, files, nil)

        case .searchPhotos(let query):
            // Use systemDataManager for photos
            let results = await ILPhotosSearchManager.shared.searchPhotos(query: query, limit: 20)
            context.setVariable("photos", value: results)
            context.setVariable("photoCount", value: results.count)
            return (true, results, nil)

        case .runCommand(let command):
            let resolvedCommand = context.resolveTemplate(command)
            let (success, output) = await terminalBridge.processAICommand(resolvedCommand, purpose: "Workflow step")
            context.setVariable("commandOutput", value: output)
            return (success, output, success ? nil : output)

        case .compressFiles(let quality):
            // Get files from context
            guard let files = context.getVariable("selectedFiles") as? [String], !files.isEmpty else {
                return (false, nil, "No files to compress")
            }

            var processedCount = 0
            for file in files {
                let ext = (file as NSString).pathExtension.lowercased()
                if ["jpg", "jpeg", "png"].contains(ext) {
                    let output = (file as NSString).deletingPathExtension + "_compressed." + ext
                    let command = "sips -s format jpeg -s formatOptions \(quality) '\(file)' --out '\(output)'"
                    let (success, _) = await terminalBridge.processAICommand(command, purpose: "Compress image")
                    if success { processedCount += 1 }
                }
            }
            context.setVariable("processedCount", value: processedCount)
            return (true, processedCount, nil)

        case .showNotification(let title, let message):
            let resolvedTitle = context.resolveTemplate(title)
            let resolvedMessage = context.resolveTemplate(message)

            // Use NSUserNotification or UNUserNotificationCenter
            let notification = NSUserNotification()
            notification.title = resolvedTitle
            notification.informativeText = resolvedMessage
            NSUserNotificationCenter.default.deliver(notification)

            return (true, nil, nil)

        case .copyToClipboard:
            if let output = context.getVariable("lastOutput") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(String(describing: output), forType: .string)
                return (true, nil, nil)
            }
            return (false, nil, "Nothing to copy")

        case .askAI(let prompt):
            let resolvedPrompt = context.resolveTemplate(prompt)
            let aiProvider = settings.createAIProvider()
            do {
                let response = try await aiProvider.sendQuery(resolvedPrompt)
                context.setVariable("aiResponse", value: response)
                return (true, response, nil)
            } catch {
                return (false, nil, error.localizedDescription)
            }

        case .generateReport:
            // Combine all context variables into a report
            var report = "# Workflow Report\n\n"
            report += "Generated: \(Date())\n\n"

            if let events = context.getVariable("events") as? [[String: Any]] {
                report += "## Events (\(events.count))\n"
                for event in events.prefix(5) {
                    report += "- \(event["title"] ?? "Untitled")\n"
                }
            }

            if let reminders = context.getVariable("reminders") as? [[String: Any]] {
                report += "\n## Reminders (\(reminders.count))\n"
                for reminder in reminders.prefix(5) {
                    report += "- \(reminder["title"] ?? "Untitled")\n"
                }
            }

            context.setVariable("report", value: report)
            return (true, report, nil)

        case .getContactEmail(let nameVariable):
            if let name = context.getVariable(nameVariable) as? String {
                let contacts = appleAppsAPI.searchContacts(query: name)
                if let contact = contacts.first, let email = contact["email"] as? String {
                    context.setVariable("contactEmail", value: email)
                    return (true, email, nil)
                }
            }
            return (false, nil, "Contact email not found")

        case .sendEmail(let toVariable, let subjectTemplate, let bodyTemplate):
            if let email = context.getVariable(toVariable) as? String {
                let subject = context.resolveTemplate(subjectTemplate).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let body = context.resolveTemplate(bodyTemplate).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: "mailto:\(email)?subject=\(subject)&body=\(body)") {
                    NSWorkspace.shared.open(url)
                    return (true, nil, nil)
                }
            }
            return (false, nil, "Could not open email")

        case .openInApp(let appName):
            let appPath = "/Applications/\(appName).app"
            if FileManager.default.fileExists(atPath: appPath) {
                NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
                return (true, nil, nil)
            }
            return (false, nil, "App not found: \(appName)")

        default:
            return (false, nil, "Action not implemented: \(step.action)")
        }
    }

    // MARK: - Workflow Management

    func addWorkflow(_ workflow: L2Workflow) {
        workflows.append(workflow)
        saveWorkflows()
    }

    func removeWorkflow(_ workflow: L2Workflow) {
        workflows.removeAll { $0.id == workflow.id }
        saveWorkflows()
    }

    func updateWorkflow(_ workflow: L2Workflow) {
        if let index = workflows.firstIndex(where: { $0.id == workflow.id }) {
            workflows[index] = workflow
            saveWorkflows()
        }
    }

    private func loadWorkflows() {
        if let data = UserDefaults.standard.data(forKey: savedWorkflowsKey),
           let decoded = try? JSONDecoder().decode([L2Workflow].self, from: data) {
            workflows = decoded
        }
    }

    private func saveWorkflows() {
        if let data = try? JSONEncoder().encode(workflows) {
            UserDefaults.standard.set(data, forKey: savedWorkflowsKey)
        }
    }

    // MARK: - Workflow Discovery

    /// Find workflows that match the current context or query
    func findMatchingWorkflows(query: String? = nil, context: UserContext? = nil) -> [L2Workflow] {
        var matches: [L2Workflow] = []

        for workflow in workflows where workflow.isEnabled {
            switch workflow.trigger {
            case .manual:
                // Always available
                if query == nil && context == nil {
                    matches.append(workflow)
                }

            case .keyword(let words):
                if let q = query?.lowercased() {
                    if words.contains(where: { q.contains($0.lowercased()) }) {
                        matches.append(workflow)
                    }
                }

            case .fileType(let extensions):
                if case .filesSelected(let urls) = context {
                    let fileExts = Set(urls.map { $0.pathExtension.lowercased() })
                    if !fileExts.isDisjoint(with: Set(extensions.map { $0.lowercased() })) {
                        matches.append(workflow)
                    }
                }

            case .contextChange(let contextType):
                if let ctx = context {
                    switch (contextType, ctx) {
                    case ("files", .filesSelected): matches.append(workflow)
                    case ("url", .url): matches.append(workflow)
                    case ("app", .appFocused): matches.append(workflow)
                    default: break
                    }
                }

            default:
                break
            }
        }

        return matches
    }
}

// MARK: - Workflow Builder DSL

extension L2Workflow {
    static func build(_ name: String, description: String = "", trigger: WorkflowTrigger = .manual, @WorkflowStepBuilder steps: () -> [WorkflowStep]) -> L2Workflow {
        return L2Workflow(name: name, description: description, trigger: trigger, steps: steps())
    }
}

@resultBuilder
struct WorkflowStepBuilder {
    static func buildBlock(_ steps: L2Workflow.WorkflowStep...) -> [L2Workflow.WorkflowStep] {
        return steps
    }
}

// MARK: - Step Builder Helpers

extension L2Workflow.WorkflowStep {
    static func getEvents(days: Int = 1, name: String = "Get Events") -> L2Workflow.WorkflowStep {
        return L2Workflow.WorkflowStep(name: name, action: .getCalendarEvents(days: days))
    }

    static func getReminders(includeDone: Bool = false, name: String = "Get Reminders") -> L2Workflow.WorkflowStep {
        return L2Workflow.WorkflowStep(name: name, action: .getReminders(includeDone: includeDone))
    }

    static func searchContacts(_ query: String, name: String = "Search Contacts") -> L2Workflow.WorkflowStep {
        return L2Workflow.WorkflowStep(name: name, action: .searchContacts(query: query))
    }

    static func runCommand(_ command: String, name: String = "Run Command") -> L2Workflow.WorkflowStep {
        return L2Workflow.WorkflowStep(name: name, action: .runCommand(command: command))
    }

    static func notify(_ title: String, message: String) -> L2Workflow.WorkflowStep {
        return L2Workflow.WorkflowStep(name: "Notify", action: .showNotification(title: title, message: message))
    }

    static func askAI(_ prompt: String, name: String = "Ask AI") -> L2Workflow.WorkflowStep {
        return L2Workflow.WorkflowStep(name: name, action: .askAI(prompt: prompt))
    }
}
