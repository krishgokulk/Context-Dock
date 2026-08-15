// PreviewKeyRouter.swift
// Context-Dock
//
// One place that decides what Space means.
//
// It used to be five: two dock monitors, the scoped list panel, the Quick Look
// datasource, and the folder view. Each guarded against the others, and a row type
// nobody had thought about fell between them — Space in a file scope did nothing for
// a while because a branch further up the same monitor swallowed it first.
//
// The ladder below is the whole rule. Both dock monitors call it; the first local
// monitor to consume the event ends propagation, so it can only run once per press.
// The scoped list panel keeps its own .onKeyPress — it is a separate surface with its
// own focus, and that is the one case where Space legitimately means something else.

import AppKit
import SwiftUI

extension LauncherView {
    /// True when the keystroke belongs to a floating panel — a pin, a sticky note, a
    /// preview window — rather than to the dock behind it.
    func previewOwnsKeyEvent(_ event: NSEvent) -> Bool {
        GlassFloatingPanel.ownsEvent(event) || PreviewController.shared.ownsEvent(event)
    }

    /// Returns true when the press was consumed. Order matters: the most specific
    /// focus wins, and the results list — the broadest target — is last.
    func handleSpaceKeyForPreview(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false }
        // ⌘Space is Spotlight's, and a modifier press is never a peek.
        guard !event.modifierFlags.contains(.command) else { return false }
        // AI mode: the user is writing a sentence, and a space is a space.
        guard !aiMode.isActive else { return false }

        // 1. A dock row that stands for a file. Covers file scopes (Screenshots, a
        //    folder extension) where the row's own path is the thing to preview.
        if let path = focusedPillPreviewPath() {
            FileQuickLookPanel.shared.toggle(path: path, siblings: visiblePreviewPaths())
            return true
        }

        // 2. Any other focused dock pill that resolves to a file or a web page.
        if let pill = currentFocusedDockPillForQuickLook(), quickLookDockPill(pill) {
            return true
        }

        // 3. Global grouped list (the app-scope sheet): Space peeks web link rows.
        if isGlobalContextActive,
            let pill = focusedGlobalGroupedListPill(),
            pill.resolvedURL != nil,
            quickLookDockPill(pill)
        {
            return true
        }

        // 4. A file result inside the global app sheet, once the user is arrowing.
        if isGlobalContextActive,
            l2.pillNavViaKeyboard,
            let result = focusedGlobalAppResultForInputPreview(),
            result.type != .application,
            let path = result.filePath,
            showQuickLookURL(URL(fileURLWithPath: path), toggleIfSame: true)
        {
            return true
        }

        // 5. The results list. Files, folders and contacts all preview; anything else
        //    lets the space through.
        guard let index = searchState.selectedIndex,
            searchState.results.indices.contains(index)
        else { return false }
        let result = searchState.results[index]
        guard result.filePath != nil || result.type == .contact else { return false }

        // Never consume Space mid-query — the user may be typing a multi-word search.
        // Shift+Space peeks anyway, which is how a peek stays reachable while typing.
        guard event.modifierFlags.contains(.shift) || searchState.query.isEmpty else {
            return false
        }
        DispatchQueue.main.async { self.quickLookSelectedItem() }
        return true
    }
}
