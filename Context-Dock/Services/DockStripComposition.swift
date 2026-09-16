// DockStripComposition.swift
// Context-Dock
//
// One dock row, composed once, so what the strip draws and what the corner is sized from
// can never disagree.
//
// The strip drew two independent lists — every running app, then every pin — with a divider
// between them. An app that was both showed up twice: Safari pinned and Safari open put two
// identical icons on the same row, one of them meaningless. A dock has one icon per app; the
// dot says it is running and the position says the user placed it.

import AppKit
import Foundation

/// An app's single place on the strip. Either half may be absent: a pinned app that is not
/// running has no icon in the running list, and a running app nobody pinned has no pin.
struct DockAppSlot: Identifiable, Equatable {
    let bundleID: String
    let title: String
    let pin: DockPin?
    let running: MatchDockIcon?
    /// Whether the app is up. Not `running != nil`: an app taken off the strip with "Remove
    /// from Strip" is absent from that list while still running, and a pin must not lie
    /// about it.
    let isRunning: Bool

    var id: String { pin?.id.uuidString ?? running?.id ?? bundleID }
    var isPinned: Bool { pin != nil }
}

struct DockStripComposition: Equatable {
    /// The app region, left to right: pinned apps in the order the user put them, then the
    /// running apps that are not pinned. Pinned first is the Dock's own rule — what someone
    /// placed by hand does not move because something else launched.
    let apps: [DockAppSlot]
    /// Pins that are not apps — commands, CLI tools, files, folders. They keep the region
    /// after the divider, the way the Dock keeps files apart from apps.
    let otherPins: [DockPin]
    /// Running apps past capacity, drawn as `+N`. A pinned app is never in this count.
    let overflow: Int

    var pinnedAppCount: Int { apps.count { $0.isPinned } }
    var unpinnedRunningCount: Int { apps.count { !$0.isPinned } }

    /// Pure: two lists in, one row out.
    ///
    /// `runningBundleIDs` is every app that is up, which is a wider set than `running` —
    /// that one is what the strip is willing to show.
    ///
    /// `unresolvedDocumentIDs` are commands and tools whose document this build cannot
    /// find — a plugin that is not installed here, an extension since deleted. They are
    /// dropped from the row rather than drawn as an empty box: the icon said nothing, the
    /// click did nothing, and the pin itself stays in the store so it comes back with the
    /// thing it points at.
    static func compose(
        running: [MatchDockIcon], pins: [DockPin], runningBundleIDs: Set<String>,
        unresolvedDocumentIDs: Set<String> = [], capacity: Int = .max
    ) -> DockStripComposition {
        var appSlots: [DockAppSlot] = []
        var otherPins: [DockPin] = []
        var pinnedBundleIDs: Set<String> = []

        for pin in pins {
            if let documentID = pin.documentID, unresolvedDocumentIDs.contains(documentID) {
                continue
            }
            guard case .app(let bundleID) = pin.kind else {
                otherPins.append(pin)
                continue
            }
            // The store refuses a second pin of the same kind, so this only guards against
            // a hand-edited dock-pins.json.
            guard pinnedBundleIDs.insert(bundleID).inserted else { continue }
            let icon = running.first { $0.bundleID == bundleID }
            appSlots.append(
                DockAppSlot(
                    bundleID: bundleID, title: pin.title, pin: pin, running: icon,
                    isRunning: icon != nil || runningBundleIDs.contains(bundleID)))
        }

        let unpinned = running.filter { icon in
            guard let bundleID = icon.bundleID else { return true }
            return !pinnedBundleIDs.contains(bundleID)
        }
        let shown = unpinned.prefix(max(0, capacity))
        appSlots += shown.map { icon in
            DockAppSlot(
                bundleID: icon.bundleID ?? icon.id, title: icon.title, pin: nil, running: icon,
                isRunning: icon.isRunning)
        }

        return DockStripComposition(
            apps: appSlots, otherPins: otherPins, overflow: unpinned.count - shown.count)
    }
}

/// The composition and the geometry that matches it, made together.
///
/// Capacity comes from the metrics and the metrics need the counts, so this runs the pure
/// composition twice: once to learn how many apps are unpinned, once to cut the row to the
/// width that survives. Both callers — the strip and the corner's size — go through here,
/// which is the whole point (memory `corner-pill-size-must-be-pure`).
struct DockStripPlan {
    let composition: DockStripComposition
    let layout: AppChatPromptMetrics.DockLayout

    /// What is running and what resolves, remembered briefly.
    ///
    /// This is read from `body` and from two `size` computations, so it runs several times
    /// per layout pass and every frame of an animation. Walking every running application
    /// and asking the search index about every pin at that rate is work nobody sees: an app
    /// launching or quitting shows up within the window instead, which is faster than the
    /// dot could be noticed anyway.
    @MainActor private static var environmentCache: (taken: Date, running: Set<String>,
        unresolved: Set<String>)?
    @MainActor private static let environmentTTL: TimeInterval = 0.5

    @MainActor
    static func make(running: [MatchDockIcon], pins: [DockPin], tools: Int) -> DockStripPlan {
        let environment: (running: Set<String>, unresolved: Set<String>)
        if let cached = environmentCache,
            Date().timeIntervalSince(cached.taken) < environmentTTL
        {
            environment = (cached.running, cached.unresolved)
        } else {
            let runningBundleIDs = Set(
                NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let unresolved = Set(
                pins.compactMap { pin -> String? in
                    guard let documentID = pin.documentID,
                        GlobalSearchService.shared.document(withID: documentID) == nil
                    else { return nil }
                    return documentID
                })
            environmentCache = (Date(), runningBundleIDs, unresolved)
            environment = (runningBundleIDs, unresolved)
        }
        return make(
            running: running, pins: pins, runningBundleIDs: environment.running,
            unresolvedDocumentIDs: environment.unresolved, tools: tools)
    }

    static func make(
        running: [MatchDockIcon], pins: [DockPin], runningBundleIDs: Set<String>,
        unresolvedDocumentIDs: Set<String> = [], tools: Int
    ) -> DockStripPlan {
        let full = DockStripComposition.compose(
            running: running, pins: pins, runningBundleIDs: runningBundleIDs,
            unresolvedDocumentIDs: unresolvedDocumentIDs)
        let layout = AppChatPromptMetrics.dockLayout(
            running: full.unpinnedRunningCount, pinnedApps: full.pinnedAppCount,
            pinned: full.otherPins.count, tools: tools)
        guard layout.overflow > 0 else { return DockStripPlan(composition: full, layout: layout) }
        return DockStripPlan(
            composition: DockStripComposition.compose(
                running: running, pins: pins, runningBundleIDs: runningBundleIDs,
                unresolvedDocumentIDs: unresolvedDocumentIDs, capacity: layout.shownRunning),
            layout: layout)
    }
}
