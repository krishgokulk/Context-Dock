// QueryFailureGuide.swift
// Context-Dock
//
// Converts every silent failure, empty response, and technical error into
// a plain-English message that tells the user exactly how to complete their
// request. Never leaves the user with a blank bubble or a raw stack trace.
//
// Two-tier output:
//   Tier 1 — instant pattern-based guidance (always works, no AI needed)
//   Tier 2 — on-device AI enrichment appended asynchronously when available

import Foundation
import AppKit

// MARK: - Failure kinds

enum QueryFailureKind {
    case onDeviceNotAvailable                      // macOS < 26, no Apple Silicon
    case onDeviceContextOverflow                   // prompt too long for Foundation Models
    case onDeviceGeneralError(String)              // any other Foundation Models error
    case noAPIKey(provider: String)                // cloud provider selected but no key
    case cloudAPIError(String)                     // HTTP / auth error from cloud provider
    case axFieldNotFound(appName: String)          // AXSearchFieldInjector couldn't find field
    case appNotFound(appName: String)              // target app not running or not installed
    case noPayload                                 // user asked to search/send but nothing selected
    case contactNotFound(name: String)             // Contacts lookup returned nothing
    case menuNotFound(query: String)               // MenuIntentRouter scored 0 matches
    case routeNotMatched(query: String)            // query hit no route at all
    case emptyResponse(query: String)              // AI returned blank / "Done."
}

// MARK: - Guide

@MainActor
final class QueryFailureGuide {
    static let shared = QueryFailureGuide()
    private init() {}

    // MARK: - Public API

    /// Returns an instant helpful message. Never empty, never crashes.
    func instant(for kind: QueryFailureKind, originalQuery: String = "") -> String {
        switch kind {

        case .onDeviceNotAvailable:
            return """
            Apple Intelligence isn't available on this Mac.

            **To use on-device AI:**
            → Requires Apple Silicon (M1 or later) and macOS 26 or later
            → If you have the hardware, go to **System Settings → Apple Intelligence & Siri** and turn it on

            **Or switch to a cloud provider:**
            → Open **Settings → AI Provider** in Context Dock
            → Choose OpenAI, Anthropic, or Gemini and paste your API key
            → Your queries will be answered instantly
            """

        case .onDeviceContextOverflow:
            return """
            The conversation got too long for on-device AI (it has a small memory window).

            **Fix:**
            → Tap the **trash icon** to clear the chat and start fresh
            → Ask a shorter, focused question
            → Or switch to a cloud provider (Settings → AI Provider) for longer conversations
            """

        case .onDeviceGeneralError(let detail):
            let friendly = friendlyOnDeviceError(detail)
            return """
            \(friendly)

            **What you can do:**
            → Wait a moment and try again — on-device AI sometimes needs a few seconds to warm up
            → Clear the chat (trash icon) and rephrase your request
            → Switch to a cloud provider in **Settings → AI Provider** if the issue continues
            """

        case .noAPIKey(let provider):
            return """
            No API key found for **\(provider)**.

            **Add your key:**
            1. Open **Settings → AI Provider** in Context Dock
            2. Select **\(provider)**
            3. Paste your API key
            4. Try your request again

            *Don't have a key? Switch to **On-Device AI** (free, no key needed) if you're on Apple Silicon + macOS 26.*
            """

        case .cloudAPIError(let detail):
            return """
            The \(detail)

            **Try:**
            → Check your API key is correct in **Settings → AI Provider**
            → Make sure you have internet access
            → Try again in a moment — the provider may be temporarily busy
            """

        case .axFieldNotFound(let appName):
            return """
            I couldn't find a search bar in **\(appName)**.

            **Try:**
            → Make sure **\(appName)** is open and a window is visible (not minimised)
            → Click inside \(appName) once, then ask again
            → Use the exact phrase: **"search \(appName.lowercased()) [your query]"**

            *Example: "search \(appName.lowercased()) from linkedin"*
            """

        case .appNotFound(let appName):
            return """
            **\(appName)** isn't running or wasn't found.

            **Try:**
            → Open \(appName) first, then repeat your request
            → Check the name — say **"open \(appName.lowercased())"** to launch it
            → If it's not installed, Context Dock can't control it
            """

        case .noPayload:
            return """
            Nothing is selected to send or search with.

            **Try:**
            → Select some text in any app, then repeat your request
            → Or type the content directly: **"search mail for [your query]"**
            → For files: select them in Finder first, then say **"send this to [name]"**
            """

        case .contactNotFound(let name):
            return """
            I couldn't find **"\(name)"** in your Contacts.

            **Try:**
            → Check the spelling — say **"find contact \(name)"** to confirm
            → Use their full name as it appears in Contacts
            → Make sure the Contacts app has permission (System Settings → Privacy → Contacts)
            """

        case .menuNotFound(let query):
            return """
            No menu item matched **"\(query)"**.

            **Try:**
            → Be more specific: include the menu name, e.g. **"Format → Bold"**
            → Or use the keyboard shortcut if you know it
            → Say **"show menus"** to see what's available in the current app
            """

        case .routeNotMatched(let query):
            return guidance(forUnknownQuery: query)

        case .emptyResponse(let query):
            return """
            The AI returned an empty response for **"\(query)"**.

            **Try:**
            → Rephrase with more detail
            → Clear the chat (trash icon) and ask again
            → For app actions, be explicit: **"[action] in [app]"** — e.g. *"export PDF in Pages"*
            → For searches, use: **"search [app] [query]"** — e.g. *"search mail from john"*
            """
        }
    }

