// SelectionScopeCard.swift
// Context-Dock
//
// The selection card in the corner shell: what is selected, and a field to act on it.
//
// Same card shape as its siblings — the clipboard preview, the App Chat list — because it
// is one of them now rather than the launcher wearing a smaller coat.

import AppKit
import SwiftUI

enum SelectionScopeMetrics {
    static let width = CornerDockLayout.cardWidth
    static let headerHeight: CGFloat = 30
    static let inputHeight: CGFloat = 44
    /// Three lines of the selection, which is enough to recognise it without becoming a
    /// reader. The card is for choosing a subject, not for reading the document.
    static let previewHeight: CGFloat = 62
    static let verticalPadding: CGFloat = 10
    /// The Dock's Selection rows, above the field. Past this many the list scrolls.
    static let maxVisibleRows = 6
    static var rowHeight: CGFloat { AppChatListMetrics.rowHeight }

    /// Answering: the selection shrinks to one line, the answer takes the room the rows had.
    static let compactPreviewHeight: CGFloat = 22
    static let answerHeight: CGFloat = 300
    static let resultActionsHeight: CGFloat = 36
    /// The Computer Use question, when a row needs it.
    static let consentHeight: CGFloat = 62
    /// What a typed send command did.
    static let outcomeHeight: CGFloat = 30

    /// A pure function of state, like every other corner surface: the shell hit-tests this
    /// exact number.
    static func size(
        rows: Int, answering: Bool = false, consent: Bool = false, outcome: Bool = false
    ) -> CGSize {
        let base = sizeWithoutConsent(rows: rows, answering: answering)
        let extra = (consent ? consentHeight : 0) + (outcome ? outcomeHeight : 0)
        return CGSize(width: base.width, height: base.height + extra)
    }

    private static func sizeWithoutConsent(rows: Int, answering: Bool) -> CGSize {
        if answering {
            return CGSize(
                width: width,
                height: headerHeight + compactPreviewHeight + answerHeight + resultActionsHeight
                    + inputHeight + verticalPadding * 2)
        }
        let listed = CGFloat(min(max(rows, 0), maxVisibleRows)) * rowHeight
        return CGSize(
            width: width,
            height: headerHeight + previewHeight + listed + inputHeight + verticalPadding * 2)
    }
}

