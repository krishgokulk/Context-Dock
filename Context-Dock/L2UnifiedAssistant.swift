//
//  L2UnifiedAssistant.swift
//  ILauncher
//
//  The brain of L2 - connects Context, Terminal, AI, Files, Photos, Contacts, Calendar, and Reminders
//  Enables natural language workflows across all data sources
//

import Foundation
import SwiftUI
import Combine
import AppKit
import EventKit
import Contacts
import Photos

// MARK: - L2 Intent Types

enum L2Intent: Equatable {
    // Calendar & Scheduling
    case showTodaySchedule
    case showUpcomingEvents(days: Int)
    case createEvent(title: String, date: Date?, duration: TimeInterval?)
    case findEventsWithContact(contactName: String)
    case prepareForMeeting(eventTitle: String?)

    // Reminders & Tasks
    case showReminders
    case showOverdueReminders
    case createReminder(title: String, dueDate: Date?)
    case completeReminder(title: String)

    // Contacts
    case findContact(name: String)
    case getContactInfo(name: String)
    case emailContact(name: String, subject: String?)
    case callContact(name: String)

    // Files & Folders
    case processFiles(operation: FileOperation, files: [URL])
    case organizeFolder(path: String)
    case findFiles(query: String, type: String?)
    case analyzeFile(url: URL)

    // Photos
    case findPhotos(query: String, dateRange: DateInterval?)
    case processPhotos(operation: PhotoOperation, count: Int?)
    case exportPhotos(destination: String)

    // Media Control (browser / music apps)
    case mediaControl(action: MediaAction)

    // Adapter-backed app actions
    case appAction(query: String)

    // Cross-app content transfer actions
    case crossAppAction(query: String)

    // Semantic fallback wants user disambiguation
    case semanticDisambiguation(options: [String], originalQuery: String)

    enum MediaAction: String, Equatable {
        case pause, play, next, previous, mute, volumeUp, volumeDown
    }

    // Terminal & Automation
    case runCommand(command: String)
    case installTool(name: String)
    case executeWorkflow(steps: [String])
    case checkIfInstalled(toolName: String)
    case intelligentTerminalQuery(query: String)  // AI figures out the command

    // Cross-Data Queries
    case dailyBriefing
    case searchEverything(query: String)
    case contextualAction // Act based on current context
    case smartSuggestion

    // General
    case askQuestion(question: String)
    case unknown(query: String)

    enum FileOperation: Equatable {
        case compress
        case resize(width: Int?, height: Int?)
        case convert(format: String)
        case rename(pattern: String)
        case move(destination: String)
        case backup
        case delete
        case analyze
    }

    enum PhotoOperation: Equatable {
        case compress
        case resize(width: Int, height: Int)
        case convert(format: String)
        case watermark(text: String)
        case createAlbum(name: String)
    }
}

// MARK: - L2 Response

struct L2Response {
    let message: String
    let data: [String: Any]?
    let actions: [L2Action]
    let suggestedFollowUps: [String]

    struct L2Action {
        let title: String
        let icon: String
        let action: () async -> Void
    }
}

// MARK: - L2 Unified Assistant

@MainActor
class L2UnifiedAssistant: ObservableObject {
    static let shared = L2UnifiedAssistant()

    // MARK: - Dependencies

    private let calendarManager = ILCalendarRemindersSearchManager.shared
    private let photosManager = ILPhotosSearchManager.shared
    private let contactsManager = ILContactsSearchManager.shared
    private let systemDataManager = SystemDataSearchManager.shared
    private let fileManager = L2AIFileManager.shared
    private let taskExecutor = L2AITaskExecutor.shared
    private let terminalBridge = TerminalAIBridge.shared
    private let contextDetector = ContextDetector.shared
    private let appleAppsAPI = AppleAppsAPI.shared
    private let settings = AppSettings.shared
    private let packageManager = TerminalPackageManager.shared
    private let adapterManager = AppAdapterManager.shared
    private let crossAppHandler = CrossAppNLHandler.shared
    private let semanticResolver = L2SemanticResolver.shared

    // MARK: - State

    @Published var isProcessing = false
    @Published var lastResponse: L2Response?
    @Published var currentContext: UserContext = .none
    @Published var conversationHistory: [L2Message] = []

    struct L2Message: Identifiable {
        let id = UUID()
        let role: Role
        let content: String
        let timestamp: Date
        let intent: L2Intent?

        enum Role {
            case user
            case assistant
        }
    }

    private init() {}

    // MARK: - App-Tool Context Snippet for L2 Prompts

    /// Builds a compact, scored tool-context block for the given app key and query.
    /// Injected into L2 terminal prompts so the AI knows which user-configured tools are available.
    func appToolContextSnippet(appKey: String?, query: String) -> String {
        guard let key = appKey, !key.isEmpty else { return "" }
        let relevantTools = settings.topExtensions(for: key, query: query, maxCount: 4)
        guard !relevantTools.isEmpty else { return "" }
        let pkgs = packageManager.packages
        let lines = relevantTools.map { ext -> String in
            var line: String
            if ext.kind == .script, let lang = ext.scriptLanguage, !ext.toolPath.isEmpty {
                // Script: tell AI exactly how to invoke it
                let runCmd = lang.runCommand(scriptPath: ext.toolPath)
                line = "- \(ext.toolName): run via `\(runCmd) \"<full user query as single arg>\"`"
            } else {
                let pkg = pkgs.first(where: { $0.command == ext.toolName })
                line = "- \(ext.toolName)"
                if let path = pkg?.installedPath ?? (ext.toolPath.isEmpty ? nil : ext.toolPath) {
                    line += " (\(path))"
                }
                if let ht = pkg?.helpText, !ht.isEmpty {
                    line += ": " + String(ht.prefix(200))
                }
            }
            let hint = ext.effectiveHint
            if !hint.isEmpty {
                line += " — " + String(hint.prefix(250))
            }
            return line
        }.joined(separator: "\n")
        return "\nAPP CONTEXT [\(key)] — USER-CONFIGURED TOOLS:\n\(lines)\nPrefer these tools over generic CLI alternatives. Use run_command.\n"
    }

    // MARK: - Main Entry Point

    /// Process a natural language query and return a response
    func process(_ query: String, context: UserContext? = nil) async -> L2Response {
        isProcessing = true
        defer { isProcessing = false }

        // Update context
        if let ctx = context {
            currentContext = ctx
        } else {
            currentContext = await detectCurrentContext()
        }

        // Add to history
        conversationHistory.append(L2Message(
            role: .user,
            content: query,
            timestamp: Date(),
            intent: nil
        ))

        // Parse intent
        var intent = parseIntent(from: query)
        if case .askQuestion = intent {
            let axContext = AXContextReader.shared.current
            let decision = await semanticResolver.resolve(query: query, context: currentContext, axContext: axContext)
            intent = remapSemanticDecision(decision, originalQuery: query, axContext: axContext) ?? intent
        }

        // Execute intent
        let response = await executeIntent(intent, originalQuery: query)

        // Add response to history
        conversationHistory.append(L2Message(
            role: .assistant,
            content: response.message,
            timestamp: Date(),
            intent: intent
        ))

        lastResponse = response
        return response
    }

    // MARK: - Context Detection