    // MARK: - Async enrichment with on-device AI

    /// Streams an on-device AI-generated guidance message on top of the instant one.
    /// Call this AFTER showing the instant message — it appends extra context asynchronously.
    func enrichAsync(
        kind: QueryFailureKind,
        originalQuery: String,
        onToken: @escaping (String) -> Void,
        onDone: @escaping () -> Void
    ) {
        guard isOnDeviceAvailable() else { onDone(); return }

        let prompt = buildEnrichmentPrompt(kind: kind, originalQuery: originalQuery)
        AIProviderService.shared.streamOnDeviceResponse(
            message: prompt,
            context: .none,
            history: [],
            additionalContextPrompt: "",
            onPartial: { token in DispatchQueue.main.async { onToken(token) } },
            onComplete: { _ in DispatchQueue.main.async { onDone() } },
            onError:    { _ in DispatchQueue.main.async { onDone() } }
        )
    }

    // MARK: - Private helpers

    private func guidance(forUnknownQuery query: String) -> String {
        let q = query.lowercased()

        // Give context-aware hints based on keywords in the query
        if q.contains("search") || q.contains("find") || q.contains("look") {
            return """
            I wasn't sure where to search for **"\(query)"**.

            **Search patterns that work:**
            → **"search [app] [query]"** — e.g. *"search mail from linkedin"*, *"search notes meeting"*
            → **"find [query] in [app]"** — e.g. *"find invoice in Finder"*
            → **"find in contacts"** — searches with your current selection
            """
        }
        if q.contains("send") || q.contains("message") || q.contains("email") {
            return """
            I wasn't sure who or where to send this.

            **Sending patterns that work:**
            → **"send this to [name]"** — sends selected text/file via Messages
            → **"email this to [name]"** — opens Mail compose to that person
            → **"message [name]"** — opens Messages conversation
            *Select something first (text or a file) so I know what to send.*
            """
        }
        if q.contains("open") || q.contains("launch") {
            return """
            I couldn't open that.

            **Try:**
            → **"open [app name]"** — e.g. *"open Safari"*, *"open Notes"*
            → **"open [file.pdf]"** — select the file in Finder first, then say *"open in Preview"*
            """
        }
        if q.contains("save") || q.contains("add") || q.contains("note") {
            return """
            I wasn't sure where to save this.

            **Save patterns that work:**
            → **"add this to Notes"** — saves selected text as a new note
            → **"save this to Bear"** / **"add to Obsidian"** — if those apps are installed
            → **"add reminder [title]"** — adds to Reminders
            """
        }

        return """
        I didn't understand **"\(query)"**.

        **Here's what I can do — just say:**
        → **Search an app:** *"search mail from linkedin"*, *"search notes budget"*
        → **App menu actions:** *"bold this in Pages"*, *"export PDF in Safari"*
        → **Send content:** *"send this to John"*, *"email this to sarah"*
        → **Calendar:** *"what's on today"*, *"add meeting at 3pm tomorrow"*
        → **Files:** *"compress selected images"*, *"find all PDFs in Downloads"*
        → **Ask anything:** *"explain this code"*, *"translate this to French"*

        *Tip: Select text or files first — Context Dock uses your selection as the payload.*
        """
    }

    private func friendlyOnDeviceError(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("context") || r.contains("token") || r.contains("length") || r.contains("window") {
            return "The conversation is too long for on-device AI."
        }
        if r.contains("unavailable") || r.contains("not available") {
            return "Apple Intelligence isn't ready yet."
        }
        if r.contains("cancel") { return "The request was cancelled." }
        return "On-device AI ran into a problem."
    }

    private func isOnDeviceAvailable() -> Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private func buildEnrichmentPrompt(kind: QueryFailureKind, originalQuery: String) -> String {
        let reason: String
        switch kind {
        case .axFieldNotFound(let app): reason = "couldn't find a search field in \(app)"
        case .appNotFound(let app):     reason = "\(app) is not running"
        case .contactNotFound(let n):   reason = "contact '\(n)' not found"
        case .menuNotFound(let q):      reason = "no menu matched '\(q)'"
        case .routeNotMatched(let q):   reason = "query '\(q)' matched no route"
        case .emptyResponse(let q):     reason = "AI returned empty for '\(q)'"
        default:                        reason = "an error occurred"
        }

        return """
        A macOS assistant app failed to handle this user request: "\(originalQuery)"
        Reason: \(reason)

        In 1-2 sentences, suggest ONE concrete rephrased example the user could try instead.
        Be specific. Use the exact format they should type. Do not explain what happened — just the fix.
        """
    }
}