struct SelectionScopeCard: View {
    @ObservedObject var model: SelectionScopeModel
    /// Observed so the answer redraws as it streams in.
    @ObservedObject private var conversation = AppChatConversation.shared
    @ObservedObject private var keyboardState = CornerDockController.shared.keyboardState
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.isShowingAnswer {
                compactPreview
                answer
                resultActions
            } else {
                preview
                rowList
            }
            if model.pendingConsent != nil { consentStrip }
            if let row = model.pendingApproval { approvalStrip(row) }
            if model.showsOutcome { outcomeLine }
            field
        }
        .padding(.vertical, SelectionScopeMetrics.verticalPadding)
        .frame(
            width: cardSize.width,
            height: cardSize.height,
            alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .background(GlassBackground(cornerRadius: 22, isDark: true))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
        }
        .onHover { inside in model.pointerChanged(inside: inside) }
        .onAppear { fieldFocused = keyboardState.owner == .selection }
        .onChange(of: keyboardState.owner) { _, owner in fieldFocused = owner == .selection }
        .onChange(of: keyboardState.focusRequestToken) { _, _ in
            fieldFocused = keyboardState.owner == .selection
        }
    }

    private var cardSize: CGSize {
        SelectionScopeMetrics.size(
            rows: model.rows.count, answering: model.isShowingAnswer,
            consent: model.isAsking, outcome: model.showsOutcome)
    }

    /// An extension that may change things asks first — here, where the keys already are.
    private func approvalStrip(_ row: SelectionActionRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(row.title) may \(row.approval ?? "change things"). It gets only this selection.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                resultButton("Run  ↩", "play.fill") { model.approveRun() }
                Spacer(minLength: 0)
                Button("Cancel") { model.cancelApproval() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: SelectionScopeMetrics.consentHeight, alignment: .center)
    }

    /// What a typed "send to …" did — the router's own words, or that it is under way.
    private var outcomeLine: some View {
        HStack(spacing: 6) {
            if model.isSending {
                ProgressView().controlSize(.small)
                Text("Sending…")
            } else if let outcome = model.outcome {
                Text(outcome)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SelectionScopeMetrics.outcomeHeight)
    }

    /// Asked in the card, before a row takes the screen (surface-cost spec, Step 4).
    private var consentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This uses \(model.pendingConsentAppName)'s menu — DoraX would press it for you.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                resultButton("Allow once", "hand.tap") { model.allowOnce() }
                resultButton("Always for \(model.pendingConsentAppName)", "checkmark.shield") {
                    model.allowAlways()
                }
                Spacer(minLength: 0)
                Button("Cancel") { model.cancelConsent() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: SelectionScopeMetrics.consentHeight, alignment: .center)
    }

    /// The selection, one line: still says what the answer is about.
    private var compactPreview: some View {
        Text(model.preview)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(
                maxWidth: .infinity, minHeight: SelectionScopeMetrics.compactPreviewHeight,
                maxHeight: SelectionScopeMetrics.compactPreviewHeight, alignment: .leading)
            .padding(.horizontal, 16)
    }

    /// The answer, drawn by the corner's one transcript view — tables, links, files, images and
    /// result cards exactly as App Chat and the Dock draw them.
    private var answer: some View {
        CornerTranscript(
            messages: model.answerMessages,
            isAnswering: model.isAnswering,
            liveSteps: conversation.liveSteps,
            appName: model.appName,
            appBundleID: model.appBundleID,
            appIcon: appIcon)
            .frame(height: SelectionScopeMetrics.answerHeight)
    }

    /// What can be done with the answer, at its end. Labelled when the row fits the card,
    /// icons alone when it does not — five actions ran off the card's edge (Share cut, the
    /// way back hidden).
    private var resultActions: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                resultButtons(labelled: true)
                resultButtons(labelled: false)
            }
            Spacer(minLength: 0)
        }
        .disabled(model.latestAnswer == nil || model.isAnswering)
        .opacity(model.latestAnswer == nil || model.isAnswering ? 0.45 : 1)
        .padding(.horizontal, 16)
        .frame(height: SelectionScopeMetrics.resultActionsHeight)
    }

    private func resultButtons(labelled: Bool) -> some View {
        HStack(spacing: 6) {
            switch model.replaceRoute {
            case .replaceInPlace:
                resultButton("Replace", "arrow.left.arrow.right", labelled: labelled) {
                    model.replaceWithAnswer()
                }
            case .copyInstead:
                resultButton("Replace", "arrow.left.arrow.right", labelled: labelled) {
                    model.replaceWithAnswer()
                }
                .help("Copies the answer. Turn on Computer Use for \(model.appName) to replace in place.")
            case .unavailable:
                EmptyView()
            }
            resultButton("Copy", "doc.on.doc", labelled: labelled) { model.copyAnswer() }
            resultButton("Note", "note.text.badge.plus", labelled: labelled) {
                model.saveAnswerToQuickNote()
            }
            .help("Save the answer to a Quick Note")
            resultButton("Share", "square.and.arrow.up", labelled: labelled) { model.shareAnswer() }
                .help("Share the answer")
        }
    }

    private func resultButton(
        _ title: String, _ symbol: String, labelled: Bool = true, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if labelled {
                    Label(title, systemImage: symbol)
                } else {
                    Image(systemName: symbol)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var appIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: model.appBundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// What was selected and where it came from — said plainly, because acting on the wrong
    /// selection is the failure this surface exists to prevent.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: model.isSharing ? "square.and.arrow.up" : (model.scope?.icon ?? "text.cursor"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(headerTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            if !model.appName.isEmpty {
                Text("· \(model.appName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            Spacer(minLength: 4)
            if model.isShowingAnswer {
                // The way back to the actions (Esc does the same). Up here, so the answer's
                // own actions keep their labels in the row below.
                Button { model.escapePressed() } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to the actions (Esc)")
                .accessibilityLabel("Back to the actions")
            }
            Button { model.togglePin() } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.isPinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Unpin" : "Keep this open")
            // A visible way out. Esc was the only one, and nobody knew it (§4a).
            Button { model.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .frame(height: SelectionScopeMetrics.headerHeight)
    }

    private var headerTitle: String {
        let subject = model.scope?.label ?? "Selection"
        guard model.isSharing else { return subject }
        return model.isSharingAnswer ? "Share the answer" : "Share \(subject)"
    }

    private var preview: some View {
        Text(model.preview)
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.82))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(
                maxWidth: .infinity, minHeight: SelectionScopeMetrics.previewHeight,
                maxHeight: SelectionScopeMetrics.previewHeight, alignment: .topLeading)
            .padding(.horizontal, 16)
    }

    /// What can be done with the selection — the Dock's Selection rows, filtered as the field
    /// is typed into, the way the clipboard's preview sits above its input.
    @ViewBuilder
    private var rowList: some View {
        if !model.rows.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: model.rows.count > SelectionScopeMetrics.maxVisibleRows) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, isFocused: index == model.focusedIndex)
                                .id(row.id)
                        }
                    }
                }
                .frame(height: SelectionScopeMetrics.size(rows: model.rows.count).height
                    - SelectionScopeMetrics.size(rows: 0).height)
                .onChange(of: model.focusedIndex) { _, index in
                    guard let index, model.rows.indices.contains(index) else { return }
                    proxy.scrollTo(model.rows[index].id)
                }
            }
        }
    }

    private func rowView(_ row: SelectionActionRow, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let image = row.image {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
                } else {
                    Image(systemName: row.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if case .needsConsent = model.screenGate(for: row) {
                    Text("Needs Computer Use · \(row.badge ?? "Finder")")
                        .font(.system(size: 11)).foregroundStyle(.orange.opacity(0.85)).lineLimit(1)
                } else if let badge = row.badge, !badge.isEmpty {
                    Text(badge).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isFocused {
                Image(systemName: "return").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: SelectionScopeMetrics.rowHeight)
        .background { CornerListRowBackground(isFocused: isFocused) }
        .contentShape(Rectangle())
        .onTapGesture { model.run(row) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var placeholder: String {
        if model.isSharing { return "Find a destination…" }
        return model.isShowingAnswer ? "Ask a follow-up…" : "Ask about this selection…"
    }

    private var field: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($fieldFocused)
                    .onChange(of: model.query) { _, _ in model.queryChanged() }
                    .onSubmit { model.returnPressed() }
                    .onKeyPress(.downArrow) { model.moveFocus(by: 1) ? .handled : .ignored }
                    .onKeyPress(.upArrow) { model.moveFocus(by: -1) ? .handled : .ignored }
                    .onKeyPress(.escape) {
                        // The corner's key monitor already stepped back for this press.
                        if SelectionScopeModel.fieldHandlesEscape(keyboardOwner: keyboardState.owner) {
                            model.escapePressed()
                        }
                        return .handled
                    }
            }
            Button { model.returnPressed() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        model.query.isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(model.query.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: SelectionScopeMetrics.inputHeight)
    }
}
