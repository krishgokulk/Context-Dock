//
//  LauncherView+BrowserPageActions.swift
//  Context-Dock
//
//  Last routing step for a browser / Safari Web App scope.
//
//  Every earlier step in `handleL2Query` matches an existing capability — a trigger
//  rule, a system command, a menu path, an adapter action, a cross-app intent. Page
//  requests have none of those to match: "dark mode for this page", "hide the
//  sidebar", "expand all comments" are capabilities of the *page*, so no app ever
//  ships a menu item for them. Reaching general chat with one of those produced an
//  explanation of how to do it by hand, which is the one thing the dock exists to
//  avoid. Here the request becomes a real Browser Extension action instead: written
//  on demand, shown before it runs, and kept afterwards so the next time it is a
//  trigger match rather than a provider call.
//

import AppKit
import SwiftUI

extension LauncherView {

    /// The browser-ish app this query should act on, or nil when the scope isn't a page.
    func browserPageActionTarget(scopedBundleId: String, scopedAppName: String)
        -> (bundleId: String, appName: String)?
    {
        let bundleId = scopedBundleId.isEmpty ? frontmost.bundleID : scopedBundleId
        guard !bundleId.isEmpty, bundleId != Bundle.main.bundleIdentifier else { return nil }
        guard isContextDockBrowserBundle(bundleId)
            || bundleId.hasPrefix("com.apple.Safari.WebApp.")
        else { return nil }

        var appName = scopedAppName.isEmpty ? frontmost.name : scopedAppName
        if appName.isEmpty {
            appName = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == bundleId }?.localizedName ?? "Browser"
        }
        return (bundleId, appName)
    }

    /// Author, approve, run and keep a page script for `query`.
    /// Returns false when this isn't a page request, so the caller falls through to chat.
    @discardableResult
    func tryAuthorBrowserPageAction(
        query: String,
        scopedBundleId: String,
        scopedAppName: String
    ) -> Bool {
        guard settings.enableContextAIExtensions else { return false }
        guard let target = browserPageActionTarget(
            scopedBundleId: scopedBundleId, scopedAppName: scopedAppName)
        else { return false }
        guard BrowserActionAuthor.looksLikePageAction(query) else { return false }

        let pageURL = axContext.currentURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pageTitle = (axContext.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        l2.chatMessages.append(AIChatMessage(role: .user, content: query))
        l2.isLoading = true
        dockTraceStep("No menu or saved action matches — writing a page script for \(target.appName)")
        let requestID = beginL2AIRequest()

        l2.currentTask = Task {
            do {
                let authored = try await BrowserActionAuthor.shared.author(
                    query: query, pageURL: pageURL, pageTitle: pageTitle, appName: target.appName)
                if Task.isCancelled {
                    await MainActor.run { finishL2AIRequest(requestID) }
                    return
                }
                await runAuthoredPageAction(authored, target: target, requestID: requestID)
            } catch {
                if isCancellationError(error) {
                    await MainActor.run { finishL2AIRequest(requestID) }
                    return
                }
                await MainActor.run {
                    l2.chatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content: error.localizedDescription,
                            isError: true))
                    finishL2AIRequest(requestID)
                }
            }
        }
        return true
    }

    /// Save the action onto the app's adapter, run it through the normal approval path,
    /// and roll the save back if the user declines or it fails — a script that never ran
    /// has no business sitting in their adapter list.
    private func runAuthoredPageAction(
        _ authored: BrowserActionAuthor.Authored,
        target: (bundleId: String, appName: String),
        requestID: UUID
    ) async {
        if !adapterManager.adapters.contains(where: { $0.bundleId == target.bundleId }) {
            await adapterManager.createAdapter(
                appName: target.appName, bundleId: target.bundleId, icon: "globe")
        }
        await adapterManager.appendAction(authored.action, to: target.bundleId)

        await MainActor.run {
            dockTraceStep("Running \(authored.action.name) in \(target.appName)")
        }
        let capturedContext = await MainActor.run { effectiveAXContextForConversation() }
        let (ok, output) = await adapterManager.execute(
            authored.action, context: capturedContext, targetBundleId: target.bundleId)

        if !ok {
            await adapterManager.deleteAction(id: authored.action.id, from: target.bundleId)
        }

        await MainActor.run {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if ok {
                let ran = detail.isEmpty ? authored.summary : detail
                message = """
                    **\(authored.action.name)** — \(ran)

                    Saved as a Browser Extension action on \(target.appName). Ask for it by \
                    name next time and it runs straight away.
                    """
            } else {
                message = detail.isEmpty
                    ? "Couldn't run \(authored.action.name)."
                    : "Couldn't run \(authored.action.name): \(detail)"
            }
            l2.chatMessages.append(
                AIChatMessage(role: .assistant, content: message, isError: !ok))
            finishL2AIRequest(requestID)
        }
    }
}
