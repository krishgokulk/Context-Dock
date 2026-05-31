import AppKit
import Foundation

final class SelectionContextService {
    static let shared = SelectionContextService()

    private init() {}

    func current(from app: NSRunningApplication? = nil) -> UserContext {
        UserContextDetector.shared.detectCurrentContext(from: app)
    }
}

final class FrontmostAppContextService {
    static let shared = FrontmostAppContextService()

    private init() {}

    var current: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }
}

final class BrowserContextService {
    static let shared = BrowserContextService()

    private init() {}

    func safari() -> (url: String, title: String)? {
        ContextDetector.shared.getSafariContext()
    }

    func chrome() -> (url: String, title: String)? {
        ContextDetector.shared.getChromeContext()
    }
}

@MainActor
final class MediaContextService {
    static let shared = MediaContextService()

    private init() {}

    func refresh() {
        MediaDockEngine.shared.refresh()
    }
}
