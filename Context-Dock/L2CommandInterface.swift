//
//  L2CommandInterface.swift
//  ILauncher
//
//  Unified natural language command interface for L2 operations
//

import Foundation
import Combine

@MainActor
class L2CommandInterface: ObservableObject {
    static let shared = L2CommandInterface()

    struct CommandResult {
        let title: String
        let message: String
        let output: String?
    }

    private let appleAppsAPI = AppleAppsAPI.shared
    private let workflowEngine = L2WorkflowEngine.shared
    private let assistant = L2UnifiedAssistant.shared

    private init() {}

    func canHandle(query: String) -> Bool {
        return parseCommand(query: query) != nil
    }

    func handle(query: String, context: UserContext? = nil) async -> CommandResult? {
        guard let command = parseCommand(query: query) else {
            return nil
        }

        switch command {
        case .workflowRun(let name):
            guard let workflow = resolveWorkflow(name: name) else {
                return CommandResult(title: "Workflow", message: "No workflow named \"\(name)\" found.", output: nil)
            }
            let success = await workflowEngine.executeWorkflow(workflow)
            let message = success ? "Workflow \"\(workflow.name)\" completed." : "Workflow \"\(workflow.name)\" failed."
            return CommandResult(title: "Workflow", message: message, output: workflow.description)

        case .safariTabs:
            let tabs = appleAppsAPI.getAllTabs()
            let output = formatSafariTabs(tabs)
            let message = tabs.isEmpty ? "No Safari tabs found." : "Found \(tabs.count) Safari tab(s)."
            return CommandResult(title: "Safari Tabs", message: message, output: output)

        case .safariCurrent:
            let current = appleAppsAPI.getCurrentTab()
            if current.isEmpty {
                return CommandResult(title: "Safari", message: "No active Safari tab found.", output: nil)
            }
            let output = formatSafariTab(current)
            return CommandResult(title: "Safari Current Tab", message: "Current Safari tab:", output: output)

        case .safariSearch(let term):
            let matches = appleAppsAPI.searchSafariTabs(query: term)
            let output = formatSafariTabs(matches)
            let message = matches.isEmpty ? "No Safari tabs match \"\(term)\"." : "Found \(matches.count) matching tab(s)."
            return CommandResult(title: "Safari Search", message: message, output: output)

        case .safariSavePDF(let filename):
            let success = appleAppsAPI.saveCurrentPageAsPDF(filename: filename)
            let message = success ? "Saved Safari page as PDF." : "Failed to save Safari page as PDF."
            return CommandResult(title: "Safari Save PDF", message: message, output: nil)

        case .safariOpen(let url):
            let success = appleAppsAPI.openSafariURL(url)
            let message = success ? "Opened in Safari: \(url)" : "Failed to open Safari URL."
            return CommandResult(title: "Safari Open", message: message, output: nil)

        case .musicControl(let action):
            let success = appleAppsAPI.musicControl(action)
            let message = success ? "Music: \(action.capitalized)." : "Failed to control Music."
            return CommandResult(title: "Music", message: message, output: nil)

        case .musicInfo:
            let info = appleAppsAPI.getMusicInfo()
            let output = formatMusicInfo(info)
            let message = output.isEmpty ? "No music currently playing." : "Now playing:"
            return CommandResult(title: "Music Info", message: message, output: output.isEmpty ? nil : output)

        case .musicSetVolume(let volume):
            let success = appleAppsAPI.setMusicVolume(volume)
            let message = success ? "Music volume set to \(max(0, min(100, volume)))." : "Failed to set Music volume."
            return CommandResult(title: "Music Volume", message: message, output: nil)

        case .musicGetVolume:
            let volume = appleAppsAPI.getMusicVolume()
            let message = volume == nil ? "Unable to read Music volume." : "Music volume is \(volume ?? 0)."
            return CommandResult(title: "Music Volume", message: message, output: nil)

        case .photosRecent(let limit):
            let photos = appleAppsAPI.getRecentPhotos(limit: limit)
            let output = formatPhotos(photos)
            let message = photos.isEmpty ? "No recent photos found." : "Recent photos (\(photos.count)):"
            return CommandResult(title: "Recent Photos", message: message, output: output)

        case .photosSearch(let term, let limit):
            let photos = appleAppsAPI.searchPhotos(query: term, limit: limit)
            let output = formatPhotos(photos)
            let message = photos.isEmpty ? "No photos match \"\(term)\"." : "Found \(photos.count) photo(s)."
            return CommandResult(title: "Photo Search", message: message, output: output)

        case .finderSelected:
            let files = appleAppsAPI.getSelectedFilesInfo()
            let output = formatFinderSelection(files)
            let message = files.isEmpty ? "No Finder selection detected." : "Finder selection:"
            return CommandResult(title: "Finder Selection", message: message, output: output)

        case .finderCurrentFolder:
            let path = appleAppsAPI.getCurrentFolder()
            let message = path.isEmpty ? "No Finder window is open." : "Current Finder folder: \(path)"
            return CommandResult(title: "Finder Folder", message: message, output: nil)

        case .finderReveal(let path):
            let success = appleAppsAPI.revealInFinder(path)
            let message = success ? "Revealed in Finder: \(path)" : "Failed to reveal in Finder."
            return CommandResult(title: "Finder Reveal", message: message, output: nil)

        case .assistantQuery(let prompt):
            let response = await assistant.process(prompt, context: context)
            return CommandResult(title: "L2 Assistant", message: response.message, output: nil)
        }
    }

