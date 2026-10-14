// DockEngine.swift
// Context-Dock
//
// The engine the Corner runs on, without the old launcher's window (#257).
//
// The old launcher (`LauncherView`) holds the Dock's search, its row builders, running a
// result and the app-scoped chat pipeline. Its window is never shown any more, and its state
// already lives outside SwiftUI (`LauncherEngineState`, E1). This owns a windowless instance
// of it that shares all of that state, starts it at launch, and feeds it what reaches it from
// outside — so none of it depends on a hidden window being alive (E2). E3 deletes the window
// and the screen code.

import AppKit
import Combine

@MainActor
final class DockEngine {
    static let shared = DockEngine()

    /// The launcher, as an engine: no window, the same shared state as the window's view.
    let core = LauncherView()
    private var sinks = Set<AnyCancellable>()
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let core = self.core
        let env = ContextDockEnvironment.shared
        let center = NotificationCenter.default

        env.userContextUpdates.sink { core.handleUserContextUpdate($0) }.store(in: &sinks)
        env.frontmostAppUpdates.sink { core.handleFrontmostAppUpdate($0) }.store(in: &sinks)

        let inputs: [(Notification.Name, (Notification) -> Void)] = [
            (.servicesOpenWithFiles, { core.handleServicesOpenWithFiles($0) }),
            (.servicesOpenWithText, { core.handleServicesOpenWithText($0) }),
            (AXMenuReader.scriptedMenusDidLoad, { core.handleScriptedMenusDidLoad($0) }),
            (.globalSearchIndexRebuildRequested, { core.handleGlobalSearchIndexRebuildRequest($0) }),
            // The Corner's App Chat and the Selection card ask on this engine's pipeline.
            (.appChatPromptSubmitted, { core.handleAppChatPromptSubmission($0) }),
            (.appChatPromptScopeChanged, { core.handleAppChatPromptScopeChange($0) }),
            (.appChatPromptNewChat, { _ in core.handleAppChatPromptNewChat() }),
            (.appChatPromptCancel, { _ in core.handleAppChatPromptCancel() }),
            (.appChatPromptPickAction, { core.handleAppChatPromptPickAction($0) }),
        ]
        for (name, handle) in inputs {
            center.publisher(for: name).sink { handle($0) }.store(in: &sinks)
        }

        core.startEngine()
    }
}
