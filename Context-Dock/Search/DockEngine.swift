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
    /// `.onChange` without a view: each reads a value and acts when it differs.
    private var watches: [() -> Void] = []
    private var watchPassScheduled = false

    private init() {}

    /// What the Corner reads off the engine by reference: the Selection card's rows and the
    /// Global results. They were set by the view's `.onAppear` at launch, test host included,
    /// and are just references — so they are set at launch whether or not `start()` runs.
    func register() {
        // The corner's Selection card asks the Dock's rows through this.
        SelectionActions.provider = core
        core.connectCornerGlobalResults()
    }

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
        startWatching()
    }

    // MARK: - Reacting to its own state

    /// The engine's reactions to its own state, which were `.onChange` hooks on the view
    /// (#257 E3). After any shared model announces a change, every value is read again on the
    /// next turn of the main loop — when the change has landed, as `.onChange` saw it — and
    /// the reaction runs for each one that differs.
    private func startWatching() {
        let core = self.core
        let state = LauncherEngineState.shared
        watch({ core.selectionModel.changeCount }) { _, _ in core.handleSelectionChange() }
        watch({ AppSettings.shared.enableFrontmostDetection }) { _, new in
            core.engineFrontmostDetectionChanged(new)
        }
        watch({ core.l2.chatMessages.count }) { _, _ in core.persistActiveL2DockSession() }
        watch({ core.l2.targetApp?.bundleId }) { _, _ in core.engineTargetAppChanged() }
        watch({ core.showContextInDock }) { _, new in core.engineShowContextInDockChanged(new) }
        watch({ core.currentContext.description }) { _, _ in core.engineContextChanged() }
        watch({ core.aiMode.isActive }) { _, new in core.handleAIModeActiveChange(new) }

        let changes: [ObservableObjectPublisher] = [
            state.objectWillChange, state.selectionModel.objectWillChange,
            state.launcherViewModel.objectWillChange, state.globalContextViewModel.objectWillChange,
            state.finderContext.objectWillChange, state.contextDockViewModel.objectWillChange,
            state.aiChatViewModel.objectWillChange, AppState.shared.objectWillChange,
            AppSettings.shared.objectWillChange,
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] _ in self?.scheduleWatchPass() }
            .store(in: &sinks)
    }

    private func watch<V: Equatable>(
        _ read: @escaping @MainActor () -> V, _ act: @escaping @MainActor (V, V) -> Void
    ) {
        var last = read()
        watches.append {
            let now = read()
            guard now != last else { return }
            let old = last
            last = now
            act(old, now)
        }
    }

    private func scheduleWatchPass() {
        guard !watchPassScheduled else { return }
        watchPassScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchPassScheduled = false
            for check in self.watches { check() }
        }
    }
}
