//
//  AIShortcutMatcher.swift
//  ILauncher
//
//  AI-Powered Intelligent Shortcut Matching
//  Uses LLM to understand shortcuts and match them intelligently to context
//

import Foundation
import AppKit

// Lightweight semantic matching via synonym expansion and fuzzy contains
fileprivate struct SemanticMatcher {
    static let synonyms: [String: [String]] = [
        "compress": ["compress", "reduce size", "shrink", "make smaller", "optimize"],
        "resize": ["resize", "scale", "change size", "downscale", "upscale"],
        "merge": ["merge", "combine", "join", "append"],
        "split": ["split", "separate", "divide", "chunk"],
        "open": ["open", "launch", "start"],
        "convert": ["convert", "transform", "change format"],
        "summarize": ["summarize", "tl;dr", "shorten", "condense"],
        "analyze": ["analyze", "inspect", "extract", "understand"],
        "copy": ["copy", "duplicate", "clone"],
        "share": ["share", "send", "distribute"],
        "email": ["email", "mail", "send email", "compose"],
        "message": ["message", "sms", "text"],
    ]

    static func matches(_ haystack: String, intents: [String]) -> Bool {
        let h = haystack.lowercased()
        for intent in intents {
            if h.contains(intent) { return true }
            if let syns = synonyms[intent] {
                for s in syns where h.contains(s) { return true }
            }
        }
        return false
    }
}

// Lightweight intent parser to extract action and entities from free text
fileprivate struct IntentParseResult { let action: String?; let entities: [String]; let appHints: [String] }
fileprivate struct IntentParser {
    static func parse(from text: String) -> IntentParseResult {
        let lower = text.lowercased()
        var action: String? = nil
        var entities: [String] = []
        var appHints: [String] = []
        // very simple patterns: "send to X on Y", "open Z", "message John"
        if lower.contains("send") { action = "send" }
        if lower.contains("message") || lower.contains("sms") { action = action ?? "message" }
        if lower.contains("email") || lower.contains("mail") { action = action ?? "email" }
        if lower.contains("open") || lower.contains("launch") { action = action ?? "open" }
        // app hints
        let knownApps = ["slack","mail","messages","whatsapp","safari","chrome"]
        for app in knownApps where lower.contains(app) { appHints.append(app) }
        // naive entity extraction: capitalized words (placeholder), and words after "to "
        let tokens = lower.split(separator: " ").map(String.init)
        if let idx = tokens.firstIndex(of: "to"), idx+1 < tokens.count { entities.append(tokens[idx+1]) }
        return IntentParseResult(action: action, entities: Array(Set(entities)), appHints: Array(Set(appHints)))
    }
}

/// Possible strategies to execute an action
enum FallbackStrategy: String {
    case directAPI = "Direct API"
    case script = "Script"
    case accessibility = "Accessibility (AX)"
}

/// Suggestion preview for UI/clarity
struct SuggestionPreview {
    let shortcut: SearchResult
    let score: Double
    let reason: String
    let fallbackPlan: [FallbackStrategy] // Ordered execution plan
    let needsDisambiguation: Bool
}

/// AI-powered shortcut matcher that understands context and suggests relevant shortcuts
class AIShortcutMatcher {
    static let shared = AIShortcutMatcher()

    private init() {}

    private let confidenceThreshold: Double = 30 // below this, suggestions are discarded
    private let disambiguationDelta: Double = 5  // if top two scores within this, mark as ambiguous

