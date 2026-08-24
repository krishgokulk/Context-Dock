// GeneralChatWindowModel.swift
// Context-Dock
//
// Conversation state for the standalone General Chat window.
//
// It is the SAME conversation the result sheet shows: both sides store to
// `GeneralAIChatConversationStore`, and both use `AIChatMessage`, so a chat
// started in the sheet continues in the window and vice versa. The window has its
// own object only because the sheet's copy lives on LauncherView's @State, which
// cannot be reached from another window.

import AppKit
import Combine
import OSLog
import Foundation
import SwiftUI

@MainActor
final class GeneralChatWindowModel: ObservableObject {
    static let shared = GeneralChatWindowModel()

    @Published var messages: [AIChatMessage] = []
    @Published var input: String = ""
    /// Threads with an answer in flight, by storage key. Per thread rather than one flag
    /// for the window: a global flag made a pending answer freeze the whole hub — the
    /// sidebar stopped switching, so clicking tailscale left the previous thread on
    /// screen and looked like tailscale's conversation had become someone else's.
    @Published private(set) var sendingScopeKeys: Set<String> = []
    /// Live human-readable stage per thread. Unlike a generic spinner, this tells the user
    /// whether DoraX is reading a page, extracting it, choosing a route, or verifying work.
    @Published private(set) var statusByScopeKey: [String: String] = [:]
    /// Observable lifecycle events accumulated for each in-flight turn.
    @Published private(set) var progressByScopeKey: [String: [String]] = [:]
    /// Files on the next message, shown as chips once it is sent.
    @Published var attachments: [URL] = []
    /// Apps the answer should be about — the composer's app picker. Several at once
    /// is the point: a chat can be scoped to Reminders and Safari together.
    @Published var attachedAppNames: [String] = []
    /// Which apps were attached when each message was sent, so the transcript keeps
    /// showing what a question was asked *about* after the scope changes. In memory
    /// only — the stored conversation format has no field for it, and a reopened
    /// window showing today's scope on last week's question would be a lie.
    @Published var messageApps: [UUID: [String]] = [:]

    /// What is highlighted in Finder right now, filtered to what this thread is about.
    ///
    /// A file chat that ignores the selection makes the user describe what they are already
    /// pointing at. Read from Finder rather than from the AX snapshot so it is current
    /// while this window — not Finder — is the key window.
    @Published private(set) var finderSelection: [URL] = []
    /// The pill's "×": this thread stops following the selection until the user picks
    /// something else. Per thread, because ignoring it in one is not a statement about
    /// the others.
    @Published var ignoredSelectionKeys: Set<String> = []

    /// The conversation currently shown. The window is a hub: one thread per app or CLI tool,
    /// each kept whether or not that app is running, plus the unscoped one the result sheet
    /// shares. Combined chat is unchanged — it is what attachedAppNames does *within* a
    /// session, so a thread can still span Reminders and Safari.
    @Published private(set) var activeScope: GeneralChatScope = .general
    /// Sidebar contents, most recently used first.
    @Published private(set) var sessions: [GeneralChatSession] = GeneralChatSessionStore.index()

    /// In-flight answer per thread, so one thread's send is never cancelled by moving to
    /// another.
    private var sendTasks: [String: Task<Void, Never>] = [:]

    /// Turn markers for the window. Paired with AppScopedChatService's stages, these say
    /// whether a stall is in this model or in the request it made.
    private static let log = Logger(
        subsystem: "com.krishgokul.ContextDock", category: "ChatWindow")

    var isEmpty: Bool { messages.isEmpty }

    /// True when this message is the first of its calendar day, so the transcript can
    /// date it.
    func startsNewDay(at index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        return !Calendar.current.isDate(
            messages[index].timestamp, inSameDayAs: messages[index - 1].timestamp)
    }

    /// True when the thread on screen is waiting for an answer. Another thread's pending
    /// answer must not spin this one.
    var isSending: Bool { sendingScopeKeys.contains(activeScope.storageKey) }
    var activeStatus: String? { statusByScopeKey[activeScope.storageKey] }
    var activeProgress: [String] { progressByScopeKey[activeScope.storageKey] ?? [] }

    /// Pull in whatever the result sheet has said since this window was last open.
    func reloadFromStore() {
        guard !isSending else { return }
        // Threads the dock created and the window has never seen. Done on every open so a
        // conversation held in the dock this morning is in the sidebar this afternoon.
        GeneralChatSessionStore.discoverDockThreads()
        // Reloading is only unsafe for a thread mid-answer; every other thread is on disk.
        messages = GeneralChatSessionStore.load(scope: activeScope)
        attachedAppNames = GeneralChatSessionStore.loadAttachedApps(scope: activeScope)
        sessions = GeneralChatSessionStore.index()
    }

