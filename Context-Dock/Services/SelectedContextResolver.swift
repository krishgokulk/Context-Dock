import AppKit
import ApplicationServices

struct SelectedContextResolver {
    struct ShareInput {
        var axContext: AXContext
        var currentContext: UserContext
        var selectedFileURLs: [URL]
        var frozenSelectionText: String?
        var previousFrontmostPID: pid_t
    }

    static func effectiveShareContext(_ input: ShareInput) -> AXContext {
        var context = input.axContext

        if context.selectedFilePaths.isEmpty {
            context.selectedFilePaths = input.selectedFileURLs.map(\.path)
        }

        if context.selectedFilePaths.isEmpty,
            let documentURL = focusedDocumentURL(pid: input.previousFrontmostPID)
        {
            context.selectedFilePaths = [documentURL.path]
            context.currentURL = nil
        }

        // File/document share wins over stale browser URL.
        if !context.selectedFilePaths.isEmpty {
            context.currentURL = nil
        }

        if context.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
            case .url(let urlString) = input.currentContext
        {
            context.currentURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if context.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
            isBrowserBundleId(context.bundleId)
        {
            if let browserContext = SafariBrowserBridge.shared.currentContext(),
                !browserContext.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                context.currentURL = browserContext.url.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let liveURL = AXContextReader.shared.current.currentURL?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !liveURL.isEmpty
            {
                context.currentURL = liveURL
            }
        }

        if context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            if case .textSelected(let text) = input.currentContext {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { context.selectedText = trimmed }
            } else if let frozenSelectionText = input.frozenSelectionText {
                let trimmed = frozenSelectionText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { context.selectedText = trimmed }
            }
        }

        return context
    }

    static func focusedDocumentURL(pid: pid_t) -> URL? {
        guard pid != 0 else { return nil }

        let axApp = AXUIElementCreateApplication(pid)
        var roots: [AXUIElement] = []

        for attribute in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, attribute, &ref) == .success, let ref {
                roots.append(unsafeBitCast(ref, to: AXUIElement.self))
            }
        }
        roots.append(axApp)

        var visited = 0
        for root in roots {
            if let url = findDocumentURL(in: root, depth: 0, maxDepth: 6, visited: &visited) {
                return url
            }
        }
        return nil
    }

    static func findDocumentURL(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        visited: inout Int
    ) -> URL? {
        guard depth <= maxDepth, visited < 500 else { return nil }
        visited += 1

        for attribute in ["AXDocument", kAXURLAttribute as String] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
                let ref,
                let url = fileURLFromAXValue(ref)
            {
                return url
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
            == .success,
            let children = childrenRef as? [AXUIElement]
        else { return nil }

        for child in children {
            if let url = findDocumentURL(
                in: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                visited: &visited
            ) {
                return url
            }
        }
        return nil
    }

    static func fileURLFromAXValue(_ value: CFTypeRef) -> URL? {
        if let url = value as? URL {
            return validShareFileURL(url)
        }
        if let url = (value as? NSURL) as URL? {
            return validShareFileURL(url)
        }
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.isFileURL {
            return validShareFileURL(url)
        }
        return validShareFileURL(URL(fileURLWithPath: trimmed))
    }

    static func validShareFileURL(_ url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL,
            FileManager.default.fileExists(atPath: standardized.path)
        else { return nil }
        return standardized
    }

    static func isBrowserBundleId(_ bundleId: String) -> Bool {
        AXContextReader.browserBundleIds.contains(bundleId)
            || bundleId.hasPrefix("com.apple.Safari")
            || bundleId.lowercased().contains("chrome")
            || bundleId.lowercased().contains("browser")
    }
}