    // Quick prefilter based on context/app semantics to reduce scoring set
    private func prefilterShortcuts(_ shortcuts: [SearchResult], context: UserContext, frontmostApp: String, limit: Int) -> [SearchResult] {
        let intentsForContext: [String] = {
            switch context {
            case .filesSelected(let urls):
                let exts = urls.map { $0.pathExtension.lowercased() }
                if exts.contains(where: { ["jpg","jpeg","png","gif","heic","webp"].contains($0) }) {
                    return ["image", "photo", "compress", "resize", "convert", "optimize", "open"]
                } else if exts.contains("pdf") {
                    return ["pdf", "merge", "split", "compress", "open"]
                } else {
                    return ["file", "open", "convert", "compress", "merge", "split"]
                }
            case .textSelected:
                return ["text", "format", "translate", "summarize", "analyze", "copy"]
            case .url:
                return ["url", "link", "open", "browser", "preview", "copy", "share"]
            case .contactSelected:
                return ["contact", "email", "call", "message"]
            case .appFocused(let app, _):
                return [app.lowercased(), "open", "launch", "quit", "window"]
            case .none:
                return []
            }
        }()

        let appLower = frontmostApp.lowercased()
        let filtered = shortcuts.filter { sr in
            let t = sr.title.lowercased()
            let s = sr.subtitle.lowercased()
            // semantic match on title or subtitle for any context intent or app name
            if SemanticMatcher.matches(t, intents: intentsForContext) || SemanticMatcher.matches(s, intents: intentsForContext) { return true }
            if !appLower.isEmpty && (t.contains(appLower) || s.contains(appLower)) { return true }
            return false
        }

        if filtered.isEmpty { return Array(shortcuts.prefix(limit)) }
        return Array(filtered.prefix(limit))
    }

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

        // Step 1: Pre-filter likely candidates by quick semantic/context checks to reduce latency
        let prefiltered: [SearchResult] = prefilterShortcuts(allShortcuts, context: context, frontmostApp: frontmostApp, limit: 30)

        // Step 2: Filter and score shortcuts (parallelized for latency)
        let scoredShortcutsArray = await withTaskGroup(of: (SearchResult, Double, String)?.self) { group in
            for shortcut in prefiltered {
                group.addTask {
                    await self.scoreShortcut(shortcut: shortcut, context: context, frontmostApp: frontmostApp)
                        .map { (shortcut, $0.score, $0.reason) }
                }
            }
            var results: [(SearchResult, Double, String)] = []
            for await item in group {
                if let value = item { results.append(value) }
            }
            return results
        }

        // Step 3: Sort by score (highest first)
        let sortedShortcuts = scoredShortcutsArray.sorted { $0.1 > $1.1 }

        // Step 4: Log top suggestions
        print("🤖 [AI Shortcut Matcher] Top suggestions:")
        for (index, item) in sortedShortcuts.prefix(limit).enumerated() {
            print("   \(index + 1). \(item.0.title) - Score: \(item.1) - \(item.2)")
        }
        print("🤖 [AI Shortcut Matcher] ==========================================")

