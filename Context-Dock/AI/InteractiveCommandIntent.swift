//
//  InteractiveCommandIntent.swift
//  Context-Dock
//
//  What an interactive Global Command should do when the model supplied no value.
//
//  The audit line that prompted this:
//
//      generalAI.execute.globalcmd.appearance | ok=true | "Appearance current value: true"
//
//  A command that exists to change something reported the switch's position instead of
//  moving it. The rule behind it was unconditional — an omitted value meant "read it" —
//  which is right for a question and wrong for an instruction. The executor could not
//  tell the two apart, because `AICapabilityExecutionRequest` carries inputs and context
//  and never intent. The same blindness as the write-intent guard, one layer down.
//
//  Reading stays the default. It is the safe answer and it never breaks anything; the
//  only thing that must not happen is "turn on dark mode" coming back as a value.
//

import Foundation

@MainActor
enum InteractiveCommandIntent {

    enum Fallback: Equatable {
        /// Report the value. What a question deserves.
        case readCurrentValue
        /// Run the command with this value.
        case set(String)
        /// Run it exactly as the model asked, with no value — there is nothing to read
        /// or flip, and the command's own guards decide what that means.
        case runAsIs
    }

    /// The vocabularies a system command's value script actually prints.
    private static let onWords: Set<String> = ["true", "1", "on", "yes", "enabled"]

    static func isOn(_ value: String) -> Bool {
        onWords.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The state the sentence names, when it names one. "Turn on dark mode" wants on
    /// whether or not it is already on — flipping there would switch it off, which is the
    /// opposite of what was asked.
    static func desiredState(in userRequest: String) -> String? {
        let text = userRequest.lowercased()
        let onPhrases = ["turn on", "switch on", "enable", "activate", "turn it on"]
        let offPhrases = ["turn off", "switch off", "disable", "deactivate", "turn it off"]
        // Longest match wins so "turn off" is never read as the "on" inside it.
        let onHit = onPhrases.compactMap { text.range(of: $0)?.lowerBound }.min()
        let offHit = offPhrases.compactMap { text.range(of: $0)?.lowerBound }.min()
        switch (onHit, offHit) {
        case (nil, nil): return nil
        case (_, nil): return "on"
        case (nil, _): return "off"
        case let (on?, off?): return on < off ? "on" : "off"
        }
    }

    static func fallback(userRequest: String, isToggle: Bool, current: String?) -> Fallback {
        let reading = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Nothing readable: there is no value to report and none to invert.
        guard !reading.isEmpty else { return .runAsIs }

        // An absent request means an older caller that never passed one. Read; never infer
        // a mutation from an absence.
        let request = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty,
            GeneralAIActionResolver.shared.requestsChange(request)
        else { return .readCurrentValue }

        guard isToggle else { return .runAsIs }
        if let wanted = desiredState(in: request) { return .set(wanted) }
        // "Toggle" and "switch" name no state, so the opposite of now is the only reading.
        return .set(isOn(reading) ? "off" : "on")
    }
}
