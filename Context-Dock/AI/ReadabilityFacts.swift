// ReadabilityFacts.swift
// Context-Dock
//
// What DoraX could and could not read from the frontmost app, as plain facts for the model.
//
// Asked "what does this page say, and what's my latest message?" in the Claude desktop app's
// chat, the answer was "Page text not readable ... Want me to re-read page?". Nothing in the
// prompt said which app was in front, that the app exposes no accessibility text, or that a
// second read would return the same nothing, so the model improvised from the word "page".
//
// This is the pure half of the fix: a value describing readability and the text it renders.
// The host only supplies facts; the model still answers in its own words, guided by
// `instruction`. No per-app cases: the reason is derived from the numbers alone.

import AppKit
import Foundation

/// A macOS permission whose absence makes part of the screen unreadable.
enum ReadabilityPermission: String, Equatable {
    case accessibility
    case screenRecording

    var settingsPath: String {
        switch self {
        case .accessibility: return "System Settings ▸ Privacy & Security ▸ Accessibility"
        case .screenRecording: return "System Settings ▸ Privacy & Security ▸ Screen Recording"
        }
    }

    var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }
}

/// Which permissions are granted. A value, so tests inject it instead of asking the OS.
struct ReadabilityPermissions: Equatable {
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool

    static let allGranted = ReadabilityPermissions(
        accessibilityGranted: true, screenRecordingGranted: true)

    var missing: [ReadabilityPermission] {
        var out: [ReadabilityPermission] = []
        if !accessibilityGranted { out.append(.accessibility) }
        if !screenRecordingGranted { out.append(.screenRecording) }
        return out
    }

    /// The live state of this process. Production only; tests pass a value.
    static var current: ReadabilityPermissions {
        ReadabilityPermissions(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess())
    }
}

/// What one OCR pass over an image came to. The three outcomes used to collapse into an
/// empty string, so "the image has no text", "the image could not be decoded" and "the
/// recogniser errored" were all reported as "recognized zero text".
enum OCROutcome: Equatable {
    case recognized(String)
    /// The recogniser ran cleanly and found nothing: dark UI, a photo, or text too small.
    case nothingFound
    /// The recogniser could not run on this image.
    case failed(reason: String)

    var text: String {
        if case .recognized(let text) = self { return text }
        return ""
    }

    var characterCount: Int { text.count }

    /// One sentence for the model about this image, saying plainly which outcome it was.
    func summary(label: String) -> String {
        switch self {
        case .recognized(let text):
            return "\(label): OCR read \(text.count) characters of text."
        case .nothingFound:
            return "\(label): OCR ran fine and found no text in this image (for example dark "
                + "interface, a photo, or text too small). That is a finding, not a failure."
        case .failed(let reason):
            return "\(label): OCR could not run on this image (\(reason)). Whether it contains "
                + "text is unknown; do not say it has none."
        }
    }
}

struct ReadabilityFacts: Equatable {

    /// Why the content the user asked about is not available, when it is not.
    enum Reason: Equatable {
        case permissionMissing(ReadabilityPermission)
        case ocrFailed(String)
        case ocrFoundNothing
        case appExposesNoText
    }

    var appName: String
    var bundleId: String
    var windowTitle: String?
    /// Characters of text reached through accessibility: the selection, or a browser page.
    var axTextCharacterCount: Int
    var screenshotTaken: Bool = false
    /// Characters OCR found in the screenshot. Nil when none was taken or OCR did not run.
    var ocrCharacterCount: Int?
    var ocrFailureReason: String?
    var missingPermissions: [ReadabilityPermission] = []

    /// True when some text of the app's own content reached the model.
    var hasReadableText: Bool {
        axTextCharacterCount > 0 || (ocrCharacterCount ?? 0) > 0
    }

