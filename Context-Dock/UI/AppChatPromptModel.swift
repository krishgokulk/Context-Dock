// AppChatPromptModel.swift
// Context-Dock
//
// Ask the frontmost app something without leaving it: a hotkey puts an input field in the
// corner shell, alongside the clipboard and the shelf.
//
// The surface is built; what it does with the question is not. `submit()` deliberately
// reports that it sent nothing rather than pretending, so nothing downstream can mistake
// this for a working route.

import Combine
import Foundation

enum AppChatPromptPhase: Equatable {
    case hidden
    /// A half-typed question, parked as a badge.
    case mini
    /// The input field, focused and waiting.
    case prompt

    var isVisible: Bool { self != .hidden }
}

@MainActor
final class AppChatPromptModel: ObservableObject {
    /// How long an untouched prompt waits. Matches the clipboard card: nothing in this
    /// corner outlives the user's attention.
    static let idleDwell: TimeInterval = 5
    /// How long the badge holding an unfinished question waits after that.
    static let miniDwell: TimeInterval = 8

    @Published private(set) var phase: AppChatPromptPhase = .hidden
    @Published var query = ""
    /// The app the question is about, captured when the prompt opened — not read live,
    /// because opening the prompt is itself an app switch.
    @Published private(set) var appName = ""
    @Published private(set) var appBundleID = ""

    private(set) var isStandDownArmed = false
    private var standDownTask: Task<Void, Never>?

    var onPhaseChange: ((AppChatPromptPhase) -> Void)?

    // MARK: - Opening

    func summon(app name: String, bundleID: String = "") {
        appName = name
        appBundleID = bundleID
        set(.prompt)
        arm(after: Self.idleDwell)
    }

    /// Typing is attention: it puts the clock back rather than making the prompt immortal.
    func queryChanged() {
        guard phase.isVisible else { return }
        arm(after: Self.idleDwell)
    }

    func hoverBegan() {
        guard phase.isVisible else { return }
        set(.prompt)
        arm(after: Self.idleDwell)
    }

    // MARK: - Standing down

    /// One step smaller. A prompt the user has typed into holds a half-written question,
    /// which is worth more than a clean corner, so it becomes a badge before it is thrown
    /// away. An empty one has nothing to preserve and simply goes.
    func standDown() {
        switch phase {
        case .prompt:
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dismiss()
            } else {
                set(.mini)
                arm(after: Self.miniDwell)
            }
        case .mini:
            dismiss()
        case .hidden:
            break
        }
    }

    /// Switching Space is leaving, and the question was about an app on the screen the
    /// user walked away from.
    func userLeftTheSpace() {
        dismiss()
    }

    func dismiss() {
        cancel()
        query = ""
        set(.hidden)
    }

    // MARK: - Sending

    /// Not connected yet. Returns false so no caller can mistake this for a sent message.
    @discardableResult
    func submit() -> Bool {
        false
    }

    // MARK: - Timer

    private func arm(after delay: TimeInterval) {
        standDownTask?.cancel()
        isStandDownArmed = true
        standDownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.standDown()
        }
    }

    private func cancel() {
        standDownTask?.cancel()
        standDownTask = nil
        isStandDownArmed = false
    }

    private func set(_ next: AppChatPromptPhase) {
        guard phase != next else { return }
        phase = next
        onPhaseChange?(next)
    }
}