    /// Shows the conversation for a scope, creating it on first use.
    ///
    /// Switching persists what is on screen first, so moving between threads cannot lose the
    /// one being left. A send in flight is left alone: cancelling someone's answer because
    /// they clicked another row would be its own bug.
    /// - Parameter seed: the conversation being handed over from the dock. A thread opened
    ///   from a scope must show what the user was already reading — arriving at an empty
    ///   window while the dock still held the transcript is not a handover, it is a second
    ///   conversation. Applied only when the thread is empty, so reopening never overwrites
    ///   history with whatever the dock happens to be showing.
    /// A file the window should open on, set just before a handoff from the dock.
    ///
    /// The dock is a strip. Reading a document or an image in it means the conversation is
    /// gone, and closing the document to reply means the document is gone. Handing the file
    /// to the window puts both on screen at once, which is the arrangement the work
    /// actually needs.
    @Published var pendingPreviewFile: URL?

    func openSession(_ scope: GeneralChatScope, title: String, seed: [AIChatMessage] = []) {
        guard scope != activeScope else {
            adoptSeedIfEmpty(seed, scope: scope, title: title)
            sessions = GeneralChatSessionStore.index()
            return
        }
        // Persist what is leaving the screen, but leave its in-flight answer running: it
        // belongs to the thread it was asked in and will be written there whether or not
        // that thread is still the visible one.
        if !isSending { persist() }
        activeScope = scope
        messages = GeneralChatSessionStore.load(scope: scope)
        input = ""
        attachments = []
        // Each thread carries its own extra apps; they are reloaded rather than inherited
        // from the thread being left.
        attachedAppNames = GeneralChatSessionStore.loadAttachedApps(scope: scope)
        adoptSeedIfEmpty(seed, scope: scope, title: title)
        GeneralChatSessionStore.upsert(
            scope: scope, title: title, messageCount: messages.count)
        sessions = GeneralChatSessionStore.index()
    }

    private func adoptSeedIfEmpty(
        _ seed: [AIChatMessage], scope: GeneralChatScope, title: String
    ) {
        guard messages.isEmpty, !seed.isEmpty else { return }
        messages = seed
        GeneralChatSessionStore.save(seed, scope: scope, title: title)
    }

    func closeSession(_ scope: GeneralChatScope) {
        GeneralChatSessionStore.remove(scope: scope)
        if scope == activeScope { openGeneralSession() }
        sessions = GeneralChatSessionStore.index()
    }

    func openGeneralSession() {
        activeScope = .general
        messages = GeneralChatSessionStore.load(scope: .general)
        attachedAppNames = GeneralChatSessionStore.loadAttachedApps(scope: .general)
        sessions = GeneralChatSessionStore.index()
    }

    /// Preserve the shared General transcript before replacing it with a clean chat.
    private func archiveGeneralConversationIfNeeded() {
        guard activeScope == .general, !messages.isEmpty else { return }
        let archivedScope = GeneralChatScope.thread(id: UUID().uuidString.lowercased())
        let firstQuestion = messages.first(where: { $0.role == .user })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = firstQuestion.isEmpty ? "New chat" : String(firstQuestion.prefix(52))
        GeneralChatSessionStore.save(messages, scope: archivedScope, title: title)
        GeneralChatSessionStore.saveAttachedApps(attachedAppNames, scope: archivedScope)
    }

