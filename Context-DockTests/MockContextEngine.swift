import AppKit
import Foundation
@testable import Context_Dock

// MARK: - MockContextEngine
// A test double for ContextEngineProtocol.
// Swap into ContextDockEnvironment(engine: MockContextEngine()) to test
// any UI code that reads context without spinning up ContextDetector (which
// requires Accessibility permissions and running apps).

final class MockContextEngine: ContextEngineProtocol {

    // MARK: Configurable stubs
    var stubbedFinderFiles: [URL] = []
    var stubbedFinderDirectory: String? = nil
    var stubbedSelectedText: String? = nil
    var stubbedSafariContext: (url: String, title: String)? = nil
    var stubbedSafariSelectedText: String? = nil
    var stubbedSafariPageContext: String? = nil
    var stubbedSafariTabs: [BrowserTab] = []
    var stubbedChromeContext: (url: String, title: String)? = nil
    var stubbedChromeTabs: [BrowserTab] = []
    var stubbedArcContext: (url: String, title: String)? = nil
    var stubbedArcTabs: [BrowserTab] = []
    var stubbedMusicInfo: (title: String, artist: String, album: String)? = nil
    var stubbedPodcastInfo: (title: String, show: String)? = nil
    var stubbedClipboardContent: String? = nil
    var stubbedNotesContext: String? = nil
    var stubbedMailContext: (subject: String, from: String, content: String)? = nil
    var stubbedDetectedContexts: [DetectedContext] = []

    // MARK: Call counters — assert the right methods were called
    private(set) var finderFilesCallCount = 0
    private(set) var selectedTextCallCount = 0
    private(set) var clipboardCallCount = 0

    // MARK: ContextEngineProtocol conformance

    func getFinderSelectedFiles() -> [URL] {
        finderFilesCallCount += 1
        return stubbedFinderFiles
    }

    func getCurrentFinderDirectory() -> String? { stubbedFinderDirectory }

    func analyzeFiles(_ urls: [URL]) -> [FileAnalysisResult] {
        urls.map { url in
            (url: url, type: url.pathExtension, size: "1 KB", isImage: false, content: nil)
        }
    }

    func getSelectedText(from app: NSRunningApplication) -> String? {
        selectedTextCallCount += 1
        return stubbedSelectedText
    }

    func getSafariContext() -> (url: String, title: String)? { stubbedSafariContext }
    func getSafariSelectedText() -> String? { stubbedSafariSelectedText }
    func getSafariPageContextForAI() -> String? { stubbedSafariPageContext }
    func getAllSafariTabs() -> [BrowserTab] { stubbedSafariTabs }
    func getChromeContext() -> (url: String, title: String)? { stubbedChromeContext }
    func getAllChromeTabs() -> [BrowserTab] { stubbedChromeTabs }
    func getArcContext() -> (url: String, title: String)? { stubbedArcContext }
    func getAllArcTabs() -> [BrowserTab] { stubbedArcTabs }

    func getMusicInfo() -> (title: String, artist: String, album: String)? { stubbedMusicInfo }
    func getPodcastInfo() -> (title: String, show: String)? { stubbedPodcastInfo }

    func getClipboardContent() -> String? {
        clipboardCallCount += 1
        return stubbedClipboardContent
    }

    func getNotesContext() -> String? { stubbedNotesContext }
    func getMailContext() -> (subject: String, from: String, content: String)? { stubbedMailContext }

    func getComprehensiveContext(frontmostApp: NSRunningApplication) -> [DetectedContext] {
        stubbedDetectedContexts
    }

    func detectContext(frontmostApp: NSRunningApplication) -> DetectedContext? {
        stubbedDetectedContexts.first
    }
}
