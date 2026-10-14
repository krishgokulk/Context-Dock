import AppKit
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

extension LauncherView {




























    /// SF Symbol name for a file extension
    func fileIcon(for ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff": return "photo"
        case "mp4", "mov", "avi", "mkv", "m4v": return "film"
        case "mp3", "aac", "flac", "wav", "m4a": return "music.note"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        case "doc", "docx", "pages": return "doc.text"
        case "xls", "xlsx", "numbers", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        case "swift", "py", "js", "ts", "rb", "go", "rs", "kt":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }




























	    var shouldShowGlobalScopedChatPin: Bool {
	        guard let target = currentGlobalScopedChatTarget else { return false }
	        let q = searchState.query.trimmingCharacters(in: .whitespacesAndNewlines)
	        guard !q.isEmpty else { return false }
	        if target.bundleId.hasPrefix("cli://") {
	            // A pinned CLI scope is a terminal-capability chat. It must not yield
	            // Enter to focused app/search/action rows; typed text always becomes a
	            // scoped AI request that can propose CLI commands with approval.
	            return !showMediaLayer && !aiMode.isActive
	        }
	        guard isGlobalContextActive else { return false }
	        guard focusedAppPillIndex == nil,
	            l2.focusedPillIndex == nil,
	            searchState.selectedIndex == nil,
	            !showMediaLayer,
	            !aiMode.isActive
	        else { return false }
	        return isQuestionStyleDockQuery(q)
	    }


    func executeMatchDockIcon(_ item: MatchDockIcon) {
        guard let bundleID = item.bundleID else { return }
        if !item.isExpandable,
            let result = currentOrImmediateGlobalAppMatches(for: searchState.query)
                .first(where: { bundleIdentifier(forApplicationResult: $0) == bundleID })
        {
            executeGlobalAppSearchResult(result)
            return
        }

        if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }) {
            activateRunningAppFromGlobalContext(runningApp)
        }
    }









}



/// Where Return went. Three routes can claim it in General Chat and two of them return
/// silently, so "Enter does nothing" has been indistinguishable from "Enter was handled by
/// something that had nothing to say" from outside the debugger.
func generalChatReturnLog(_ what: String) {
    Logger(subsystem: "com.krishgokul.ContextDock", category: "GeneralChat")
        .notice("return: \(what, privacy: .public)")
}

extension LauncherView {
}