    private func resolveWorkflow(name: String) -> L2Workflow? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return nil
        }
        if let exact = workflowEngine.workflows.first(where: { $0.name.lowercased() == normalized }) {
            return exact
        }
        return workflowEngine.workflows.first(where: { $0.name.lowercased().contains(normalized) })
    }

    private func parseCommand(query: String) -> L2Command? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return nil
        }

        if let workflowName = parseWorkflowName(from: q) {
            return .workflowRun(name: workflowName)
        }

        if q.contains("safari") || q.contains("browser") {
            if q.contains("tab") && (q.contains("list") || q.contains("show") || q.contains("all") || q.contains("open")) {
                return .safariTabs
            }
            if q.contains("current") || q.contains("active") {
                return .safariCurrent
            }
            if q.contains("save") && q.contains("pdf") {
                let filename = extractQuotedText(from: query)
                return .safariSavePDF(filename: filename)
            }
            if q.contains("open") {
                if let url = extractURL(from: query) {
                    return .safariOpen(url: url)
                }
            }
            if q.contains("search") || q.contains("find") {
                let term = extractSearchTerm(from: query)
                if !term.isEmpty {
                    return .safariSearch(term: term)
                }
            }
        }

        if q.contains("music") || q.contains("song") || q.contains("track") {
            if q.contains("play") || q.contains("pause") || q.contains("next") || q.contains("previous") || q.contains("skip") || q.contains("toggle") {
                let action = parseMusicAction(from: q)
                return .musicControl(action: action)
            }
            if q.contains("volume") {
                if let value = extractFirstInt(from: q) {
                    return .musicSetVolume(value: value)
                }
                return .musicGetVolume
            }
            if q.contains("what's playing") || q.contains("now playing") || q.contains("current") {
                return .musicInfo
            }
        }

        if q.contains("photo") || q.contains("photos") || q.contains("picture") {
            let limit = extractFirstInt(from: q) ?? 10
            if q.contains("recent") || q.contains("latest") || q.contains("new") {
                return .photosRecent(limit: limit)
            }
            if q.contains("search") || q.contains("find") {
                let term = extractSearchTerm(from: query)
                if !term.isEmpty {
                    return .photosSearch(term: term, limit: limit)
                }
            }
        }

        if q.contains("finder") || q.contains("show in finder") {
            if q.contains("selected") || q.contains("selection") {
                return .finderSelected
            }
            if q.contains("current") && (q.contains("folder") || q.contains("directory") || q.contains("path")) {
                return .finderCurrentFolder
            }
            if q.contains("reveal") || q.contains("show in finder") {
                if let path = extractQuotedText(from: query) {
                    return .finderReveal(path: path)
                }
            }
        }

        let intent = assistant.parseIntent(from: query)
        if case .unknown = intent {
            return nil
        }
        return .assistantQuery(prompt: query)
    }

    private func parseWorkflowName(from query: String) -> String? {
        if query.contains("workflow") && (query.contains("run") || query.contains("execute") || query.contains("start")) {
            if let quoted = extractQuotedText(from: query) {
                return quoted
            }
            if let range = query.range(of: "workflow") {
                let name = query[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    private func parseMusicAction(from query: String) -> String {
        if query.contains("pause") {
            return "pause"
        }
        if query.contains("next") || query.contains("skip") {
            return "next"
        }
        if query.contains("previous") || query.contains("back") {
            return "previous"
        }
        if query.contains("toggle") {
            return "toggle"
        }
        return "play"
    }

    private func extractFirstInt(from text: String) -> Int? {
        let parts = text.split { !$0.isNumber }
        return parts.first.flatMap { Int($0) }
    }

    private func extractQuotedText(from text: String) -> String? {
        let pattern = "\"([^\"]+)\""
        if let range = text.range(of: pattern, options: .regularExpression) {
            let matched = text[range]
            return matched.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private func extractURL(from text: String) -> String? {
        let pattern = #"https?://[^\s]+"#
        if let range = text.range(of: pattern, options: .regularExpression) {
            return String(text[range])
        }
        return nil
    }

    private func extractSearchTerm(from text: String) -> String {
        if let quoted = extractQuotedText(from: text) {
            return quoted
        }
        let tokens = text
            .replacingOccurrences(of: "search", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "find", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "in safari", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "photos", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "tabs", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tokens
    }

    private func formatSafariTabs(_ tabs: [[String: Any]]) -> String {
        guard !tabs.isEmpty else { return "" }
        return tabs.enumerated().map { index, tab in
            let title = tab["title"] as? String ?? "Untitled"
            let url = tab["url"] as? String ?? ""
            return "\(index + 1). \(title) - \(url)"
        }.joined(separator: "\n")
    }

    private func formatSafariTab(_ tab: [String: Any]) -> String {
        let title = tab["title"] as? String ?? "Untitled"
        let url = tab["url"] as? String ?? ""
        if url.isEmpty {
            return title
        }
        return "\(title)\n\(url)"
    }

    private func formatMusicInfo(_ info: [String: Any]) -> String {
        guard let title = info["title"] as? String, !title.isEmpty else {
            return ""
        }
        let artist = info["artist"] as? String ?? ""
        let album = info["album"] as? String ?? ""
        let state = info["state"] as? String ?? ""
        var parts: [String] = [title]
        if !artist.isEmpty {
            parts.append("by \(artist)")
        }
        if !album.isEmpty {
            parts.append("on \(album)")
        }
        if !state.isEmpty {
            parts.append("(\(state))")
        }
        return parts.joined(separator: " ")
    }

    private func formatPhotos(_ photos: [[String: Any]]) -> String {
        guard !photos.isEmpty else { return "" }
        return photos.enumerated().map { index, photo in
            let name = photo["filename"] as? String ?? "Photo \(index + 1)"
            let created = photo["created"] as? String ?? ""
            return created.isEmpty ? "\(index + 1). \(name)" : "\(index + 1). \(name) - \(created)"
        }.joined(separator: "\n")
    }

    private func formatFinderSelection(_ files: [[String: Any]]) -> String {
        guard !files.isEmpty else { return "" }
        return files.compactMap { file in
            let name = file["name"] as? String ?? ""
            let kind = file["kind"] as? String ?? ""
            let size = file["size"] as? Int64 ?? 0
            let path = file["path"] as? String ?? ""
            let detail = [kind.isEmpty ? nil : kind, size > 0 ? "\(size) bytes" : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
            if detail.isEmpty {
                return "\(name) - \(path)"
            }
            return "\(name) (\(detail)) - \(path)"
        }.joined(separator: "\n")
    }

    private enum L2Command {
        case workflowRun(name: String)
        case safariTabs
        case safariCurrent
        case safariSearch(term: String)
        case safariSavePDF(filename: String?)
        case safariOpen(url: String)
        case musicControl(action: String)
        case musicInfo
        case musicSetVolume(value: Int)
        case musicGetVolume
        case photosRecent(limit: Int)
        case photosSearch(term: String, limit: Int)
        case finderSelected
        case finderCurrentFolder
        case finderReveal(path: String)
        case assistantQuery(prompt: String)
    }
}