    /// True when the scope's app is running (or its CLI binary is installed) — the
    /// sidebar dims what is not currently there without hiding it.
    func isScopeLive(_ scope: GeneralChatScope) -> Bool {
        switch scope {
        case .general, .thread:
            return true
        case .app(let bundleId):
            return !NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId).isEmpty
        case .cli(let command):
            return TerminalPackageManager.shared.packages.contains {
                $0.command.caseInsensitiveCompare(command) == .orderedSame && $0.isInstalled
            }
        case .folder(let path):
            // Dimmed rather than dropped when the folder is gone: the conversation about
            // it is still worth reading, and a row that vanishes looks like data loss.
            return FileManager.default.fileExists(atPath: path)
        }
    }

    /// Heading for the side panel: the thread's own name, not a generic "Details".
    var activeScopeTitle: String {
        switch activeScope {
        case .general, .thread: return "Details"
        case .cli(let command): return command
        case .folder(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .app: return activeScopeAppName ?? "Details"
        }
    }

    /// Bundle id of the thread's app, when it has one — the side panel's "add tools"
    /// deep link needs it, and a CLI thread has no adapter to open.
    var activeScopeBundleId: String? {
        if case .app(let bundleId) = activeScope { return bundleId }
        return nil
    }

    var activeScopeSymbol: String {
        switch activeScope {
        case .general, .thread: return "bubble.left.and.bubble.right"
        case .cli: return "terminal"
        case .folder: return "folder"
        case .app: return "app.dashed"
        }
    }

    /// What the visible thread can reach — the same inventory its prompt is built from.
    var activeScopeInventory: ScopeInventory {
        switch activeScope {
        case .general, .thread:
            return ScopeInventory(
                subtitle: "Unscoped chat. Attach an app to give it that app's tools.",
                groups: [])
        case .cli(let command):
            return ScopeInventory.cli(command: command)
        case .folder(let path):
            return ScopeInventory.folder(path: path)
        case .app(let bundleId):
            return ScopeInventory.app(
                bundleId: bundleId, appName: activeScopeAppName ?? bundleId)
        }
    }

    /// Title for the active thread, used when persisting.
    var activeTitle: String {
        switch activeScope {
        case .general: return "General"
        case .thread:
            return sessions.first { $0.scope == activeScope }?.title ?? "Chat"
        case .cli(let command): return command
        case .folder(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .app(let bundleId):
            return sessions.first { $0.scope == activeScope }?.title ?? bundleId
        }
    }

    // MARK: - Streaming

    /// The bubble the provider is writing into, when one is on screen.
    ///
    /// A turn used to show "Thinking…" for its whole length — twenty seconds of nothing on a
    /// scoped question that runs two tools, with no way to tell a working turn from a stuck
    /// one. The text now lands as it is written, in a real message that the finished answer
    /// replaces.
    private var streamingMessageID: UUID?
    private var streamingScopeKey: String?

    /// Applies one streaming event to the visible thread.
    ///
    /// Only the visible thread: a partial answer written into a thread nobody is looking at
    /// would be replaced by the final one anyway, and would have to be unpicked if the user
    /// switched to it mid-turn.
    func receiveStream(_ event: AIProviderStreamEvent, scope: GeneralChatScope) {
        guard scope == activeScope, sendingScopeKeys.contains(scope.storageKey) else { return }
        switch event {
        case .text(let fragment):
            guard !fragment.isEmpty else { return }
            if let id = streamingMessageID,
                streamingScopeKey == scope.storageKey,
                let index = messages.firstIndex(where: { $0.id == id })
            {
                messages[index] = AIChatMessage(
                    id: id, role: .assistant, content: messages[index].content + fragment)
            } else {
                let message = AIChatMessage(role: .assistant, content: fragment)
                streamingMessageID = message.id
                streamingScopeKey = scope.storageKey
                messages.append(message)
            }

        case .toolCallStarted(let name):
            // Everything written so far was the model narrating its way towards a tool. The
            // answer comes from the round after the tool returns, so this text is not a
            // draft of it — leaving it on screen would put a stray half-sentence above the
            // real reply.
            clearStreamingMessage()
            // The step itself is shown. A turn that reads a page, checks a file and then
            // answers was indistinguishable from one that sat still for twenty seconds: the
            // work was real, the transcript said nothing about it, and the user is the one
            // deciding whether to trust the answer. These rows are removed when the answer
            // lands — the receipts on the message are the durable record.
            appendStepRow(ScopedToolStep.label(for: name))
        }
    }

    /// Steps shown while the turn is working, by message id, so they can be cleared when it
    /// finishes. Transient by design: what ran durably is on the answer's receipts.
    private var stepMessageIDs: [UUID] = []

    private func appendStepRow(_ label: String) {
        let message = AIChatMessage(role: .tool, content: label)
        stepMessageIDs.append(message.id)
        messages.append(message)
    }

    private func clearStepRows() {
        guard !stepMessageIDs.isEmpty else { return }
        let ids = Set(stepMessageIDs)
        messages.removeAll { ids.contains($0.id) }
        stepMessageIDs.removeAll()
    }

    /// Drops the in-flight bubble. Called when a tool interrupts the writing and again
    /// before the finished answer is filed, so the two never appear at once.
    private func clearStreamingMessage() {
        guard let id = streamingMessageID else { return }
        messages.removeAll { $0.id == id }
        streamingMessageID = nil
        streamingScopeKey = nil
    }

    /// Files an answer, carrying whatever it came with: the enable button, the route
    /// choices, the console receipt.
    private func apply(
        _ answer: AppScopedChatService.Answer, to scope: GeneralChatScope, title: String
    ) {
        // The log itself is written by whoever ran the work; the window only decides
        // whether the panel showing it should be visible.
        if answer.consoleOutput != nil
            || !ChatConsoleLog.shared.entries(for: scope).isEmpty
        {
            GeneralChatWindowChromeState.shared.showBottomPanel()
        }
        // Files the answer named, as rows with Open / Show in Finder — the same treatment
        // the general chat already gives them, now that a scoped answer can carry them.
        let named = answer.files.isEmpty
            ? AppScopedChatService.mentionedFiles(in: answer.text)
            : answer.files
        let liveProgress = progressByScopeKey[scope.storageKey] ?? []
        var durableTrace: [String] = []
        for step in liveProgress + answer.trace + ["Task complete"] {
            if !durableTrace.contains(where: {
                $0.caseInsensitiveCompare(step) == .orderedSame
            }) {
                durableTrace.append(step)
            }
        }
        deliver(
            AIChatMessage(
                role: .assistant, content: answer.text,
                recentFiles: named.map { RecentFileAction(url: $0) },
                mcpToolsRan: answer.toolChips,
                evidenceReceipts: answer.evidenceReceipts,
                subjectiveEvaluation: answer.subjectiveEvaluation,
                enableAppRequest: answer.enableApp,
                trace: durableTrace,
                actionChoices: answer.routeChoices),
            to: scope, title: title)
    }

    /// The user picked how to carry out the last request. Runs that route, remembers the
    /// choice for next time, and answers from what it produced.
    func pickRoute(_ choice: ActionChoice) {
        guard !isSending else { return }
        let question = lastUserQuestion
        let scope = activeScope
        let title = activeTitle
        let key = scope.storageKey
        let history: [ChatMessage] = messages.compactMap { message in
            switch message.role {
            case .user: return ChatMessage(role: .user, content: message.content)
            case .assistant: return ChatMessage(role: .assistant, content: message.content)
            case .tool, .approval: return nil
            }
        }

        sendingScopeKeys.insert(key)
        progressByScopeKey[key] = ["Understanding your request…"]
        sendTasks[key] = Task { [weak self] in
            let answer = await AppScopedChatService.runChosenRoute(
                choice.id, query: question, history: history, scope: scope)
            await MainActor.run { self?.apply(answer, to: scope, title: title) }
        }
    }

    /// The question the route choice belongs to.
    private var lastUserQuestion: String {
        messages.last { $0.role == .user }?.content ?? ""
    }

    /// "Enable <app> for this chat": attach the app, then ask the question again so the
    /// user gets an answer rather than a granted permission and a dead end.
    func enableApp(_ request: EnableAppRequest) {
        // Approving an app at the gate is how a workspace gets built: "launch Safari and
        // Notes" asks for both, and saying yes should land the user in the Safari + Notes
        // conversation with the question re-asked there. Appending the name in place left
        // the answer in General, where the two apps were in scope but the conversation
        // belonged to nothing.
        //
        // Matched case-insensitively against the name the gate reported, so the two sides
        // agree even when the app is not running and the installed-apps cache is cold.
        let already = currentMembership.contains {
            $0.caseInsensitiveCompare(request.name) == .orderedSame
        }
        if !already {
            openCombination(currentMembership + [request.name])
        }
        // Say what just changed, before the answer arrives.
        //
        // Enabling an app silently re-ran the question, so the next thing on screen was an
        // answer with no account of why it could suddenly see the user's messages. The
        // permission the user just granted, and the tools it brought with it, are the most
        // important thing in the conversation at that moment — and the one thing they were
        // never shown.
        deliver(
            AIChatMessage(role: .tool, content: Self.scopeSummary(for: request)),
            to: activeScope, title: activeTitle)
        input = request.query
        send()
    }

    /// What this conversation can now reach, in the user's terms: the app, and what came
    /// with it. Counted from the adapter rather than described in general, so it is true of
    /// their setup rather than of the feature.
    static func scopeSummary(for request: EnableAppRequest) -> String {
        var parts: [String] = []
        if let adapter = AppAdapterManager.shared.adapter(for: request.bundleId) {
            let actions = adapter.actions.filter { $0.type != .aiPrompt }.count
            if actions > 0 { parts.append("\(actions) action\(actions == 1 ? "" : "s")") }
        }
        let skills = SkillStore.shared.skills(for: request.bundleId).filter(\.isEnabled).count
        if skills > 0 { parts.append("\(skills) skill\(skills == 1 ? "" : "s")") }
        let capabilities = CapabilityRegistry.shared.all.filter {
            $0.appBundleID?.caseInsensitiveCompare(request.bundleId) == .orderedSame
        }.count
        if capabilities > 0 { parts.append("\(capabilities) built-in tools") }
        let clis = ScopedGroundingBlocks.runnableCommandBinaries(forBundleId: request.bundleId)
        if !clis.isEmpty { parts.append("\(clis.count) CLI tool\(clis.count == 1 ? "" : "s")") }
        let menus = AppMenuCapabilityCache.shared.menuItems(
            bundleIdentifier: request.bundleId, appName: request.name, query: "",
            maxResults: 60
        ).filter(\.isLeaf).count
        if menus > 0 { parts.append("\(menus) menu commands") }

        let inventory = parts.isEmpty
            ? "no tools linked yet — answers will come from what DoraX can read directly"
            : parts.joined(separator: " · ")
        return "\(request.name) is now in this chat — \(inventory). This question is answered "
            + "from \(request.name) only; other apps stay out unless you add them."
    }

    /// The trash in the composer clears the thread you are reading, and only that one —
    /// a Reminders thread cleared must not touch Calendar's, and must not be confused with
    /// "New chat", which moves you somewhere else.
    func clearActiveThread() {
        cancel()
        messages = []
        messageApps = [:]
        attachments = []
        if activeScope == .general {
            GeneralAIChatConversationStore.clear()
        } else {
            GeneralChatSessionStore.save([], scope: activeScope, title: activeTitle)
            // The dock's next visit starts clean too, rather than replaying what was
            // just deleted.
            if let panelKey = GeneralChatSessionStore.dockPanelKey(activeScope) {
                AppPanelChatStore.shared.beginSession(for: panelKey)
            }
        }
        sessions = GeneralChatSessionStore.index()
    }

    /// "New chat" from a scoped thread means "back to the unscoped one" — without this
    /// there is no way back to General once an app thread is open, and the button would
    /// instead wipe the app thread the user is reading.
    func newChat() {
        // A combined thread's members are the thread. Clearing them would leave a thread
        // named after two apps that is about neither, so New chat here empties the
        // transcript and keeps the pairing — the same rule as General.
        if activeScope.isWorkspace {
            cancel()
            messages = []
            messageApps = [:]
            input = ""
            attachments = []
            GeneralChatSessionStore.save(
                [], scope: activeScope, title: attachedAppNames.joined(separator: " + "))
            sessions = GeneralChatSessionStore.index()
            return
        }
        guard activeScope == .general else {
            openGeneralSession()
            newChat()
            return
        }
        cancel()
        archiveGeneralConversationIfNeeded()
        messages = []
        messageApps = [:]
        input = ""
        attachments = []
        // The combined set survives. Attaching Safari and Notes together is a working
        // arrangement the user built — a workflow they return to across many questions —
        // and clearing it on New chat threw that away every time they wanted a fresh
        // question about the same apps. New chat empties the conversation, not the setup.
        GeneralChatSessionStore.saveAttachedApps(attachedAppNames, scope: activeScope)
        GeneralAIChatConversationStore.clear()
        GeneralChatSessionStore.upsert(scope: .general, title: "General", messageCount: 0)
        sessions = GeneralChatSessionStore.index()
    }

    func cancel() {
        let key = activeScope.storageKey
        sendTasks[key]?.cancel()
        sendTasks[key] = nil
        sendingScopeKeys.remove(key)
    }

    /// Same five ways to attach the dock offers — one implementation, in
    /// ChatAttachmentCapture, so the "+" means the same thing on both surfaces.
    func attachFiles(imagesOnly: Bool = false) {
        let picked = ChatAttachmentCapture.pickFiles(imagesOnly: imagesOnly)
        attachments.append(contentsOf: picked.filter { !attachments.contains($0) })
    }

    func captureScreenshot(interactive: Bool, windowFirst: Bool = false) {
        ChatAttachmentCapture.captureScreenshot(
            interactive: interactive, windowFirst: windowFirst
        ) { [weak self] url in
            guard let self, !self.attachments.contains(url) else { return }
            self.attachments.append(url)
        }
    }

    /// OCR'd screen text lands in the composer, where the user can see what was read
    /// before sending it — a capture that silently became context would be worse.
    func captureScreenText() {
        ChatAttachmentCapture.captureScreenText { [weak self] text in
            guard let self else { return }
            let existing = self.input.trimmingCharacters(in: .whitespacesAndNewlines)
            self.input = existing.isEmpty ? text : existing + "\n\n" + text
        }
    }

    /// Stable per membership, so the same set of apps always returns to the same
    /// conversation rather than starting a new one each time.
    static func combinedThreadID(for names: [String]) -> String {
        "combined-" + names.map { $0.lowercased() }.sorted().joined(separator: "+")
    }

    /// The apps this conversation is currently about.
    var currentMembership: [String] {
        if activeScope.isWorkspace { return attachedAppNames }
        if let scopeApp = activeScopeAppName {
            return [scopeApp] + attachedAppNames.filter { $0 != scopeApp }
        }
        return attachedAppNames
    }

    /// Opens the conversation that belongs to exactly this set of apps.
    ///
    /// Membership *is* the identity of a combined chat. Safari + Notes is one workspace;
    /// adding Calendar does not grow it into a three-app version of itself, it moves to the
    /// Safari + Notes + Calendar workspace, which has its own history and its own tools.
    /// Coming back to the pair returns to the pair's conversation with everything still in
    /// it — which is the whole reason to key a workspace by who is in it.
    func openCombination(_ names: [String]) {
        var members: [String] = []
        for name in names where !members.contains(name) { members.append(name) }

        switch members.count {
        case 0:
            openGeneralSession()
            GeneralChatWindowChromeState.shared.mode = .chat
        case 1:
            // One app is that app's own thread, not a combination of one — and an app
            // thread is a chat, so the window goes back to Chat with it.
            guard let bundleId = Self.bundleId(forAppNamed: members[0]) else { return }
            openSession(.app(bundleId: bundleId), title: members[0])
            attachedAppNames = []
            GeneralChatSessionStore.saveAttachedApps([], scope: activeScope)
            GeneralChatWindowChromeState.shared.mode = .chat
        default:
            let combined = GeneralChatScope.thread(id: Self.combinedThreadID(for: members))
            openSession(combined, title: members.joined(separator: " + "))
            attachedAppNames = members
            GeneralChatSessionStore.saveAttachedApps(members, scope: combined)
            // A workspace lives in Work. Building one and leaving the user in Chat would
            // put the conversation somewhere its own list does not show it.
            GeneralChatWindowChromeState.shared.mode = .work
        }
        sessions = GeneralChatSessionStore.index()
    }

    func attachApp(_ name: String) {
        guard !attachedAppNames.contains(name) else { return }
        // Picking an app in General chat means "talk to this app" — so it becomes that
        // app's own thread, listed and persisted like the ones handed over from the dock.
        // Held only in attachedAppNames it was a scope on an unsaved conversation, which
        // is why "/calendar" vanished on the next New chat.
        //
        // Mid-thread too, not only on an empty one: "/finder" after three questions asked
        // for a Finder chat just as plainly, and answering it with a loose name in the
        // composer left the user in General with no Finder tools and no row to return to.
        // The General thread is persisted on the way out and stays in the sidebar; the app
        // thread opens clean rather than inheriting a copy of a conversation that is
        // already readable one row above.
        if activeScope.isGeneralChat, let bundleId = Self.bundleId(forAppNamed: name) {
            openSession(.app(bundleId: bundleId), title: name)
            return
        }

        openCombination(currentMembership + [name])
    }

    // MARK: - Finder selection

    /// The selection, narrowed to what this thread may speak for.
    ///
    /// A folder thread promises the folder: a file selected somewhere else is not "these",
    /// and quietly widening the scope to wherever the user last clicked would break the
    /// one guarantee the thread makes. A Finder thread has no such boundary — the
    /// selection is the whole point of it.
    var selectionInScope: [URL] {
        guard !ignoredSelectionKeys.contains(ignoreKey) else { return [] }
        switch activeScope {
        case .folder(let path):
            let root = path.hasSuffix("/") ? path : path + "/"
            return finderSelection.filter { $0.path == path || $0.path.hasPrefix(root) }
        case .app(let bundleId) where bundleId == ChatAppDirectory.finderBundleID:
            return finderSelection
        default:
            return []
        }
    }

    /// One line for the pill: names when there are few, a count when there are many.
    var selectionSummary: String {
        let selection = selectionInScope
        switch selection.count {
        case 0: return ""
        case 1: return selection[0].lastPathComponent
        case 2, 3: return selection.map(\.lastPathComponent).joined(separator: ", ")
        default: return "\(selection.count) items selected"
        }
    }

    /// Re-reads Finder's selection. Cheap and non-blocking — ContextDetector answers from a
    /// short-lived cache and refreshes behind it, so calling this on window focus, on
    /// thread switch and before a send costs one Apple event, not three.
    func refreshFinderSelection() {
        // Only threads that can act on files ask Finder anything.
        let readsFiles: Bool = {
            switch activeScope {
            case .folder: return true
            case .app(let bundleId): return bundleId == ChatAppDirectory.finderBundleID
            default: return false
            }
        }()
        guard readsFiles else {
            if !finderSelection.isEmpty { finderSelection = [] }
            return
        }
        ContextDetector.shared.finderSelectedFilesAsync { [weak self] urls in
            guard let self, self.finderSelection != urls else { return }
            self.finderSelection = urls
        }
    }

    /// Identifies a thread AND the selection it was shown, so dismissing the pill silences
    /// this selection here — not the feature. Highlight something else and it comes back,
    /// which is what the "×" means to someone who has just changed their mind about which
    /// files they want.
    private var ignoreKey: String {
        let fingerprint = finderSelection.map(\.path).sorted().joined(separator: "|")
        return "\(activeScope.storageKey)##\(fingerprint)"
    }

    func ignoreSelectionForActiveThread() {
        ignoredSelectionKeys.insert(ignoreKey)
    }

    /// Asks for a directory and opens it as its own thread.
    ///
    /// A folder attached as a file would be one more chip on one more question. As a
    /// thread it is somewhere to come back to: the same directory, the same history, the
    /// same tools, whether or not Finder is open on it.
    func attachFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Chat"
        panel.message = "Pick a folder to chat with"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolderSession(url)
    }

    /// Opens (or returns to) the thread for a directory. Symlinks and aliases are resolved
    /// first so the same folder reached two ways is one thread, not two.
    func openFolderSession(_ url: URL) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return }
        openSession(.folder(path: path), title: URL(fileURLWithPath: path).lastPathComponent)
    }

    func removeApp(_ name: String) {
        // Dropping a member is a move to a different workspace, not an edit to this one.
        // Editing in place would rewrite Safari + Notes into Safari and take the pair's
        // history with it, leaving no way back to a conversation the user built.
        let remaining = currentMembership.filter { $0 != name }
        guard remaining.count != currentMembership.count else { return }
        if activeScope.isWorkspace {
            openCombination(remaining)
            return
        }
        attachedAppNames.removeAll { $0 == name }
        GeneralChatSessionStore.saveAttachedApps(attachedAppNames, scope: activeScope)
    }

    /// Bundle id for an app the user picked by name, running or merely installed.
    private static func bundleId(forAppNamed name: String) -> String? {
        // The directory the pickers offer from, so anything listed can also be scoped —
        // an app the user could pick but not resolve would attach as a name and silently
        // lose its tools.
        if let fromDirectory = ChatAppDirectory.bundleId(forName: name) {
            return fromDirectory
        }
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == name })?.bundleIdentifier
        {
            return running
        }
        return InstalledApplicationsCatalog.cachedInstalledApps()
            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.bundleId
    }

    /// The app this thread is about, when it is an app thread. Shown in the composer
    /// beside any extra attached apps so the scope is visible while typing.
    var activeScopeAppName: String? {
        guard case .app = activeScope else { return nil }
        return sessions.first { $0.scope == activeScope }?.title
    }

    /// Every app in play for the visible thread: the thread's own app first, then the
    /// extra ones that make it a combined chat.
    var scopeAppNames: [String] {
        guard let scopeApp = activeScopeAppName else { return attachedAppNames }
        return [scopeApp] + attachedAppNames.filter { $0 != scopeApp }
    }

    func send() {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard !isSending else {
            Self.log.notice(
                "send ignored: \(self.activeScope.storageKey, privacy: .public) already sending")
            return
        }

        let settings = AppSettings.shared
        let provider = settings.selectedAIProvider

        let history: [ChatMessage] = messages.compactMap { message in
            switch message.role {
            case .user: return ChatMessage(role: .user, content: message.content)
            case .assistant: return ChatMessage(role: .assistant, content: message.content)
            case .tool, .approval: return nil
            }
        }

        let sentAttachments = attachments
        let userMessage = AIChatMessage(
            role: .user, content: query, attachments: sentAttachments)
        if !attachedAppNames.isEmpty {
            messageApps[userMessage.id] = attachedAppNames
        }
        messages.append(userMessage)
        input = ""
        attachments = []
        persist()

        if provider.requiresAPIKey && !settings.isProviderConfigured(provider) {
            messages.append(
                AIChatMessage(
                    role: .assistant,
                    content:
                        "\(provider.shortName) has no API key yet. Add one in Settings → AI Provider, "
                        + "or switch to On-Device Intelligence.",
                    isError: true))
            persist()
            return
        }

        let rawKey = provider.requiresAPIKey ? settings.getAPIKey(for: provider) : ""
        let apiKey: String? = rawKey.isEmpty ? nil : rawKey
        // An attached app makes this an app question, so the provider gets the same
        // app-focused context the sheet builds for one.
        let context: UserContext = {
            // An app thread is about that app whether or not anything extra is attached.
            if case .app(let bundleId) = activeScope {
                return .appFocused(name: activeScopeAppName ?? bundleId, bundleID: bundleId)
            }
            guard let name = attachedAppNames.first else { return .none }
            let bundleID = Self.bundleId(forAppNamed: name) ?? ""
            return .appFocused(name: name, bundleID: bundleID)
        }()
        let providerAttachments = sentAttachments.map(AIAttachment.inferred(from:))

        // The thread this question was asked in. The answer belongs to it even if the
        // user has moved to another thread by the time it arrives — appending to whatever
        // happens to be on screen is how tailscale's window ends up holding Calendar's
        // conversation.
        let sendScope = activeScope
        let sendTitle = activeTitle
        let sendKey = sendScope.storageKey

        let scopeAppName = activeScopeAppName ?? sendTitle
        let extraApps = attachedAppNames
        // What was highlighted when the question was asked. Captured here rather than read
        // inside the request: the user may click elsewhere while the answer is in flight,
        // and "these" has to mean what it meant when they typed it.
        let selection = selectionInScope

        Self.log.notice(
            "turn start scope=\(sendKey, privacy: .public) provider=\(provider.rawValue, privacy: .public)")
        sendingScopeKeys.insert(sendKey)
        progressByScopeKey[sendKey] = ["Understanding your request…"]
        sendTasks[sendKey] = Task { [weak self] in
            // A provider or tool loop that never returns must still end the turn. Without
            // this the thread sat on "Thinking…" with no way back except relaunching.
            let watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000_000)  // 150s
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.sendingScopeKeys.contains(sendKey) else { return }
                    self.deliver(
                        AIChatMessage(
                            role: .assistant,
                            content:
                                "That took too long and was stopped. It usually means a linked "
                                + "MCP server or CLI tool never answered — try again, or check "
                                + "the tool in Settings → App Adapters.",
                            isError: true),
                        to: sendScope, title: sendTitle)
                }
            }
            defer { watchdog.cancel() }
            do {
                // Every thread — scoped or not — goes through the one path, so the window
                // grounds, executes and sanitises the way the dock's chat does instead of
                // asking the model to answer from memory.
                let answer = try await AppScopedChatService.send(
                    scope: sendScope,
                    appName: scopeAppName,
                    query: query,
                    history: history,
                    attachments: sentAttachments,
                    extraAppNames: extraApps,
                    finderSelection: selection,
                    onStream: { event in
                        Task { @MainActor [weak self] in
                            self?.receiveStream(event, scope: sendScope)
                        }
                    },
                    onStatus: { status in
                        Task { @MainActor [weak self] in
                            guard self?.sendingScopeKeys.contains(sendKey) == true else { return }
                            self?.recordProgress(status, for: sendKey)
                        }
                    })
                guard !Task.isCancelled else {
                    await MainActor.run { self?.finishSending(sendKey) }
                    return
                }
                await MainActor.run {
                    self?.apply(answer, to: sendScope, title: sendTitle)
                }
            } catch {
                guard !Task.isCancelled else {
                    await MainActor.run { self?.finishSending(sendKey) }
                    return
                }
                await MainActor.run {
                    self?.deliver(
                        AIChatMessage(
                            role: .assistant,
                            content: "Error: \(error.localizedDescription)",
                            isError: true),
                        to: sendScope, title: sendTitle)
                }
            }
        }
    }

    /// Files an answer into the thread it was asked in. When that thread is on screen the
    /// visible transcript grows; when it is not, the answer is written straight to that
    /// thread's stored conversation, so switching away mid-answer loses nothing and
    /// contaminates nothing.
    /// Ends a thread's turn without adding a message. A cancelled task used to return
    /// straight out of both branches, leaving the thread marked as sending forever: the
    /// spinner never stopped and every later message was swallowed by the isSending guard,
    /// which is what "it just says Thinking… and ignores me" actually was.
    private func finishSending(_ key: String) {
        sendingScopeKeys.remove(key)
        statusByScopeKey[key] = nil
        progressByScopeKey[key] = nil
        sendTasks[key] = nil
    }

    private func recordProgress(_ status: String, for key: String) {
        statusByScopeKey[key] = status
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var steps = progressByScopeKey[key] ?? []
        if steps.last?.caseInsensitiveCompare(normalized) != .orderedSame {
            steps.append(normalized)
        }
        progressByScopeKey[key] = steps
    }

    /// Closes any console row still running for a thread whose turn has ended, so the log
    /// never shows work in progress that nothing is doing.
    private func settleConsole(_ scope: GeneralChatScope) {
        ChatConsoleLog.shared.settleRunning(
            scope: scope, note: "Stopped when the turn ended.")
    }

    private func deliver(
        _ message: AIChatMessage, to scope: GeneralChatScope, title: String
    ) {
        Self.log.notice("turn end scope=\(scope.storageKey, privacy: .public)")
        // The watchdog and the real answer can both arrive; whichever is first ends the
        // turn, and the loser is dropped rather than appended twice.
        guard sendingScopeKeys.contains(scope.storageKey) else { return }
        // The finished answer supersedes whatever was streamed into the bubble, including a
        // partial one left behind by a turn that failed or timed out, and the step rows that
        // described getting there.
        clearStreamingMessage()
        clearStepRows()
        sendingScopeKeys.remove(scope.storageKey)
        statusByScopeKey[scope.storageKey] = nil
        progressByScopeKey[scope.storageKey] = nil
        settleConsole(scope)
        // Anything the answer built becomes a file, which the panel already knows how to
        // show. Done here rather than in the view so an artifact survives the thread being
        // switched away from before it was ever looked at.
        ArtifactStore.extract(from: message.content, scope: scope)
        sendTasks[scope.storageKey] = nil

        if scope == activeScope {
            messages.append(message)
            persist()
            return
        }

        var stored = GeneralChatSessionStore.load(scope: scope)
        stored.append(message)
        GeneralChatSessionStore.save(stored, scope: scope, title: title)
        sessions = GeneralChatSessionStore.index()
    }

    private func persist() {
        GeneralChatSessionStore.save(messages, scope: activeScope, title: activeTitle)
        sessions = GeneralChatSessionStore.index()
    }
}
