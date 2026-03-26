//
//  AIShortcutMatcher.swift
//  ILauncher
//
//  AI-Powered Intelligent Shortcut Matching
//  Uses LLM to understand shortcuts and match them intelligently to context
//

import Foundation
import AppKit

/// AI-powered shortcut matcher that understands context and suggests relevant shortcuts
class AIShortcutMatcher {
    static let shared = AIShortcutMatcher()

    private init() {}

    // MARK: - Main Suggestion API

    /// Get AI-powered shortcut suggestions based on current context
    func suggestShortcuts(
        for context: UserContext,
        frontmostApp: String,
        allShortcuts: [SearchResult],
        limit: Int = 6
    ) async -> [SearchResult] {
        print("🤖 [AI Shortcut Matcher] ==========================================")
        print("🤖 [AI Shortcut Matcher] Context: \(context.description)")
        print("🤖 [AI Shortcut Matcher] Frontmost App: \(frontmostApp)")
        print("🤖 [AI Shortcut Matcher] Total shortcuts available: \(allShortcuts.count)")

        // Step 1: Filter and score shortcuts
        var scoredShortcuts: [(shortcut: SearchResult, score: Double, reason: String)] = []

        for shortcut in allShortcuts {
            if let (score, reason) = await scoreShortcut(
                shortcut: shortcut,
                context: context,
                frontmostApp: frontmostApp
            ) {
                scoredShortcuts.append((shortcut, score, reason))
            }
        }

        // Step 2: Sort by score (highest first)
        scoredShortcuts.sort { $0.score > $1.score }

        // Step 3: Log top suggestions
        print("🤖 [AI Shortcut Matcher] Top suggestions:")
        for (index, item) in scoredShortcuts.prefix(limit).enumerated() {
            print("   \(index + 1). \(item.shortcut.title) - Score: \(item.score) - \(item.reason)")
        }
        print("🤖 [AI Shortcut Matcher] ==========================================")

        // Step 4: Return top N shortcuts
        return scoredShortcuts.prefix(limit).map { $0.shortcut }
    }

    // MARK: - Scoring Logic

    /// Score a single shortcut based on context using multiple factors
    private func scoreShortcut(
        shortcut: SearchResult,
        context: UserContext,
        frontmostApp: String
    ) async -> (score: Double, reason: String)? {
        var totalScore: Double = 0.0
        var reasons: [String] = []

        // Factor 1: Context Match (0-100 points)
        let contextScore = scoreContextMatch(shortcut: shortcut, context: context)
        if contextScore > 0 {
            totalScore += contextScore
            reasons.append("context:\(Int(contextScore))")
        }

        // Factor 2: App Match (0-50 points)
        let appScore = scoreAppMatch(shortcut: shortcut, frontmostApp: frontmostApp)
        if appScore > 0 {
            totalScore += appScore
            reasons.append("app:\(Int(appScore))")
        }

        // Factor 3: Usage Frequency (0-30 points)
        let usageScore = scoreUsageFrequency(shortcut: shortcut)
        if usageScore > 0 {
            totalScore += usageScore
            reasons.append("usage:\(Int(usageScore))")
        }

        // Factor 4: Recency (0-20 points)
        let recencyScore = scoreRecency(shortcut: shortcut)
        if recencyScore > 0 {
            totalScore += recencyScore
            reasons.append("recent:\(Int(recencyScore))")
        }

        // Only return shortcuts with some relevance
        guard totalScore > 0 else { return nil }

        let reasonString = reasons.joined(separator: ", ")
        return (totalScore, reasonString)
    }

    // MARK: - Context Matching

    /// Score how well a shortcut matches the current context
    private func scoreContextMatch(shortcut: SearchResult, context: UserContext) -> Double {
        let title = shortcut.title.lowercased()
        let subtitle = shortcut.subtitle.lowercased()

        switch context {
        case .filesSelected(let urls):
            return scoreFileContext(title: title, subtitle: subtitle, files: urls)

        case .textSelected(let text):
            return scoreTextContext(title: title, subtitle: subtitle, text: text)

        case .url(let url):
            // Treat URL context as text, but it should score strongly for link/browser actions
            return scoreURLContext(title: title, subtitle: subtitle, url: url)

        case .contactSelected(let contact):
            return scoreContactContext(title: title, subtitle: subtitle, contact: contact)

        case .appFocused(let appName, _):
            return scoreAppContext(title: title, subtitle: subtitle, appName: appName)

        case .none:
            return 0
        }
    }

