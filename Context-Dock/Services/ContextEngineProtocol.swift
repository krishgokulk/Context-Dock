import AppKit
import Combine
import Foundation

// MARK: - Return type alias

typealias FileAnalysisResult = (url: URL, type: String, size: String, isImage: Bool, content: String?)

// MARK: - ContextEngineProtocol

/// Abstracts all context-reading from the concrete ContextDetector.
/// UI layers depend on this protocol; only App/ wires in the real class.
protocol ContextEngineProtocol: AnyObject {
    func getFinderSelectedFiles() -> [URL]
    func getCurrentFinderDirectory() -> String?
    func analyzeFiles(_ urls: [URL]) -> [FileAnalysisResult]
    func getSelectedText(from app: NSRunningApplication) -> String?

    func getSafariContext() -> (url: String, title: String)?
    func getSafariSelectedText() -> String?
    func getSafariPageContextForAI() -> String?
    func getAllSafariTabs() -> [BrowserTab]
    func getChromeContext() -> (url: String, title: String)?
    func getAllChromeTabs() -> [BrowserTab]
    func getArcContext() -> (url: String, title: String)?
    func getAllArcTabs() -> [BrowserTab]

    func getMusicInfo() -> (title: String, artist: String, album: String)?
    func getPodcastInfo() -> (title: String, show: String)?
    func getClipboardContent() -> String?
    func getNotesContext() -> String?
    func getMailContext() -> (subject: String, from: String, content: String)?

    func getComprehensiveContext(frontmostApp: NSRunningApplication) -> [DetectedContext]
    func detectContext(frontmostApp: NSRunningApplication) -> DetectedContext?
}

// MARK: - FrontmostAppInfo

struct FrontmostAppInfo: Equatable {
    let name: String
    let bundleID: String
}

// MARK: - ContextDockEnvironment

/// Single typed bridge between AppDelegate (event source) and SwiftUI views (consumers).
/// AppDelegate calls update methods directly instead of posting NotificationCenter events.
/// Views subscribe to the Combine subjects via .onReceive — same push semantics,
/// no userInfo dictionary casting.
@MainActor
final class ContextDockEnvironment: ObservableObject {
    static let shared = ContextDockEnvironment()

    /// Injected at startup; swap out in tests without touching any call site.
    let engine: any ContextEngineProtocol

    let userContextUpdates = PassthroughSubject<UserContext, Never>()
    let frontmostAppUpdates = PassthroughSubject<FrontmostAppInfo, Never>()

    init(engine: any ContextEngineProtocol = ContextDetector.shared) {
        self.engine = engine
    }

    func userContextDidDetect(_ context: UserContext) {
        userContextUpdates.send(context)
    }

    func frontmostAppDidChange(name: String, bundleID: String) {
        frontmostAppUpdates.send(FrontmostAppInfo(name: name, bundleID: bundleID))
    }
}