    private var trimmedTitle: String? {
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty ?? true) ? nil : title
    }

    /// Derived from the numbers alone, so it holds for any app. A missing Accessibility
    /// permission outranks everything: it is the one cause the user can fix in one place.
    var reason: Reason? {
        guard !hasReadableText else { return nil }
        if missingPermissions.contains(.accessibility) { return .permissionMissing(.accessibility) }
        if let failure = ocrFailureReason { return .ocrFailed(failure) }
        if screenshotTaken, !missingPermissions.contains(.screenRecording) { return .ocrFoundNothing }
        if missingPermissions.contains(.screenRecording) { return .permissionMissing(.screenRecording) }
        return .appExposesNoText
    }

    /// The facts block, as the model receives it.
    func block() -> String {
        let name = appName.isEmpty ? "the frontmost app" : appName
        var lines = ["## What I could and could not read (facts, read just now)"]
        lines.append(
            "- Frontmost app: \(name)\(bundleId.isEmpty ? "" : " (\(bundleId))")")
        if let title = trimmedTitle {
            lines.append("- Window title: \"\(title)\" (readable)")
        } else {
            lines.append("- Window title: not exposed")
        }
        // Only what is known: how much text reached DoraX. Whether the app could expose more
        // is not something the host can tell, so it is never claimed.
        lines.append(
            axTextCharacterCount > 0
                ? "- Text that reached DoraX: \(axTextCharacterCount) characters (selection or web page)"
                : "- Text that reached DoraX: none (DoraX reads only your selection or a web "
                    + "page; nothing like that is available from \(name))")
        if screenshotTaken {
            if let failure = ocrFailureReason {
                lines.append("- Screenshot: taken; OCR failed (\(failure))")
            } else {
                lines.append("- Screenshot: taken; OCR found \(ocrCharacterCount ?? 0) characters")
            }
        }
        if missingPermissions.isEmpty {
            lines.append("- Missing permission: none")
        } else {
            let named = missingPermissions
                .map { "\($0.displayName) (\($0.settingsPath))" }
                .joined(separator: ", ")
            lines.append("- Missing permission: \(named)")
        }
        lines.append(guidance())
        return lines.joined(separator: "\n")
    }

    /// The one-line verdict: what to tell the user, and what to suggest.
    func guidance() -> String {
        let name = appName.isEmpty ? "the frontmost app" : appName
        guard let reason else {
            return "Verdict: text from \(name) was read; answer from it and say which part "
                + "you used."
        }
        let seen = trimmedTitle.map { "only the window title \"\($0)\" is readable" }
            ?? "not even a window title is readable"
        switch reason {
        case .permissionMissing(let permission):
            return "Verdict: the content of \(name) is NOT readable because \(permission.displayName) "
                + "permission is missing; \(seen). Next step: grant \(permission.displayName) "
                + "in \(permission.settingsPath), or select the text and ask again, or paste it."
        case .ocrFailed(let failure):
            return "Verdict: the content of \(name) is NOT readable; \(seen), and screenshot OCR "
                + "failed (\(failure)). Next step: select the text and ask again, or paste it."
        case .ocrFoundNothing:
            return "Verdict: the content of \(name) is NOT available to me; \(seen), there is no "
                + "selection or web page, and screenshot OCR found no text. Next step: select "
                + "the text and ask again, or paste it."
        case .appExposesNoText:
            return "Verdict: the content of \(name) is NOT available to me; \(seen), because "
                + "DoraX only reads your selection or a web page and there is none right now. "
                + "Next step: select the text and ask again, or paste it."
        }
    }

    /// The instruction that goes with the facts, in the scoped-chat prompt. One text, used by
    /// the Dock and the Corner alike.
    static let instruction =
        "WHEN THE APP EXPOSES NOTHING. If the content the question asks about is not in the "
        + "context above, answer in your own words: name the app that is in front, say what IS "
        + "readable (the window title, a selection), give the reason from the \"What I could and "
        + "could not read\" block (nothing is selected and it is not a web page, a "
        + "permission is missing, or screenshot OCR found nothing or failed), and give one concrete next step "
        + "(select the text and ask again, paste it, or grant the named permission in System "
        + "Settings). Never offer to re-read, reload or try again unless something has "
        + "changed: a second read returns the same nothing. Say \"app\", not \"page\", unless "
        + "the app is a browser. \"My latest message\" means a message in this app; say which "
        + "app this chat is scoped to rather than guessing another."
}