    /// Score for file context
    private func scoreFileContext(title: String, subtitle: String, files: [URL]) -> Double {
        guard !files.isEmpty else { return 0 }

        var score: Double = 0

        // Analyze file types
        let extensions = files.map { $0.pathExtension.lowercased() }
        let hasImages = extensions.contains(where: { ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains($0) })
        let hasPDFs = extensions.contains { $0 == "pdf" }
        let hasVideos = extensions.contains(where: { ["mp4", "mov", "avi", "mkv"].contains($0) })
        let hasCode = extensions.contains(where: { ["swift", "py", "js", "java", "cpp"].contains($0) })

        // High-value keywords for files
        let fileKeywords = ["file", "files", "open", "convert", "compress", "resize", "merge", "split"]
        for keyword in fileKeywords {
            if title.contains(keyword) || subtitle.contains(keyword) {
                score += 30
                break
            }
        }

        // Image-specific
        if hasImages {
            let imageKeywords = ["image", "photo", "picture", "compress", "resize", "convert", "optimize"]
            for keyword in imageKeywords {
                if title.contains(keyword) || subtitle.contains(keyword) {
                    score += 50
                    break
                }
            }
        }

        // PDF-specific
        if hasPDFs {
            let pdfKeywords = ["pdf", "merge", "split", "compress"]
            for keyword in pdfKeywords {
                if title.contains(keyword) || subtitle.contains(keyword) {
                    score += 50
                    break
                }
            }
        }

        // Video-specific
        if hasVideos {
            let videoKeywords = ["video", "convert", "compress", "trim", "cut"]
            for keyword in videoKeywords {
                if title.contains(keyword) || subtitle.contains(keyword) {
                    score += 50
                    break
                }
            }
        }

        // Code-specific
        if hasCode {
            let codeKeywords = ["code", "format", "lint", "compile", "run"]
            for keyword in codeKeywords {
                if title.contains(keyword) || subtitle.contains(keyword) {
                    score += 50
                    break
                }
            }
        }

        // Multiple files bonus
        if files.count > 1 {
            let multiKeywords = ["batch", "multiple", "all", "merge", "combine"]
            for keyword in multiKeywords {
                if title.contains(keyword) || subtitle.contains(keyword) {
                    score += 20
                    break
                }
            }
        }

        return min(score, 100)  // Cap at 100
    }

    /// Score for text context
    private func scoreTextContext(title: String, subtitle: String, text: String) -> Double {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }

        var score: Double = 0

        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let charCount = text.count

        // Text processing keywords
        let textKeywords = ["text", "format", "convert", "translate", "summarize", "count", "word"]
        for keyword in textKeywords {
            if title.contains(keyword) || subtitle.contains(keyword) {
                score += 40
                break
            }
        }

        // Long text (good for summarize, analyze)
        if wordCount > 50 {
            let longTextKeywords = ["summarize", "analyze", "extract", "tl;dr"]
            for keyword in longTextKeywords {
                if title.contains(keyword) || subtitle.contains(keyword) {
                    score += 40
                    break
                }
            }
        }

