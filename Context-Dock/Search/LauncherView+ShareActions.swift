import AppKit
import SwiftUI

extension LauncherView {
    // MARK: - Share sheet

    func presentSharingPicker(items: [Any]) {
        ShareActionCoordinator.shared.presentSharingPicker(items: items) { active in
            self.isSharingSheetActive = active
        }
    }

    /// Shows NSSharingServicePicker anchored above the pill row,
    /// using the current AX context (selected files, URL, or text).
    /// Sets shareSheetVisible = true so arrow keys are passed through to the picker.
    func showShareSheetForContext() {
        let items = ShareIntentRouter.shared.shareableItems(
            for: effectiveShareAXContext())
        guard !items.isEmpty else { return }
        presentSharingPicker(items: items)
    }

    func executeShareMenuDestination(_ title: String) {
        let normalizedTitle = normalizedDockPillText(title)
        let items = ShareIntentRouter.shared.shareableItems(
            for: effectiveShareAXContext())
        ShareActionCoordinator.shared.executeShareDestination(
            title: title,
            normalizedTitle: normalizedTitle,
            items: items,
            presentSharingPicker: { self.presentSharingPicker(items: $0) }
        )
    }

    func effectiveShareAXContext() -> AXContext {
        let pid = axContext.pid != 0
            ? axContext.pid
            : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
        return SelectedContextResolver.effectiveShareContext(
            SelectedContextResolver.ShareInput(
                axContext: axContext,
                currentContext: currentContext,
                selectedFileURLs: effectiveSelectedFileURLsForConversation(),
                frozenSelectionText: frozenSelectionText,
                previousFrontmostPID: pid
            )
        )
    }

    func focusedDocumentURLForShareContext() -> URL? {
        let pid = axContext.pid != 0
            ? axContext.pid
            : (AppDelegate.shared?.previousFrontmostApp?.processIdentifier ?? 0)
        return SelectedContextResolver.focusedDocumentURL(pid: pid)
    }

    func fileURLFromAXValue(_ value: CFTypeRef) -> URL? {
        SelectedContextResolver.fileURLFromAXValue(value)
    }

    func validShareFileURL(_ url: URL) -> URL? {
        SelectedContextResolver.validShareFileURL(url)
    }

    func isBrowserBundleId(_ bundleId: String) -> Bool {
        SelectedContextResolver.isBrowserBundleId(bundleId)
    }

    func executeShareIntent(
        _ intent: ShareIntent,
        userMessage: String? = nil
    ) {
        let capturedContext = effectiveAXContextForConversation()
        if let userMessage, !userMessage.isEmpty {
            l2.chatMessages.append(AIChatMessage(role: .user, content: userMessage))
        }
        l2.isLoading = true
        Task {
            let resolution = await ShareIntentRouter.shared.resolve(intent)
            let output = await ShareIntentRouter.shared.execute(
                resolution,
                axContext: capturedContext,
                presentSharingPicker: { items in
                    self.presentSharingPicker(items: items)
                }
            )
            await MainActor.run {
                self.l2.chatMessages.append(AIChatMessage(role: .assistant, content: output))
                self.l2.isLoading = false
            }
        }
    }

    func executeTransformShareIntent(
        _ intent: ShareIntent,
        userMessage: String
    ) {
        let selectedFiles = effectiveSelectedFileURLsForConversation()
        guard !selectedFiles.isEmpty else {
            l2.chatMessages.append(AIChatMessage(role: .user, content: userMessage))
            l2.chatMessages.append(
                AIChatMessage(
                    role: .assistant,
                    content:
                        "Select a small text or PDF document first, then ask me to summarize and send it.",
                    isError: true
                ))
            return
        }

        if let existingTask = l2.currentTask {
            existingTask.cancel()
            l2.currentTask = nil
            l2.isLoading = false
            l2.activeRequestID = nil
        }

        l2.chatMessages.append(AIChatMessage(role: .user, content: userMessage))
        l2.isLoading = true
        searchState.query = ""
        l2.focusedPillIndex = nil

        l2.currentTask = Task {
            let readable = transformShareReadableContent(from: selectedFiles)
            guard !readable.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run {
                    l2.chatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content:
                                "I couldn't read text from the selected file. This works best with small text, Markdown, source, CSV, RTF, or text-based PDF files.",
                            isError: true
                        ))
                    l2.isLoading = false
                    l2.currentTask = nil
                }
                return
            }

            do {
                let summaryPrompt = transformSharePrompt(
                    userMessage: userMessage,
                    fileSummary: readable.summary,
                    fileContent: readable.content
                )
                let summary = try await sendToAIProviderWithContext(
                    query: summaryPrompt,
                    messageHistory: l2.chatMessages
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                guard !Task.isCancelled else { return }
                let resolution = await ShareIntentRouter.shared.resolve(intent)
                let subject = "Summary of \(readable.primaryFileName)"
                let output = await ShareIntentRouter.shared.executeText(
                    summary,
                    resolution: resolution,
                    subject: subject,
                    presentSharingPicker: { items in
                        self.presentSharingPicker(items: items)
                    }
                )

                await MainActor.run {
                    l2.chatMessages.append(
                        AIChatMessage(role: .assistant, content: "\(output)\n\n\(summary)")
                    )
                    l2.isLoading = false
                    l2.currentTask = nil
                }
            } catch {
                await MainActor.run {
                    l2.chatMessages.append(
                        AIChatMessage(
                            role: .assistant,
                            content:
                                "Sorry, I couldn't summarize and send that: \(error.localizedDescription)",
                            isError: true
                        ))
                    l2.isLoading = false
                    l2.currentTask = nil
                }
            }
        }
    }

    func transformShareIntent(for query: String) -> ShareIntent? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let hasTransformWord = [
            "summary", "summarize", "summarise", "tldr", "tl;dr",
            "explain", "describe", "key points", "short version", "brief",
        ].contains { q.contains($0) }
        let hasDeliveryWord = [
            "send", "share", "message", "messages", "imessage", "text",
            "sms", "mail", "email",
        ].contains { q.contains($0) }
        let referencesSelection = [
            "this file", "selected file", "selection", "this document",
            "selected document", "this pdf", "selected pdf", "this",
        ].contains { q.contains($0) }
        guard hasTransformWord, hasDeliveryWord, referencesSelection else { return nil }
        guard !effectiveSelectedFileURLsForConversation().isEmpty else { return nil }
        return ShareIntentRouter.shared.parse(query)
    }

    func transformShareReadableContent(from urls: [URL])
        -> (summary: String, content: String, primaryFileName: String)
    {
        TransformShareContentReader.readableContent(from: urls)
    }

    func transformSharePrompt(
        userMessage: String,
        fileSummary: String,
        fileContent: String
    ) -> String {
        TransformShareContentReader.prompt(
            userMessage: userMessage,
            fileSummary: fileSummary,
            fileContent: fileContent
        )
    }

}