        // Step 5: Filter by confidence threshold and return top N shortcuts
        let filteredByConfidence = sortedShortcuts.filter { $0.1 >= confidenceThreshold }
        return filteredByConfidence.prefix(limit).map { $0.0 }
    }

    // MARK: - Preview API for UI and Fallback Support

    /// Get previews for suggested shortcuts (score + fallback plan + reason)
    /// This provides clarity on scoring and fallback strategies for UI display and reliability.
    func previewSuggestions(
        for context: UserContext,
        frontmostApp: String,
        allShortcuts: [SearchResult],
        limit: Int = 6
    ) async -> [SuggestionPreview] {
        // Pre-filter to reduce candidates for preview
        let prefiltered: [SearchResult] = prefilterShortcuts(allShortcuts, context: context, frontmostApp: frontmostApp, limit: 30)

        // Parallel scoring for latency
        let scoredShortcutsArray = await withTaskGroup(of: (SearchResult, Double, String)?.self) { group in
            for shortcut in prefiltered {
                group.addTask {
                    await self.scoreShortcut(shortcut: shortcut, context: context, frontmostApp: frontmostApp)
                        .map { (shortcut, $0.score, $0.reason) }
                }
            }
            var results: [(SearchResult, Double, String)] = []
            for await item in group {
                if let value = item { results.append(value) }
            }
            return results
        }

        let sortedShortcuts = scoredShortcutsArray.sorted { $0.1 > $1.1 }
        let filteredByConfidence = sortedShortcuts.filter { $0.1 >= confidenceThreshold }
        let topArray = Array(filteredByConfidence.prefix(limit))
        let ambiguous: Bool = {
            guard topArray.count >= 2 else { return false }
            return abs(topArray[0].1 - topArray[1].1) <= disambiguationDelta
        }()
        return topArray.map { (shortcut, score, reason) in
            let fallbackPlan: [FallbackStrategy] = self.dynamicFallbackPlan(for: shortcut)
            return SuggestionPreview(shortcut: shortcut, score: score, reason: reason, fallbackPlan: fallbackPlan, needsDisambiguation: ambiguous)
        }
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
        var penalties: Double = 0

        // Factor 1: Context Match (0-100 points + penalties)
        let (contextScore, contextReason, contextPenalty) = scoreContextMatch(shortcut: shortcut, context: context)
        if contextScore > 0 {
            totalScore += contextScore
            reasons.append(contextReason)
        }
        if contextPenalty < 0 {
            penalties += contextPenalty
        }

        // Factor 2: App Match (0-50 points)
        let (appScore, appReason) = scoreAppMatch(shortcut: shortcut, frontmostApp: frontmostApp)
        if appScore > 0 {
            totalScore += appScore
            reasons.append(appReason)
        }

        // Factor 3: Usage Frequency (0-30 points)
        let usageScore = scoreUsageFrequency(shortcut: shortcut)
        if usageScore > 0 {
            totalScore += usageScore
            reasons.append("usage:+\(Int(usageScore))")
        }

        // Factor 4: Recency (0-20 points)
        let recencyScore = scoreRecency(shortcut: shortcut)
        if recencyScore > 0 {
            totalScore += recencyScore
            reasons.append("recency:+\(Int(recencyScore))")
        }

        // Apply penalties
        if penalties < 0 {
            totalScore += penalties
            reasons.append("penalty:\(Int(penalties))")
        }

        // Only return shortcuts with some relevance
        guard totalScore > 0 else { return nil }

        let reasonString = reasons.isEmpty ? "relevant" : reasons.joined(separator: ", ")
        return (totalScore, reasonString)
    }

    // MARK: - Context Matching

    /// Score how well a shortcut matches the current context
    private func scoreContextMatch(shortcut: SearchResult, context: UserContext) -> (Double, String, Double) {
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
            // appFocused context returns (Double, String, Double) but app context here has no penalties
            let (score, reason) = scoreAppContext(title: title, subtitle: subtitle, appName: appName)
            return (score, reason, 0)

        case .none:
            return (0, "no context", 0)
        }
    }

    /// Score for file context
    private func scoreFileContext(title: String, subtitle: String, files: [URL]) -> (Double, String, Double) {
        guard !files.isEmpty else { return (0, "no files", 0) }
        var score: Double = 0
        var penalty: Double = 0
        var reasonParts: [String] = []

        let extensions = files.map { $0.pathExtension.lowercased() }
        let hasImages = extensions.contains(where: { ["jpg","jpeg","png","gif","heic","webp"].contains($0) })
        let hasPDFs = extensions.contains { $0 == "pdf" }
        let hasVideos = extensions.contains(where: { ["mp4","mov","avi","mkv"].contains($0) })
        let hasCode = extensions.contains(where: { ["swift","py","js","java","cpp"].contains($0) })

        // General file intents
        if SemanticMatcher.matches(title+" "+subtitle, intents: ["file","open"]) {
            score += 20
            reasonParts.append("file/open")
        }

        if hasImages {
            if SemanticMatcher.matches(title+" "+subtitle, intents: ["image","photo","compress","resize","convert","optimize"]) {
                score += 60
                reasonParts.append("image ops")
            } else {
                penalty -= 30
            }
        }
        if hasPDFs {
            if SemanticMatcher.matches(title+" "+subtitle, intents: ["pdf","merge","split","compress"]) {
                score += 60
                reasonParts.append("pdf ops")
            } else {
                penalty -= 30
            }
        }
        if hasVideos {
            if SemanticMatcher.matches(title+" "+subtitle, intents: ["video","convert","compress","trim","cut"]) {
                score += 50
                reasonParts.append("video ops")
            } else {
                penalty -= 25
            }
        }
        if hasCode {
            if SemanticMatcher.matches(title+" "+subtitle, intents: ["code","format","lint","compile","run"]) {
                score += 50
                reasonParts.append("code ops")
            } else {
                penalty -= 20
            }
        }

        if files.count > 1 {
            if SemanticMatcher.matches(title+" "+subtitle, intents: ["batch","multiple","merge","combine"]) {
                score += 15
                reasonParts.append("batch")
            }
        }

        return (min(score, 100), reasonParts.isEmpty ? "file context" : reasonParts.joined(separator: ", "), penalty)
    }

    /// Score for text context
    private func scoreTextContext(title: String, subtitle: String, text: String) -> (Double, String, Double) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (0, "empty text", 0) }

        var score: Double = 0
        var penalty: Double = 0
        var reasonParts: [String] = []

        let parsed = IntentParser.parse(from: text)
        if let action = parsed.action {
            if SemanticMatcher.matches(title+" "+subtitle, intents: [action]) { score += 20; reasonParts.append("intent:\(action)") }
        }
        if !parsed.appHints.isEmpty {
            if SemanticMatcher.matches(title+" "+subtitle, intents: parsed.appHints) { score += 15; reasonParts.append("app hint") }
        }

        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count

        // Text processing keywords
        if SemanticMatcher.matches(title+" "+subtitle, intents: ["text", "format", "convert", "translate", "summarize", "count", "word"]) {
            score += 40
            reasonParts.append("text ops")
        }

        // Long text (good for summarize, analyze)
        if wordCount > 50 {
            if SemanticMatcher.matches(title+" "+subtitle, intents: ["summarize", "analyze", "extract", "tl;dr"]) {
                score += 40
                reasonParts.append("long text ops")
            } else {
                penalty -= 20
            }
        }

        return (min(score, 100), reasonParts.isEmpty ? "text context" : reasonParts.joined(separator: ", "), penalty)
    }

    /// Score for URL context
    private func scoreURLContext(title: String, subtitle: String, url: String) -> (Double, String, Double) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (0, "empty url", 0) }
        
        let parsed = IntentParser.parse(from: trimmed)

        // Start with normal text scoring
        var (score, reason, penalty) = scoreTextContext(title: title, subtitle: subtitle, text: trimmed)

        if let action = parsed.action {
            if SemanticMatcher.matches(title+" "+subtitle, intents: [action]) { score += 20; reason = reason.isEmpty ? "intent:\(action)" : reason + ", intent:\(action)" }
        }
        if !parsed.appHints.isEmpty {
            if SemanticMatcher.matches(title+" "+subtitle, intents: parsed.appHints) { score += 15; reason = reason.isEmpty ? "app hint" : reason + ", app hint" }
        }

        // Extra boost for URL-specific actions
        let urlIntentFound = SemanticMatcher.matches(title+" "+subtitle, intents: ["url", "link", "browser", "open", "visit", "shorten", "expand", "preview", "copy", "share"])

        if urlIntentFound {
            score += 25
            reason = reason.isEmpty ? "url actions" : reason + ", url actions"
        } else {
            penalty -= 10
        }

        // If the shortcut explicitly mentions a browser, boost
        if SemanticMatcher.matches(title+" "+subtitle, intents: ["safari", "chrome", "arc", "firefox", "edge"]) {
            score += 20
            reason += ", browser boost"
        }

        // Short URL strings for quick actions
        let wordCount = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        if wordCount < 10 {
            if SemanticMatcher.matches(title+" "+subtitle, intents: ["copy", "paste", "search", "open", "visit", "share"]) {
                score += 20
                reason += ", short url ops"
            }
        }

        // URL detection boost
        let looksLikeURL = trimmed.contains("http://") || trimmed.contains("https://") || trimmed.contains("www.")
        if looksLikeURL {
            if SemanticMatcher.matches(title+" "+subtitle, intents: ["url", "link", "open", "browser", "shorten", "preview", "copy"]) {
                score += 30
                reason += ", url detected ops"
            }
        }

        // Email-like strings
        let looksLikeEmail = trimmed.contains("@") && trimmed.contains(".")
        if looksLikeEmail {
            if SemanticMatcher.matches(title+" "+subtitle, intents: ["email", "mail", "send", "compose"]) {
                score += 20
                reason += ", email ops"
            }
        }

        return (min(score, 100), reason.isEmpty ? "url context" : reason.trimmingCharacters(in: .whitespacesAndNewlines), penalty)
    }

    /// Score for contact context
    private func scoreContactContext(title: String, subtitle: String, contact: String) -> (Double, String, Double) {
        let contactKeywords = ["contact", "email", "call", "message", "sms", "facetime", "whatsapp"]
        var score: Double = 0
        var penalty: Double = 0
        var reason: String = ""

        if SemanticMatcher.matches(title+" "+subtitle, intents: contactKeywords) {
            score = 60
            reason = "contact ops"
        } else {
            penalty = -30
            reason = "contact mismatch"
        }

        return (min(score, 100), reason, penalty)
    }

    /// Score for app-focused context
    private func scoreAppContext(title: String, subtitle: String, appName: String) -> (Double, String) {
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

        return (min(score, 100), "app:\(appName)")
    }

    // MARK: - App Matching

    /// Score how well a shortcut matches the frontmost app
    private func scoreAppMatch(shortcut: SearchResult, frontmostApp: String) -> (Double, String) {
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

        return (min(score, 50), "app:\(frontmostApp)")
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

    // Determine fallback plan dynamically
    private func dynamicFallbackPlan(for shortcut: SearchResult) -> [FallbackStrategy] {
        let t = shortcut.title.lowercased()
        let s = shortcut.subtitle.lowercased()
        let explicitAPI = t.contains("[cap:api]") || s.contains("[cap:api]")
        let explicitScript = t.contains("[cap:script]") || s.contains("[cap:script]")
        let explicitAX = t.contains("[cap:ax]") || s.contains("[cap:ax]")
        let supportsAPI = explicitAPI || t.contains("api") || s.contains("api") || t.contains("native")
        let supportsScript = explicitScript || t.contains("script") || s.contains("script") || t.contains("shell") || s.contains("shell")
        let supportsAX = explicitAX || (!supportsAPI && !supportsScript)
        if supportsAPI && supportsScript {
            return [.directAPI, .script, .accessibility]
        } else if supportsAPI {
            return supportsAX ? [.directAPI, .accessibility] : [.directAPI]
        } else if supportsScript {
            return supportsAX ? [.script, .accessibility] : [.script]
        } else {
            return [.accessibility]
        }
    }

    // Feedback hooks to record success/failure externally
    func recordExecutionResult(for shortcut: SearchResult, success: Bool) {
        let id = shortcut.trackingIdentifier
        if success {
            // modest boost
            let current: Double = UsageTracker.shared.getScore(for: id)
            let boosted: Double = min(100.0, current + 5.0)
            UsageTracker.shared.setScore(boosted, for: id)
            UsageTracker.shared.setLastUsed(now: Date(), for: id)
        } else {
            // slight penalty
            let current: Double = UsageTracker.shared.getScore(for: id)
            let reduced: Double = max(0.0, current - 3.0)
            UsageTracker.shared.setScore(reduced, for: id)
        }
    }
}

// MARK: - Helper Extensions

extension UsageTracker {
    /// Get last used timestamp for an item
    func getLastUsed(for identifier: String) -> Date? {
        let key = "usage.lastUsed.\(identifier)"
        if let ts = UserDefaults.standard.object(forKey: key) as? TimeInterval {
            return Date(timeIntervalSince1970: ts)
        }
        return nil
    }

    /// Record last used timestamp for an item (called elsewhere in app when executing)
    func setLastUsed(now date: Date = Date(), for identifier: String) {
        let key = "usage.lastUsed.\(identifier)"
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
    }

    /// Update usage score (simple reinforcement). Real implementation should persist properly.
    func setScore(_ score: Double, for identifier: String) {
        let key = "usage.score.\(identifier)"
        UserDefaults.standard.set(score, forKey: key)
    }
}

