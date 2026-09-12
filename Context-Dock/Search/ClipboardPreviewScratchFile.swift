// ClipboardPreviewScratchFile.swift
// Context-Dock
//
// Where a clipboard text entry lives on disk long enough for the preview panel to render
// it, and the naming rule that fixed a real bug.
//
// Text has no file of its own, so previewing it writes one. That file used to have a single
// fixed name reused for every clip. `PreviewItem.id` is the URL, so two different clips
// previewed one after another produced the identical id: `PreviewController.present`'s
// `toggleIfSame` read the second press as "close the one already open" rather than "show
// different text", and on the rare path where the window did stay open, SwiftUI's
// `.id(item.id)` never changed either, so `PreviewTextEditor` kept showing whatever it had
// already loaded — the panel looked blank or stuck on stale text under a title that had in
// fact changed.
//
// Naming the file by a hash of its content fixes both at once: identical text still
// collapses to the same URL and toggles the same window shut, which is the one case where
// that behaviour is actually wanted, and different text always gets a fresh id.
//
// Pulled out of `ClipboardPanelController` as pure functions — no AppKit, no view model —
// so the naming rule and the pruning rule can be asserted directly rather than through a
// full clipboard model and a live preview window.

import Foundation

enum ClipboardPreviewScratchFile {

    /// The filename prefix every scratch file for a text clip shares, so pruning can find
    /// them and nothing else in the temp directory.
    static let filenamePrefix = "context-dock-clip-preview-"

    /// A short, stable-within-this-process fingerprint of the text.
    ///
    /// `String.hashValue` is reseeded per launch, not per string — the same text hashes the
    /// same way for as long as this process runs, which is exactly the lifetime a scratch
    /// file needs: nothing about "the same clip pressed twice" is expected to survive a
    /// relaunch, and every file gets pruned on the next write regardless.
    static func digest(for text: String) -> String {
        String(format: "%016x", text.hashValue)
    }

    /// Where this text's scratch file lives, without writing it.
    static func url(for text: String, in directory: URL = FileManager.default.temporaryDirectory)
        -> URL
    {
        directory.appendingPathComponent("\(filenamePrefix)\(digest(for: text)).txt")
    }

    /// Write the text to its content-named scratch file and return where it landed.
    @discardableResult
    static func write(
        _ text: String, in directory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        let target = url(for: text, in: directory)
        guard (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return target
    }

    /// Every earlier scratch file except the one just written. Best-effort: a file the
    /// preview panel still has open fails to delete on some platforms and that failure is
    /// silently swallowed, because leaving one extra file behind is nothing next to the bug
    /// this replaced.
    ///
    /// Compares filenames, not full URLs. `/var` on macOS is a symlink to `/private/var`,
    /// and `contentsOfDirectory` can hand back the resolved path while `current` still holds
    /// the unresolved one `temporaryDirectory` returned — the two `URL`s then compare
    /// unequal despite naming the same file, and this deleted the very file it meant to
    /// keep. The filename already carries the content hash, so it alone is enough to tell
    /// two scratch files apart.
    static func pruneStale(
        keeping current: URL, in directory: URL = FileManager.default.temporaryDirectory
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }
        let keptName = current.lastPathComponent
        for entry in entries
        where entry.lastPathComponent.hasPrefix(filenamePrefix)
            && entry.lastPathComponent != keptName
        {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