    private func detectCurrentContext() async -> UserContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        return UserContextDetector.shared.detectCurrentContext(from: frontmostApp)
    }

    // MARK: - Intent Parsing

    func parseIntent(from query: String) -> L2Intent {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Daily Briefing
        if q.contains("daily briefing") || q.contains("what's on today") ||
           q.contains("my day") || q.contains("today's schedule") ||
           q.contains("what do i have today") {
            return .dailyBriefing
        }

        if crossAppHandler.parse(query) != nil {
            return .crossAppAction(query: query)
        }

        if L2AppActionRouter.shared.resolve(query: query) != nil {
            return .appAction(query: query)
        }

        // Calendar queries
        if q.contains("today") && (q.contains("meeting") || q.contains("event") || q.contains("schedule") || q.contains("calendar")) {
            return .showTodaySchedule
        }

        if q.contains("upcoming") || q.contains("next week") || q.contains("this week") {
            let days = q.contains("week") ? 7 : 3
            return .showUpcomingEvents(days: days)
        }

        if q.contains("schedule") && q.contains("meeting") || q.contains("create event") || q.contains("add to calendar") {
            // Extract title from query
            let title = extractQuotedText(from: query) ?? "New Meeting"
            return .createEvent(title: title, date: nil, duration: 3600)
        }

        if q.contains("prepare for") && (q.contains("meeting") || q.contains("call")) {
            let meetingTitle = extractQuotedText(from: query)
            return .prepareForMeeting(eventTitle: meetingTitle)
        }

        // Reminders
        if q.contains("reminder") || q.contains("todo") || q.contains("task") {
            if q.contains("overdue") || q.contains("missed") {
                return .showOverdueReminders
            }
            if q.contains("create") || q.contains("add") || q.contains("remind me") {
                let title = extractQuotedText(from: query) ?? "New Reminder"
                return .createReminder(title: title, dueDate: nil)
            }
            return .showReminders
        }

        // Contacts
        if q.contains("contact") || q.contains("find") && (q.contains("email") || q.contains("phone") || q.contains("number")) {
            if let name = extractName(from: query) {
                if q.contains("email") && q.contains("send") {
                    return .emailContact(name: name, subject: extractQuotedText(from: query))
                }
                if q.contains("call") {
                    return .callContact(name: name)
                }
                return .findContact(name: name)
            }
        }

        // File operations
        if q.contains("compress") || q.contains("resize") || q.contains("convert") {
            if q.contains("image") || q.contains("photo") || q.contains("jpg") || q.contains("png") {
                if q.contains("compress") {
                    return .processFiles(operation: .compress, files: [])
                }
                if q.contains("resize") {
                    return .processFiles(operation: .resize(width: nil, height: nil), files: [])
                }
                if q.contains("convert") {
                    let format = extractFormat(from: query) ?? "png"
                    return .processFiles(operation: .convert(format: format), files: [])
                }
            }
            if q.contains("pdf") {
                return .processFiles(operation: .compress, files: [])
            }
        }

        if q.contains("backup") {
            return .processFiles(operation: .backup, files: [])
        }

        if q.contains("organize") && (q.contains("folder") || q.contains("files") || q.contains("downloads")) {
            return .organizeFolder(path: "~/Downloads")
        }

        // Photos
        if q.contains("photo") || q.contains("picture") || q.contains("image") {
            if q.contains("find") || q.contains("search") || q.contains("show") {
                let searchQuery = extractQuotedText(from: query) ?? ""
                return .findPhotos(query: searchQuery, dateRange: nil)
            }
            if q.contains("yesterday") || q.contains("last week") || q.contains("recent") {
                return .findPhotos(query: "", dateRange: nil)
            }
        }

        // Media control - detect before terminal keywords to avoid AI roundtrip
        let mediaActionMap: [(keywords: [String], action: L2Intent.MediaAction)] = [
            (["pause", "stop music", "stop playing"], .pause),
            (["play", "resume", "unpause"], .play),
            (["next", "skip", "next song", "next track"], .next),
            (["previous", "prev", "back", "last song", "last track"], .previous),
            (["mute", "silence"], .mute),
            (["volume up", "louder", "increase volume"], .volumeUp),
            (["volume down", "quieter", "lower volume", "decrease volume"], .volumeDown),
        ]
        // Only trigger if query is short/focused (media commands tend to be short)
        if q.count < 80 {
            for (keywords, action) in mediaActionMap {
                if keywords.contains(where: { q.contains($0) }) {
                    return .mediaControl(action: action)
                }
            }
        }

        // Terminal commands - explicit
        if q.starts(with: "run ") || q.starts(with: "execute ") {
            let command = query.replacingOccurrences(of: "run ", with: "")
                               .replacingOccurrences(of: "execute ", with: "")
            return .runCommand(command: command)
        }

        // Check if tool/app is installed
        if let toolName = extractToolNameForCheck(from: q) {
            return .checkIfInstalled(toolName: toolName)
        }

        // Install tool
        if q.contains("install") {
            if let toolName = extractToolName(from: query) {
                return .installTool(name: toolName)
            }
        }

        // Intelligent terminal queries - AI determines the command
        // Patterns: system info, network, processes, files, packages, services
        let terminalKeywords = [
            // System info
            "show", "display", "get", "check", "what is", "tell me",
            // Network
            "wifi", "network", "ip", "internet", "connection", "dns",
            // Packages
            "delete", "remove", "uninstall", "list all", "show all",
            "update", "upgrade", "install", "packages", "brew", "npm", "pip",
            // Services & processes
            "start", "stop", "restart", "status of", "running", "processes",
            // File system
            "disk", "storage", "memory", "cpu", "battery",
            // File operations — must go through tool-use so AI can run commands and see output
            "move", "copy", "rename", "mkdir", "make folder", "create folder",
            "sort files", "sort by", "organize", "clean up", "clean downloads",
            "find files", "delete files", "remove files", "empty folder",
            "move all", "move files", "zip all", "compress all",
            // Tools
            "ollama", "docker", "git", "node", "python"
        ]
        if terminalKeywords.contains(where: { q.contains($0) }) {
            return .intelligentTerminalQuery(query: query)
        }

        // Search everything
        if q.contains("search") || q.contains("find") {
            let searchQuery = extractQuotedText(from: query) ?? query.replacingOccurrences(of: "search", with: "")
                .replacingOccurrences(of: "find", with: "").trimmingCharacters(in: .whitespaces)
            return .searchEverything(query: searchQuery)
        }

        // Context-aware action
        if q.contains("help") && q.contains("this") || q.contains("what can i do") || q.contains("suggest") {
            return .smartSuggestion
        }

        // Default: ask AI
        return .askQuestion(question: query)
    }

    // MARK: - Intent Execution

    private func executeIntent(_ intent: L2Intent, originalQuery: String) async -> L2Response {
        switch intent {
        case .dailyBriefing:
            return await executeDailyBriefing()

        case .showTodaySchedule:
            return await executeShowTodaySchedule()

        case .showUpcomingEvents(let days):
            return await executeShowUpcomingEvents(days: days)

        case .createEvent(let title, let date, let duration):
            return await executeCreateEvent(title: title, date: date, duration: duration)

        case .prepareForMeeting(let eventTitle):
            return await executePrepareForMeeting(eventTitle: eventTitle)

        case .showReminders:
            return await executeShowReminders()

        case .showOverdueReminders:
            return await executeShowOverdueReminders()

        case .createReminder(let title, let dueDate):
            return await executeCreateReminder(title: title, dueDate: dueDate)

        case .findContact(let name):
            return await executeFindContact(name: name)

        case .getContactInfo(let name):
            return await executeGetContactInfo(name: name)

        case .emailContact(let name, let subject):
            return await executeEmailContact(name: name, subject: subject)

        case .processFiles(let operation, let files):
            return await executeProcessFiles(operation: operation, files: files)

        case .organizeFolder(let path):
            return await executeOrganizeFolder(path: path)

        case .findPhotos(let query, let dateRange):
            return await executeFindPhotos(query: query, dateRange: dateRange)

        case .runCommand(let command):
            return await executeRunCommand(command: command)

        case .installTool(let name):
            return await executeInstallTool(name: name)

        case .checkIfInstalled(let toolName):
            return await executeCheckIfInstalled(toolName: toolName)

        case .intelligentTerminalQuery(let query):
            return await executeIntelligentTerminalQuery(query: query)

        case .searchEverything(let query):
            return await executeSearchEverything(query: query)

        case .smartSuggestion:
            return await executeSmartSuggestion()

        case .askQuestion(let question):
            return await executeAskQuestion(question: question)

        case .mediaControl(let action):
            return await executeMediaControl(action: action)

        case .crossAppAction(let query):
            return await executeCrossAppAction(query: query)

        case .appAction(let query):
            return await executeAppAction(query: query)

        case .semanticDisambiguation(let options, let originalQuery):
            return executeSemanticDisambiguation(options: options, originalQuery: originalQuery)

        default:
            return await executeAskQuestion(question: originalQuery)
        }
    }

    // MARK: - Intent Implementations

    private func executeDailyBriefing() async -> L2Response {
        var briefing = "## Daily Briefing\n\n"
        var data: [String: Any] = [:]

        // Get today's events
        let todayEvents = appleAppsAPI.getTodayEvents()
        briefing += "### Calendar (\(todayEvents.count) events today)\n"
        for event in todayEvents.prefix(5) {
            let title = event["title"] as? String ?? "Untitled"
            let startDate = event["startDate"] as? String ?? ""
            let isAllDay = event["isAllDay"] as? Bool ?? false
            if isAllDay {
                briefing += "- **\(title)** (All Day)\n"
            } else {
                briefing += "- **\(title)** at \(formatTime(startDate))\n"
            }
        }
        data["events"] = todayEvents

        // Get reminders
        let reminders = appleAppsAPI.getReminders(limit: 5)
        let overdueReminders = appleAppsAPI.getOverdueReminders()
        briefing += "\n### Reminders\n"
        if !overdueReminders.isEmpty {
            briefing += "**\(overdueReminders.count) overdue!**\n"
        }
        for reminder in reminders.prefix(5) {
            let title = reminder["title"] as? String ?? "Untitled"
            let isCompleted = reminder["isCompleted"] as? Bool ?? false
            let marker = isCompleted ? "[x]" : "[ ]"
            briefing += "- \(marker) \(title)\n"
        }
        data["reminders"] = reminders
        data["overdueReminders"] = overdueReminders

        // Context-aware suggestions
        briefing += "\n### Suggested Actions\n"
        if let nextEvent = todayEvents.first {
            let title = nextEvent["title"] as? String ?? "meeting"
            briefing += "- Prepare for \"\(title)\"\n"
        }
        if !overdueReminders.isEmpty {
            briefing += "- Review overdue reminders\n"
        }
        briefing += "- Check recent files\n"

        return L2Response(
            message: briefing,
            data: data,
            actions: [
                L2Response.L2Action(title: "Show All Events", icon: "calendar") {
                    // Action implementation
                },
                L2Response.L2Action(title: "Show Reminders", icon: "checklist") {
                    // Action implementation
                }
            ],
            suggestedFollowUps: [
                "What's my next meeting?",
                "Show overdue reminders",
                "Prepare for my next meeting"
            ]
        )
    }

    private func executeAppAction(query: String) async -> L2Response {
        guard let resolution = L2AppActionRouter.shared.resolve(query: query) else {
            return await executeAskQuestion(question: query)
        }

        let match = resolution.primary
        let context = AXContextReader.shared.current
        let result = await adapterManager.execute(
            match.action,
            context: context,
            targetBundleId: match.adapter.bundleId
        )
        let followUps = resolution.alternatives.map { "\($0.adapter.appName) \($0.action.name)" }

        let message: String
        if result.0 {
            message = "Executed \(match.adapter.appName) → \(match.action.name).\n\(result.1)"
        } else {
            message = "Couldn’t run \(match.adapter.appName) → \(match.action.name).\n\(result.1)"
        }

        return L2Response(
            message: message,
            data: [
                "bundleId": match.adapter.bundleId,
                "appName": match.adapter.appName,
                "actionId": match.action.id,
                "actionName": match.action.name,
                "matchedAppPhrase": match.matchedAppPhrase,
                "matchedActionPhrase": match.matchedActionPhrase,
                "success": result.0
            ],
            actions: [],
            suggestedFollowUps: followUps
        )
    }

    private func executeCrossAppAction(query: String) async -> L2Response {
        guard let intent = crossAppHandler.parse(query) else {
            return await executeAskQuestion(question: query)
        }

        guard let resolved = await crossAppHandler.resolve(intent) else {
            return L2Response(
                message: "Couldn’t resolve that cross-app action.",
                data: nil,
                actions: [],
                suggestedFollowUps: []
            )
        }

        let context = AXContextReader.shared.current
        let output = await crossAppHandler.execute(resolved, axContext: context)

        var data: [String: Any] = [
            "confirmationMessage": resolved.confirmationMessage,
            "output": output
        ]
        if let recipient = resolved.intent.recipientName {
            data["recipientName"] = recipient
        }
        if let appName = resolved.intent.targetAppName {
            data["targetAppName"] = appName
        }
        if let currentURL = context.currentURL {
            data["currentURL"] = currentURL
        }
        if let selectedText = context.selectedText, !selectedText.isEmpty {
            data["selectedTextPreview"] = String(selectedText.prefix(200))
        }
        if !context.selectedFilePaths.isEmpty {
            data["selectedFiles"] = context.selectedFilePaths
        }

        let followUps = suggestedFollowUps(for: resolved, context: context)

        return L2Response(
            message: output,
            data: data,
            actions: [],
            suggestedFollowUps: followUps
        )
    }

    private func remapSemanticDecision(_ decision: L2SemanticDecision, originalQuery: String, axContext: AXContext) -> L2Intent? {
        switch decision {
        case .appAction(let appName, let actionPhrase):
            return .appAction(query: "\(appName) \(actionPhrase)")

        case .crossApp(let targetApp, let mode):
            return .crossAppAction(query: canonicalCrossAppQuery(targetApp: targetApp, mode: mode, axContext: axContext))

        case .terminal(let query):
            return .intelligentTerminalQuery(query: query)

        case .askUser(let options):
            return .semanticDisambiguation(options: options, originalQuery: originalQuery)

        case .noMatch:
            return nil
        }
    }

    private func canonicalCrossAppQuery(targetApp: String, mode: String, axContext: AXContext) -> String {
        switch mode.lowercased() {
        case "page":
            return "add this page to \(targetApp)"
        case "link":
            return "save this link to \(targetApp)"
        case "bookmark":
            return "bookmark this in \(targetApp)"
        case "open":
            return "open this in \(targetApp)"
        case "send":
            return "send this to \(targetApp)"
        default:
            if axContext.currentURL != nil {
                return "add this page to \(targetApp)"
            }
            return "add this to \(targetApp)"
        }
    }

    private func executeSemanticDisambiguation(options: [String], originalQuery: String) -> L2Response {
        let lines = options.prefix(4).map { "- \($0)" }.joined(separator: "\n")
        return L2Response(
            message: """
            I found a few likely interpretations for "\(originalQuery)":
            \(lines)
            """,
            data: [
                "options": options,
                "originalQuery": originalQuery
            ],
            actions: [],
            suggestedFollowUps: Array(options.prefix(4))
        )
    }

    private func suggestedFollowUps(for result: CrossAppResult, context: AXContext) -> [String] {
        switch result.intent.action {
        case .sendMessage:
            if let recipient = result.intent.recipientName {
                return ["email this to \(recipient)", "open this in Messages"]
            }
            return ["email this", "share this"]

        case .sendEmail:
            if let recipient = result.intent.recipientName {
                return ["send this to \(recipient) in Messages", "share this with \(recipient)"]
            }
            return ["send this in Messages", "share this"]

        case .shareFile:
            return ["send this to Messages", "email this"]

        case .openInApp:
            if context.currentURL != nil {
                return ["add this page to Notes", "bookmark this in Notion"]
            }
            if context.selectedText != nil {
                return ["add this to Notes", "send this to Messages"]
            }
            return ["share this", "open in another app"]

        case .captureToApp:
            if context.currentURL != nil {
                return ["bookmark this in Notion", "save this page to Bear"]
            }
            if context.selectedText != nil {
                return ["add this to Obsidian", "email this"]
            }
            return ["open this in Safari", "share this"]

        case .searchInApp:
            let app = result.intent.targetAppName ?? "this app"
            return ["find in \(app)", "search in Finder", "search in Safari"]
        }
    }

    private func executeShowTodaySchedule() async -> L2Response {
        let events = appleAppsAPI.getTodayEvents()

        var message = "## Today's Schedule\n\n"
        if events.isEmpty {
            message += "No events scheduled for today."
        } else {
            for event in events {
                let title = event["title"] as? String ?? "Untitled"
                let startDate = event["startDate"] as? String ?? ""
                let isAllDay = event["isAllDay"] as? Bool ?? false

                if isAllDay {
                    message += "- **\(title)** (All Day)\n"
                } else {
                    message += "- **\(title)** at \(formatTime(startDate))\n"
                }
            }
        }

        return L2Response(
            message: message,
            data: ["events": events],
            actions: [],
            suggestedFollowUps: [
                "What's my next meeting?",
                "Schedule a new meeting",
                "Show tomorrow's schedule"
            ]
        )
    }

    private func executeShowUpcomingEvents(days: Int) async -> L2Response {
        let events = appleAppsAPI.getCalendarEvents(limit: 20)

        var message = "## Upcoming Events (Next \(days) days)\n\n"
        if events.isEmpty {
            message += "No upcoming events."
        } else {
            for event in events {
                let title = event["title"] as? String ?? "Untitled"
                let startDate = event["startDate"] as? String ?? ""
                let location = event["location"] as? String ?? ""

                message += "- **\(title)**\n"
                message += "  \(formatDateTime(startDate))"
                if !location.isEmpty {
                    message += " @ \(location)"
                }
                message += "\n"
            }
        }

        return L2Response(
            message: message,
            data: ["events": events],
            actions: [],
            suggestedFollowUps: [
                "Show today's events only",
                "Create a new event",
                "Find meetings with a specific person"
            ]
        )
    }

    private func executeCreateEvent(title: String, date: Date?, duration: TimeInterval?) async -> L2Response {
        let eventDate = date ?? Date().addingTimeInterval(3600) // Default: 1 hour from now
        let eventDuration = duration ?? 3600 // Default: 1 hour

        let success = appleAppsAPI.createEvent(
            title: title,
            startDate: eventDate,
            endDate: eventDate.addingTimeInterval(eventDuration)
        )

        if success {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            return L2Response(
                message: "Created event: **\(title)**\nScheduled for: \(formatter.string(from: eventDate))",
                data: ["title": title, "date": eventDate],
                actions: [],
                suggestedFollowUps: [
                    "Show today's schedule",
                    "Create another event",
                    "Set a reminder"
                ]
            )
        } else {
            return L2Response(
                message: "Failed to create event. Please check calendar permissions.",
                data: nil,
                actions: [],
                suggestedFollowUps: ["Open System Preferences"]
            )
        }
    }

    private func executePrepareForMeeting(eventTitle: String?) async -> L2Response {
        var message = "## Meeting Preparation\n\n"
        var foundEvent: [String: Any]?

        // Find the meeting
        let events = appleAppsAPI.getCalendarEvents(limit: 20)
        if let title = eventTitle {
            foundEvent = events.first { ($0["title"] as? String ?? "").lowercased().contains(title.lowercased()) }
        } else {
            // Get the next meeting
            foundEvent = events.first
        }

        guard let event = foundEvent else {
            return L2Response(
                message: "No upcoming meeting found to prepare for.",
                data: nil,
                actions: [],
                suggestedFollowUps: ["Show my schedule", "Create a meeting"]
            )
        }

        let meetingTitle = event["title"] as? String ?? "Meeting"
        let startDate = event["startDate"] as? String ?? ""
        let notes = event["notes"] as? String ?? ""

        message += "### \(meetingTitle)\n"
        message += "**Time:** \(formatDateTime(startDate))\n\n"

        if !notes.isEmpty {
            message += "### Notes\n\(notes)\n\n"
        }

        // Try to find related contacts
        message += "### Suggested Preparation\n"
        message += "- Review previous meeting notes\n"
        message += "- Check related documents\n"
        message += "- Prepare talking points\n"

        return L2Response(
            message: message,
            data: ["event": event],
            actions: [
                L2Response.L2Action(title: "Find Related Files", icon: "doc.text.magnifyingglass") {
                    // Search for files related to meeting
                },
                L2Response.L2Action(title: "Open Calendar", icon: "calendar") {
                    if let url = URL(string: "calshow://") {
                        NSWorkspace.shared.open(url)
                    }
                }
            ],
            suggestedFollowUps: [
                "Find files about \(meetingTitle)",
                "Who is in this meeting?",
                "Show my notes"
            ]
        )
    }

    private func executeShowReminders() async -> L2Response {
        let reminders = appleAppsAPI.getReminders(limit: 20)

        var message = "## Reminders\n\n"
        if reminders.isEmpty {
            message += "No reminders found."
        } else {
            for reminder in reminders {
                let title = reminder["title"] as? String ?? "Untitled"
                let isCompleted = reminder["isCompleted"] as? Bool ?? false
                let dueDate = reminder["dueDate"] as? String ?? ""

                let marker = isCompleted ? "[x]" : "[ ]"
                message += "- \(marker) **\(title)**"
                if !dueDate.isEmpty {
                    message += " (Due: \(formatDate(dueDate)))"
                }
                message += "\n"
            }
        }

        return L2Response(
            message: message,
            data: ["reminders": reminders],
            actions: [],
            suggestedFollowUps: [
                "Show overdue reminders",
                "Create a reminder",
                "Complete a reminder"
            ]
        )
    }

    private func executeShowOverdueReminders() async -> L2Response {
        let overdueReminders = appleAppsAPI.getOverdueReminders()

        var message = "## Overdue Reminders\n\n"
        if overdueReminders.isEmpty {
            message += "No overdue reminders! You're all caught up."
        } else {
            message += "**\(overdueReminders.count) overdue items:**\n\n"
            for reminder in overdueReminders {
                let title = reminder["title"] as? String ?? "Untitled"
                let dueDate = reminder["dueDate"] as? String ?? ""

                message += "- **\(title)**"
                if !dueDate.isEmpty {
                    message += " (Was due: \(formatDate(dueDate)))"
                }
                message += "\n"
            }
        }

        return L2Response(
            message: message,
            data: ["overdueReminders": overdueReminders],
            actions: [],
            suggestedFollowUps: [
                "Show all reminders",
                "Complete these reminders"
            ]
        )
    }

    private func executeCreateReminder(title: String, dueDate: Date?) async -> L2Response {
        // Note: Creating reminders requires EventKit and proper permissions
        // For now, we'll return a message about the action
        return L2Response(
            message: "To create reminder: **\(title)**\n\nPlease use the Reminders app or Siri for now. Full reminder creation coming soon!",
            data: ["title": title],
            actions: [
                L2Response.L2Action(title: "Open Reminders", icon: "checklist") {
                    if let url = URL(string: "x-apple-reminderkit://") {
                        NSWorkspace.shared.open(url)
                    }
                }
            ],
            suggestedFollowUps: [
                "Show my reminders",
                "What's overdue?"
            ]
        )
    }

    private func executeFindContact(name: String) async -> L2Response {
        let contacts = appleAppsAPI.searchContacts(query: name)

        var message = "## Contact Search: \(name)\n\n"
        if contacts.isEmpty {
            message += "No contacts found matching '\(name)'."
        } else {
            for contact in contacts {
                let fullName = contact["fullName"] as? String ?? "Unknown"
                let email = contact["email"] as? String ?? ""
                let phone = contact["phone"] as? String ?? ""

                message += "### \(fullName)\n"
                if !email.isEmpty {
                    message += "- Email: \(email)\n"
                }
                if !phone.isEmpty {
                    message += "- Phone: \(phone)\n"
                }
                message += "\n"
            }
        }

        return L2Response(
            message: message,
            data: ["contacts": contacts],
            actions: [],
            suggestedFollowUps: [
                "Send email to \(name)",
                "Call \(name)",
                "Find another contact"
            ]
        )
    }

    private func executeGetContactInfo(name: String) async -> L2Response {
        return await executeFindContact(name: name)
    }

    private func executeEmailContact(name: String, subject: String?) async -> L2Response {
        let contacts = appleAppsAPI.searchContacts(query: name)

        guard let contact = contacts.first,
              let email = contact["email"] as? String, !email.isEmpty else {
            return L2Response(
                message: "Could not find email for '\(name)'.",
                data: nil,
                actions: [],
                suggestedFollowUps: ["Find contact \(name)"]
            )
        }

        let subjectParam = subject.map { "&subject=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } ?? ""
        if let url = URL(string: "mailto:\(email)?\(subjectParam)") {
            NSWorkspace.shared.open(url)
        }

        return L2Response(
            message: "Opening email composer for **\(contact["fullName"] as? String ?? name)**...",
            data: ["contact": contact],
            actions: [],
            suggestedFollowUps: [
                "Find another contact",
                "Show my schedule"
            ]
        )
    }

    private func executeProcessFiles(operation: L2Intent.FileOperation, files: [URL]) async -> L2Response {
        // Get files from context if not provided
        var targetFiles = files
        if targetFiles.isEmpty {
            if case .filesSelected(let urls) = currentContext {
                targetFiles = urls
            }
        }

        if targetFiles.isEmpty {
            return L2Response(
                message: "No files selected. Please select files in Finder first, or specify which files to process.",
                data: nil,
                actions: [],
                suggestedFollowUps: [
                    "Select files in Finder",
                    "Find files to process"
                ]
            )
        }

        var commandDescription = ""
        switch operation {
        case .compress:
            commandDescription = "compress"
        case .resize(let width, let height):
            commandDescription = "resize to \(width ?? 0)x\(height ?? 0)"
        case .convert(let format):
            commandDescription = "convert to \(format)"
        case .backup:
            commandDescription = "backup"
        case .analyze:
            commandDescription = "analyze"
        default:
            commandDescription = "process"
        }

        return L2Response(
            message: "Ready to \(commandDescription) \(targetFiles.count) file(s).\n\nUse the L2 Task Executor to proceed with this operation.",
            data: ["files": targetFiles.map { $0.path }, "operation": String(describing: operation)],
            actions: [
                L2Response.L2Action(title: "Execute", icon: "play.fill") {
                    // Trigger task executor
                }
            ],
            suggestedFollowUps: [
                "Show file details first",
                "Choose different files"
            ]
        )
    }

    private func executeOrganizeFolder(path: String) async -> L2Response {
        let expandedPath = NSString(string: path).expandingTildeInPath

        return L2Response(
            message: "To organize **\(path)**:\n\n1. Analyze folder contents\n2. Group by file type\n3. Create date-based subfolders\n4. Move files accordingly\n\nWould you like me to proceed?",
            data: ["path": expandedPath],
            actions: [
                L2Response.L2Action(title: "Analyze Folder", icon: "folder.badge.gearshape") {
                    // Analyze folder
                },
                L2Response.L2Action(title: "Open in Finder", icon: "folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: expandedPath)
                }
            ],
            suggestedFollowUps: [
                "Show folder contents first",
                "Just show me the file types"
            ]
        )
    }

    private func executeFindPhotos(query: String, dateRange: DateInterval?) async -> L2Response {
        let results = await photosManager.searchPhotos(query: query, limit: 20)

        var message = "## Photos"
        if !query.isEmpty {
            message += " matching '\(query)'"
        }
        message += "\n\n"

        if results.isEmpty {
            message += "No photos found."
        } else {
            message += "Found **\(results.count)** photos.\n\n"
            for result in results.prefix(10) {
                message += "- \(result.title) (\(result.subtitle))\n"
            }
            if results.count > 10 {
                message += "\n... and \(results.count - 10) more"
            }
        }

        return L2Response(
            message: message,
            data: ["count": results.count],
            actions: [
                L2Response.L2Action(title: "Open Photos App", icon: "photo") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
                }
            ],
            suggestedFollowUps: [
                "Process these photos",
                "Export photos",
                "Search for different photos"
            ]
        )
    }

    private func executeRunCommand(command: String) async -> L2Response {
        let (success, output) = await terminalBridge.processAICommand(command, purpose: "User requested command")

        if success {
            return L2Response(
                message: "**Command executed:**\n```\n\(command)\n```\n\n**Output:**\n```\n\(output)\n```",
                data: ["command": command, "output": output, "success": true],
                actions: [],
                suggestedFollowUps: [
                    "Run another command",
                    "What else can I do?"
                ]
            )
        } else {
            return L2Response(
                message: "**Command failed:**\n```\n\(command)\n```\n\n**Error:**\n```\n\(output)\n```",
                data: ["command": command, "output": output, "success": false],
                actions: [],
                suggestedFollowUps: [
                    "Try a different command",
                    "What went wrong?"
                ]
            )
        }
    }

    // MARK: - Media Control

    private func executeMediaControl(action: L2Intent.MediaAction) async -> L2Response {
        // Use the context captured before ILauncher became frontmost
        let (frontApp, frontBundleId): (String, String) = {
            if case .appFocused(let name, let bundleID) = currentContext {
                return (name, bundleID)
            }
            let ws = NSWorkspace.shared.frontmostApplication
            return (ws?.localizedName ?? "", ws?.bundleIdentifier ?? "")
        }()

        // Browser apps — inject JS into active tab
        let browserBundleIds = [
            "com.apple.Safari",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser"
        ]
        let isBrowser = browserBundleIds.contains(frontBundleId)

        if isBrowser {
            return await executeBrowserMediaControl(action: action, bundleId: frontBundleId, appName: frontApp)
        }

        // Music apps — AppleScript
        let musicBundleIds: [String: String] = [
            "com.apple.Music":         "Music",
            "com.spotify.client":      "Spotify",
            "com.apple.iTunes":        "iTunes"
        ]
        if let appName = musicBundleIds[frontBundleId] {
            return executeMusicAppControl(action: action, appName: appName)
        }

        // Fallback: try browser first, then system volume
        return await executeBrowserMediaControl(action: action, bundleId: "", appName: frontApp)
    }

    private func executeBrowserMediaControl(action: L2Intent.MediaAction, bundleId: String, appName: String) async -> L2Response {
        let jsMap: [L2Intent.MediaAction: String] = [
            .pause:    "var v=document.querySelector('video,audio');if(v)v.pause();",
            .play:     "var v=document.querySelector('video,audio');if(v)v.play();",
            .next:     "document.querySelector('[aria-label*=\"Next\"],button.ytp-next-button')?.click();",
            .previous: "document.querySelector('[aria-label*=\"Previous\"],button.ytp-prev-button')?.click();",
            .mute:     "var v=document.querySelector('video,audio');if(v)v.muted=!v.muted;",
            .volumeUp: "var v=document.querySelector('video,audio');if(v)v.volume=Math.min(1,v.volume+0.1);",
            .volumeDown:"var v=document.querySelector('video,audio');if(v)v.volume=Math.max(0,v.volume-0.1);"
        ]

        guard let js = jsMap[action] else {
            return L2Response(message: "Unknown media action.", data: nil, actions: [], suggestedFollowUps: [])
        }

        // Use osascript to inject JS into the frontmost browser
        let escapedJs = js.replacingOccurrences(of: "\"", with: "\\\"")
        let appTarget = bundleId == "com.apple.Safari" ? "Safari" :
                        bundleId == "com.google.Chrome" ? "Google Chrome" :
                        bundleId == "org.mozilla.firefox" ? "Firefox" :
                        bundleId == "com.microsoft.edgemac" ? "Microsoft Edge" :
                        bundleId == "com.brave.Browser" ? "Brave Browser" : "Safari"

        let script: String
        if appTarget == "Safari" {
            script = """
            tell application "Safari"
                do JavaScript "\(escapedJs)" in front document
            end tell
            """
        } else {
            // Chrome-family: use execute script in active tab
            script = """
            tell application "\(appTarget)"
                execute front window's active tab javascript "\(escapedJs)"
            end tell
            """
        }

        let result = runAppleScript(script)
        let actionLabel = action.rawValue.capitalized
        if result.success {
            return L2Response(
                message: "✅ \(actionLabel)d",
                data: nil, actions: [], suggestedFollowUps: ["play", "pause", "next", "previous"]
            )
        } else {
            // Fallback: try system media keys via osascript
            return executeSystemMediaKey(action: action)
        }
    }

    private func executeMusicAppControl(action: L2Intent.MediaAction, appName: String) -> L2Response {
        let cmdMap: [L2Intent.MediaAction: String] = [
            .pause:    "pause",
            .play:     "play",
            .next:     "next track",
            .previous: "previous track",
            .mute:     "set muted of sound volume settings to not (muted of sound volume settings)"
        ]
        guard let cmd = cmdMap[action] else {
            return executeSystemMediaKey(action: action)
        }
        let script = "tell application \"\(appName)\" to \(cmd)"
        let result = runAppleScript(script)
        let label = action.rawValue.capitalized
        return L2Response(
            message: result.success ? "✅ \(label)d in \(appName)" : "❌ Could not control \(appName): \(result.output)",
            data: nil, actions: [], suggestedFollowUps: ["play", "pause", "next", "previous"]
        )
    }

    private func executeSystemMediaKey(action: L2Intent.MediaAction) -> L2Response {
        // Use osascript key code for system media keys
        let keyCodeMap: [L2Intent.MediaAction: Int] = [
            .pause: 179,     // Play/Pause key code
            .play:  179,
            .next:  176,     // Next track
            .previous: 177   // Previous track
        ]
        if let keyCode = keyCodeMap[action] {
            let script = "key code \(keyCode) using {}"
            _ = runAppleScript("tell application \"System Events\" to \(script)")
        }
        return L2Response(
            message: "✅ \(action.rawValue.capitalized)d",
            data: nil, actions: [], suggestedFollowUps: ["play", "pause", "next", "previous"]
        )
    }

    /// Run an AppleScript string synchronously, return (success, output)
    @discardableResult
    private func runAppleScript(_ source: String) -> (success: Bool, output: String) {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            let result = script.executeAndReturnError(&error)
            if let err = error {
                return (false, err["NSAppleScriptErrorMessage"] as? String ?? "AppleScript error")
            }
            return (true, result.stringValue ?? "")
        }
        return (false, "Failed to create AppleScript")
    }

    private func executeInstallTool(name: String) async -> L2Response {
        let command = "brew install \(name)"
        let (success, output) = await terminalBridge.processAICommand(command, purpose: "Install \(name) via Homebrew")

        if success {
            return L2Response(
                message: "**\(name)** installed successfully!\n\n```\n\(output.prefix(500))\n```",
                data: ["tool": name, "installed": true],
                actions: [],
                suggestedFollowUps: [
                    "What can I do with \(name)?",
                    "Install another tool"
                ]
            )
        } else {
            return L2Response(
                message: "Failed to install **\(name)**.\n\n```\n\(output)\n```",
                data: ["tool": name, "installed": false],
                actions: [],
                suggestedFollowUps: [
                    "Try installing manually",
                    "Check if Homebrew is installed"
                ]
            )
        }
    }

    /// Check if a tool is installed by running `which <tool>`
    private func executeCheckIfInstalled(toolName: String) async -> L2Response {
        let command = "which \(toolName)"
        let (success, output) = await terminalBridge.processAICommand(command, purpose: "Check if \(toolName) is installed")

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if success && !trimmedOutput.isEmpty && !trimmedOutput.contains("not found") {
            // Tool is installed - get version if possible
            var versionInfo = ""
            let versionCmd = "\(toolName) --version 2>/dev/null || \(toolName) -v 2>/dev/null || echo ''"
            let (_, versionOutput) = await terminalBridge.processAICommand(versionCmd, purpose: "Get \(toolName) version")
            let version = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty {
                versionInfo = "\n**Version:** `\(version.components(separatedBy: "\n").first ?? version)`"
            }

            return L2Response(
                message: "✅ **\(toolName)** is installed!\n\n**Path:** `\(trimmedOutput)`\(versionInfo)",
                data: ["tool": toolName, "installed": true, "path": trimmedOutput],
                actions: [],
                suggestedFollowUps: [
                    "Show \(toolName) help",
                    "Update \(toolName)",
                    "Uninstall \(toolName)"
                ]
            )
        } else {
            return L2Response(
                message: "❌ **\(toolName)** is not installed.\n\nWould you like me to install it?",
                data: ["tool": toolName, "installed": false],
                actions: [],
                suggestedFollowUps: [
                    "Install \(toolName)",
                    "Search for \(toolName) alternatives"
                ]
            )
        }
    }

    /// Intelligent terminal query - AI figures out the command and executes it
    private func executeIntelligentTerminalQuery(query: String) async -> L2Response {
        // First, check if user has configured packages that match this query
        if let package = packageManager.findPackageForQuery(query) {
            // Package found! Try to generate command using the package
            if let command = packageManager.generateCommand(for: query, using: package) {
                let purpose = "Using \(package.name): \(package.description)"
                
                // If command has placeholders like [URL], ask the user or use context
                var finalCommand = command
                
                // Extract URL from context if command needs one
                if command.contains("[URL]") {
                    if case .url(let urlString) = currentContext {
                        finalCommand = command.replacingOccurrences(of: "[URL]", with: urlString)
                    } else {
                        // Ask user for URL
                        return L2Response(
                            message: "To use **\(package.name)**, I need a URL.\n\nSuggested command:\n```bash\n\(command)\n```\n\nPlease provide the URL or paste it in the browser first.",
                            data: ["package": package.name, "command": command],
                            actions: [],
                            suggestedFollowUps: [
                                "Here's the URL: [paste URL]",
                                "Use current tab URL"
                            ]
                        )
                    }
                }
                
                // Replace other common placeholders
                finalCommand = finalCommand.replacingOccurrences(of: "[package]", with: "")
                finalCommand = finalCommand.replacingOccurrences(of: "[message]", with: "")
                
                // Show user what will execute and ask for confirmation
                return L2Response(
                    message: "Using **\(package.name)**\n\n**Command:**\n```bash\n\(finalCommand)\n```\n\n**Purpose:** \(purpose)\n\nExecute this command?",
                    data: [
                        "package": package.name,
                        "command": finalCommand,
                        "needsConfirmation": true
                    ],
                    actions: [
                        L2Response.L2Action(title: "Execute", icon: "play.fill") {
                            let (success, output) = await self.terminalBridge.processAICommand(finalCommand, purpose: purpose)
                            self.packageManager.recordCommand(query: query, command: finalCommand, success: success, forPackageName: package.name)

                            await MainActor.run {
                                if success {
                                    self.lastResponse = L2Response(
                                        message: "✅ **Command executed successfully!**\n\n**Output:**\n```\n\(output.prefix(1000))\n```",
                                        data: ["success": true, "output": output],
                                        actions: [],
                                        suggestedFollowUps: []
                                    )
                                } else {
                                    self.lastResponse = L2Response(
                                        message: "⚠️ **Command completed with issues:**\n\n```\n\(output)\n```",
                                        data: ["success": false, "output": output],
                                        actions: [],
                                        suggestedFollowUps: []
                                    )
                                }
                            }
                        }
                    ],
                    suggestedFollowUps: [
                        "Show me the command help",
                        "Use different options"
                    ]
                )
            }
        }
        
        // No matching package — use tool_use loop for cloud providers, text parsing for OnDevice
        let terminalContext = terminalBridge.getRecentContext(lastN: 5)
        let availablePackages = packageManager.packages
            .filter { $0.isEnabled && $0.isInstalled }
            .map { "\($0.command) - \($0.description)" }
            .joined(separator: "\n")

        let chatHistory = conversationHistory.suffix(10).compactMap { msg -> ChatMessage? in
            let role: ChatMessage.MessageRole = msg.role == .user ? .user : .assistant
            return ChatMessage(role: role, content: msg.content, timestamp: msg.timestamp)
        }

        // Resolve working directory from context: selected file/folder or current Finder window
        let workingDir: String = {
            if case .filesSelected(let urls) = currentContext, let first = urls.first {
                return first.hasDirectoryPath ? first.path : first.deletingLastPathComponent().path
            }
            let finderFolder = appleAppsAPI.getCurrentFolder()
            if !finderFolder.isEmpty { return finderFolder }
            return "~"
        }()

        // Contextual query enriched with terminal state — sent as the user message in the tool loop
        let contextualQuery = """
        \(availablePackages.isEmpty ? "" : "Available terminal packages:\n\(availablePackages)\n\n")\
        \(terminalContext.isEmpty   ? "" : "Recent terminal activity:\n\(terminalContext)\n\n")\
        Working directory (where the user is): \(workingDir)
        User request: "\(query)"
        IMPORTANT: Use the working directory above for all file paths. Prefer `find -maxdepth 1` or glob patterns over `ls | awk` for listing files.
        """

        let provider = settings.selectedAIProvider
        let apiKey: String? = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : nil

        // Closure: routes each AI-requested tool call through TerminalAIBridge
        // (all approval UI, risk classification, and audit logging are preserved)
        let commandExecutor: (String, String) async -> (Bool, String) = { [weak self] command, purpose in
            guard let self else { return (false, "Internal error") }
            return await self.terminalBridge.processAICommand(command, purpose: purpose)
        }

        do {
            // Tool-use multi-turn loop — AI sees command output and can chain follow-ups
            let (finalText, executedCommands) = try await AIProviderService.shared.sendWithTools(
                contextualQuery,
                context: currentContext,
                provider: provider,
                apiKey: apiKey,
                conversationHistory: chatHistory,
                commandExecutor: commandExecutor
            )

            // Feed successful commands into the learning loop
            for executed in executedCommands {
                if let matchedPkg = packageManager.findPackageForQuery(query) {
                    packageManager.recordCommand(
                        query: query,
                        command: executed.command,
                        success: executed.success,
                        forPackageName: matchedPkg.name
                    )
                }
            }

            // Clean chat response: brief status only — full output visible in terminal dropdown
            let allSucceeded = executedCommands.allSatisfy { $0.success }
            let chatMessage: String
            if executedCommands.isEmpty {
                chatMessage = finalText
            } else if allSucceeded {
                let cmdNames = executedCommands.map { "`\($0.command.components(separatedBy: " ").first ?? $0.command)`" }.joined(separator: ", ")
                chatMessage = "✅ Done — ran \(cmdNames)\n\n\(finalText)"
            } else {
                let failed = executedCommands.filter { !$0.success }
                let reason = failed.first?.output.components(separatedBy: "\n").first ?? "error"
                chatMessage = "❌ Failed: \(reason)\n\n\(finalText)"
            }

            return L2Response(
                message: chatMessage,
                data: ["executedCount": executedCommands.count,
                       "allSucceeded": executedCommands.allSatisfy { $0.success }],
                actions: [],
                suggestedFollowUps: []
            )

        } catch AIServiceError.unsupportedProvider(_) {
            // OnDevice / Shortcuts: no tool_use support — fall back to legacy text-parsing
            return await executeIntelligentTerminalQueryLegacy(
                query: query,
                terminalContext: terminalContext,
                availablePackages: availablePackages,
                chatHistory: chatHistory
            )

        } catch {
            return L2Response(
                message: "I couldn't process that request. Error: \(error.localizedDescription)",
                data: nil,
                actions: [],
                suggestedFollowUps: []
            )
        }
    }

    /// Legacy text-parsing path used for OnDevice / Shortcuts providers that don't support tool_use.
    private func executeIntelligentTerminalQueryLegacy(
        query: String,
        terminalContext: String,
        availablePackages: String,
        chatHistory: [ChatMessage]
    ) async -> L2Response {

        let prompt = buildLegacyTerminalPrompt(
            query: query,
            terminalContext: terminalContext,
            availablePackages: availablePackages
        )
        let aiProvider = settings.createAIProvider()

        do {
            let aiResponse = try await aiProvider.sendQuery(prompt, context: currentContext, conversationHistory: chatHistory)

            if let command = extractCommand(from: aiResponse),
               let purpose = extractPurpose(from: aiResponse),
               command != "NONE" {

                let (success, output) = await terminalBridge.processAICommand(command, purpose: purpose)

                if let matchedPkg = packageManager.findPackageForQuery(query) {
                    packageManager.recordCommand(query: query, command: command, success: success, forPackageName: matchedPkg.name)
                }

                return L2Response(
                    message: success
                        ? "✅ Done"
                        : "❌ Failed: \(output.components(separatedBy: "\n").first ?? output)",
                    data: ["command": command, "output": output, "success": success],
                    actions: [],
                    suggestedFollowUps: []
                )
            } else {
                return L2Response(
                    message: "I need more information to help with that. Could you be more specific?\n\n\(aiResponse)",
                    data: nil,
                    actions: [],
                    suggestedFollowUps: []
                )
            }
        } catch {
            return L2Response(
                message: "I couldn't process that request. Error: \(error.localizedDescription)",
                data: nil,
                actions: [],
                suggestedFollowUps: []
            )
        }
    }

    private func buildLegacyTerminalPrompt(query: String, terminalContext: String, availablePackages: String) -> String {
        """
        You are a terminal command expert. The user wants to perform an action.
        Determine the exact terminal command to execute.

        User's installed terminal packages:
        \(availablePackages.isEmpty ? "None configured" : availablePackages)

        Recent terminal activity:
        \(terminalContext.isEmpty ? "None" : terminalContext)

        User request: "\(query)"

        Respond with ONLY the command to execute in this exact format:
        [COMMAND: <the exact command>]
        [PURPOSE: <brief explanation>]

        Common command patterns:
        - Ollama: ollama list, ollama rm <model>, ollama pull <model>, ollama run <model>
        - Homebrew: brew list, brew upgrade, brew uninstall <pkg>, brew services list
        - Docker: docker ps, docker images, docker rm <id>, docker rmi <image>
        - npm: npm list -g, npm uninstall -g <pkg>, npm update -g
        - pip: pip list, pip uninstall <pkg>, pip install --upgrade <pkg>
        - YouTube: yt-dlp [URL], yt-dlp -x --audio-format mp3 [URL]
        - Git: git status, git commit -m "message", git push

        If you cannot determine a safe command, respond with:
        [COMMAND: NONE]
        [PURPOSE: Unable to determine safe command - need more information]
        """
    }

    /// Extract command from AI response format [COMMAND: xxx]
    private func extractCommand(from response: String) -> String? {
        let pattern = #"\[COMMAND:\s*(.+?)\]"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
           let range = Range(match.range(at: 1), in: response) {
            return String(response[range]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Extract purpose from AI response format [PURPOSE: xxx]
    private func extractPurpose(from response: String) -> String? {
        let pattern = #"\[PURPOSE:\s*(.+?)\]"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
           let range = Range(match.range(at: 1), in: response) {
            return String(response[range]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func executeSearchEverything(query: String) async -> L2Response {
        let results = await systemDataManager.searchAll(query: query, perTypeLimit: 5)

        var message = "## Search Results for '\(query)'\n\n"

        if results.isEmpty {
            message += "No results found."
        } else {
            let grouped = Dictionary(grouping: results) { $0.type }

            for (type, items) in grouped {
                let typeName: String
                switch type {
                case .calendarEvent: typeName = "Calendar Events"
                case .contact: typeName = "Contacts"
                case .photo: typeName = "Photos"
                default: typeName = "Other"
                }

                message += "### \(typeName) (\(items.count))\n"
                for item in items.prefix(3) {
                    message += "- **\(item.title)**"
                    if !item.subtitle.isEmpty {
                        message += " - \(item.subtitle)"
                    }
                    message += "\n"
                }
                message += "\n"
            }
        }

        return L2Response(
            message: message,
            data: ["resultsCount": results.count, "query": query],
            actions: [],
            suggestedFollowUps: [
                "Search for something else",
                "Show more details"
            ]
        )
    }

    private func executeSmartSuggestion() async -> L2Response {
        var suggestions: [String] = []
        var message = "## Smart Suggestions\n\n"

        // Based on context
        switch currentContext {
        case .filesSelected(let urls):
            let fileCount = urls.count
            let extensions = Set(urls.map { $0.pathExtension.lowercased() })

            message += "You have **\(fileCount) file(s)** selected.\n\n"

            if extensions.contains("jpg") || extensions.contains("png") || extensions.contains("heic") {
                suggestions.append("Compress these images")
                suggestions.append("Resize to specific dimensions")
                suggestions.append("Convert to different format")
            }
            if extensions.contains("pdf") {
                suggestions.append("Compress PDF")
                suggestions.append("Merge with other PDFs")
                suggestions.append("Extract text from PDF")
            }
            suggestions.append("Get file info")
            suggestions.append("Move to folder")

        case .url(let urlString):
            message += "You're viewing: **\(urlString)**\n\n"
            suggestions.append("Save page as PDF")
            suggestions.append("Extract text from page")
            suggestions.append("Find related bookmarks")

        case .appFocused(let name, _):
            message += "You're working in **\(name)**.\n\n"
            suggestions.append("Show today's schedule")
            suggestions.append("Find related files")
            suggestions.append("Take a screenshot")

        case .none:
            message += "No specific context detected.\n\n"
            suggestions.append("Show my daily briefing")
            suggestions.append("What's on my calendar?")
            suggestions.append("Show my reminders")
            suggestions.append("Search for something")

        default:
            suggestions.append("Show my daily briefing")
            suggestions.append("Search everything")
        }

        message += "### Try these:\n"
        for suggestion in suggestions {
            message += "- \(suggestion)\n"
        }

        return L2Response(
            message: message,
            data: ["suggestions": suggestions],
            actions: [],
            suggestedFollowUps: suggestions
        )
    }

    private func executeAskQuestion(question: String) async -> L2Response {
        // Use the AI provider to answer the question WITH conversation history
        let aiProvider = settings.createAIProvider()

        // Convert L2Message history to ChatMessage format for AI
        let chatHistory = conversationHistory.suffix(20).compactMap { msg -> ChatMessage? in
            let role: ChatMessage.MessageRole = msg.role == .user ? .user : .assistant
            return ChatMessage(role: role, content: msg.content, timestamp: msg.timestamp)
        }

        // Add terminal execution context if available
        let terminalContext = terminalBridge.getRecentContext(lastN: 5)
        var enhancedQuestion = question
        if !terminalContext.isEmpty {
            enhancedQuestion = """
            Recent terminal activity:
            \(terminalContext)

            User question: \(question)
            """
        }

        do {
            let response = try await aiProvider.sendQuery(
                enhancedQuestion,
                context: currentContext,
                conversationHistory: chatHistory
            )
            return L2Response(
                message: response,
                data: nil,
                actions: [],
                suggestedFollowUps: [
                    "Tell me more",
                    "What else can you help with?"
                ]
            )
        } catch {
            return L2Response(
                message: "I couldn't process that question. Error: \(error.localizedDescription)",
                data: nil,
                actions: [],
                suggestedFollowUps: [
                    "Try asking differently",
                    "What can you help with?"
                ]
            )
        }
    }

    // MARK: - Helper Methods

    /// Extract tool name from "is X installed" patterns
    private func extractToolNameForCheck(from query: String) -> String? {
        let q = query.lowercased()

        // Patterns: "is ollama installed", "is node installed", "do i have python"
        // "check if brew is installed", "is ffmpeg available"
        let patterns: [(regex: String, group: Int)] = [
            (#"is\s+(\w+)\s+installed"#, 1),
            (#"is\s+(\w+)\s+available"#, 1),
            (#"do\s+i\s+have\s+(\w+)"#, 1),
            (#"check\s+if\s+(\w+)\s+is\s+installed"#, 1),
            (#"(\w+)\s+installed\??"#, 1),
            (#"have\s+(\w+)\s+installed"#, 1),
        ]

        for (pattern, group) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
               let range = Range(match.range(at: group), in: q) {
                let toolName = String(q[range])
                // Filter out common false positives
                let excludeWords = ["it", "this", "that", "the", "a", "an", "i", "is", "what"]
                if !excludeWords.contains(toolName) {
                    return toolName
                }
            }
        }
        return nil
    }

    private func extractQuotedText(from query: String) -> String? {
        let pattern = "\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
           let range = Range(match.range(at: 1), in: query) {
            return String(query[range])
        }
        return nil
    }

    private func extractName(from query: String) -> String? {
        // Simple extraction - look for capitalized words after "with", "to", "for"
        let patterns = ["with ", "to ", "for ", "about ", "contact "]
        for pattern in patterns {
            if let range = query.lowercased().range(of: pattern) {
                let afterPattern = String(query[range.upperBound...])
                let words = afterPattern.split(separator: " ")
                if let firstName = words.first {
                    return String(firstName).capitalized
                }
            }
        }
        return nil
    }

    private func extractFormat(from query: String) -> String? {
        let formats = ["png", "jpg", "jpeg", "gif", "webp", "pdf", "mp4", "mov"]
        for format in formats {
            if query.lowercased().contains(format) {
                return format
            }
        }
        return nil
    }

    private func extractToolName(from query: String) -> String? {
        let words = query.lowercased().split(separator: " ")
        if let installIndex = words.firstIndex(of: "install"), installIndex + 1 < words.count {
            return String(words[installIndex + 1])
        }
        return nil
    }

    private func formatTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoString) else { return isoString }

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: date)
    }

    private func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoString) else { return isoString }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        return dateFormatter.string(from: date)
    }

    private func formatDateTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoString) else { return isoString }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        return dateFormatter.string(from: date)
    }
}

// MARK: - L2 Quick Actions

extension L2UnifiedAssistant {

    /// Get quick actions based on current context
    func getQuickActions() -> [L2Response.L2Action] {
        var actions: [L2Response.L2Action] = []

        // Always available
        actions.append(L2Response.L2Action(title: "Daily Briefing", icon: "sun.max") {
            _ = await self.process("daily briefing")
        })

        actions.append(L2Response.L2Action(title: "Today's Schedule", icon: "calendar") {
            _ = await self.process("show today's schedule")
        })

        actions.append(L2Response.L2Action(title: "Reminders", icon: "checklist") {
            _ = await self.process("show my reminders")
        })

        // Context-specific
        switch currentContext {
        case .filesSelected(let urls):
            if !urls.isEmpty {
                actions.append(L2Response.L2Action(title: "Process Files", icon: "doc.badge.gearshape") {
                    _ = await self.process("process these files")
                })
            }

        case .url:
            actions.append(L2Response.L2Action(title: "Save as PDF", icon: "doc.fill") {
                _ = await self.process("save this page as PDF")
            })

        default:
            break
        }

        return actions
    }
}