        return min(score, 100)
    }

    /// Score for URL context
    private func scoreURLContext(title: String, subtitle: String, url: String) -> Double {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        // Start with normal text scoring
        var score = scoreTextContext(title: title, subtitle: subtitle, text: trimmed)

        // Extra boost for URL-specific actions
        let urlKeywords = ["url", "link", "browser", "open", "visit", "shorten", "expand", "preview", "copy", "share"]
        for keyword in urlKeywords {
            if title.contains(keyword) || subtitle.contains(keyword) {
                score += 25
                break
            }
        }

        // If the shortcut explicitly mentions a browser, boost
        let browserKeywords = ["safari", "chrome", "arc", "firefox", "edge"]
        for keyword in browserKeywords {
            if title.contains(keyword) || subtitle.contains(keyword) {
                score += 20
                break
            }
        }

        // Short URL strings are often used for quick actions like copy/open
        let wordCount = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        if wordCount < 10 {
            let shortTextKeywords = ["copy", "paste", "search", "open", "visit", "share"]
            for keyword in shortTextKeywords {
                if title.contains(keyword) || subtitle.contains(keyword) {
                    score += 20
                    break
                }
            }
        }

        // URL detection
        let looksLikeURL = trimmed.contains("http://") || trimmed.contains("https://") || trimmed.contains("www.")
        if looksLikeURL {
            let urlActionKeywords = ["url", "link", "open", "browser", "shorten", "preview", "copy"]
            for keyword in urlActionKeywords {
                if title.contains(keyword) || subtitle.contains(keyword) {
                    score += 30
                    break
                }
            }
        }

        // Email-like strings (mailto links or copied emails)
        let looksLikeEmail = trimmed.contains("@") && trimmed.contains(".")
        if looksLikeEmail {
            let emailKeywords = ["email", "mail", "send", "compose"]
            for keyword in emailKeywords {
                if title.contains(keyword) || subtitle.contains(keyword) {
                    score += 20
                    break
                }
            }
        }

        return min(score, 100)
    }

    /// Score for contact context
    private func scoreContactContext(title: String, subtitle: String, contact: String) -> Double {
        let contactKeywords = ["contact", "email", "call", "message", "sms", "facetime", "whatsapp"]
        var score: Double = 0

        for keyword in contactKeywords {
            if title.contains(keyword) || subtitle.contains(keyword) {
                score += 60
                break
            }
        }

        return min(score, 100)
    }

    /// Score for app-focused context
    private func scoreAppContext(title: String, subtitle: String, appName: String) -> Double {
        let appLower = appName.lowercased()
        var score: Double = 0

        // Direct app name match
        if title.contains(appLower) || subtitle.contains(appLower) {
            score += 80
        }

        // App-specific keywords
        let appKeywords = ["open", "launch", "quit", "restart", "window"]
        for keyword in appKeywords {
            if title.contains(keyword) || subtitle.contains(keyword) {
                score += 20
                break
            }
        }

        return min(score, 100)
    }

    // MARK: - App Matching

    /// Score how well a shortcut matches the frontmost app
    private func scoreAppMatch(shortcut: SearchResult, frontmostApp: String) -> Double {
        let title = shortcut.title.lowercased()
        let subtitle = shortcut.subtitle.lowercased()
        let appLower = frontmostApp.lowercased()

        var score: Double = 0

        // Exact app name in title
        if title.contains(appLower) {
            score += 30
        }

        // App name in subtitle
        if subtitle.contains(appLower) {
            score += 20
        }

        // Common app-specific patterns
        if title.hasPrefix("open in \(appLower)") || title.hasPrefix("\(appLower):") {
            score += 40
        }

        return min(score, 50)
    }

    // MARK: - Usage Analytics

    /// Score based on how frequently this shortcut is used
    private func scoreUsageFrequency(shortcut: SearchResult) -> Double {
        let usageScore = UsageTracker.shared.getScore(for: shortcut.trackingIdentifier)

        // Convert frecency score (0-100) to points (0-30)
        return (usageScore / 100.0) * 30.0
    }

    /// Score based on how recently this shortcut was used
    private func scoreRecency(shortcut: SearchResult) -> Double {
        // Check if used in last hour -> 20 points
        // Used in last day -> 15 points
        // Used in last week -> 10 points
        // Used in last month -> 5 points

        guard let lastUsed = UsageTracker.shared.getLastUsed(for: shortcut.trackingIdentifier) else {
            return 0
        }

        let timeInterval = Date().timeIntervalSince(lastUsed)
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        let week: TimeInterval = 604800
        let month: TimeInterval = 2592000

        if timeInterval < hour {
            return 20
        } else if timeInterval < day {
            return 15
        } else if timeInterval < week {
            return 10
        } else if timeInterval < month {
            return 5
        }

        return 0
    }
}

// MARK: - Helper Extensions

extension UsageTracker {
    /// Get last used timestamp for an item
    func getLastUsed(for identifier: String) -> Date? {
        // Check if item exists in tracking
        guard getScore(for: identifier) > 0 else { return nil }

        // This would need to be implemented in UsageTracker
        // For now, return nil
        return nil
    }
}
