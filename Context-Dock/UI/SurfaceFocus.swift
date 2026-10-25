// SurfaceFocus.swift
// Context-Dock
//
// The one focus-state of the unified Corner surface (#318). Global Context and the frontmost
// app's Context Dock are not two layers with their own state: they are one field, one running-
// apps row and one query, and *focus* — one app or all apps — is the only difference. The
// data-vs-UI lane (`RequestLane`/`LanePlan`) is decided per request and never reads this.

import Foundation

/// What the surface is focused on.
enum SurfaceFocus: Equatable {
    /// The app in front now — the default on open (today's "Context Dock").
    case frontmost
    /// Every running app, cross-app (today's "Global Context").
    case global
    /// An app chosen from Global with → or a pill, not necessarily the one in front.
    case app
}

/// A key or gesture that can move focus. Only the moves that change focus are here; ← / swipes
/// into General Chat stay in `CornerNavigation`.
enum SurfaceFocusEvent: Equatable {
    /// A lone, quick ⌘ tap.
    case commandTap
    /// ↑ or a swipe down — zoom out toward Global.
    case zoomOut
    /// ↓ or a swipe up — zoom back in toward the frontmost app.
    case zoomIn
    /// → on an empty field with nothing highlighted — step into an app.
    case stepIn
    /// Esc (or ← off the first app) with nothing left to unwind — step back.
    case stepBack
}

enum SurfaceFocusOutcome: Equatable {
    case focus(SurfaceFocus)
    /// Put the surface away.
    case close
    /// The key means nothing here.
    case none
}

enum SurfaceFocusRules {
    /// Pure: where an event leaves the surface. The same answer for a key and for the swipe
    /// that mirrors it (00-DOCK-AND-CORNER §4b), from either shell position.
    static func decide(_ event: SurfaceFocusEvent, from focus: SurfaceFocus) -> SurfaceFocusOutcome {
        switch (event, focus) {
        // ⌘ is a zoom: out from an app, back in from Global. From a chosen app it comes home to
        // Global first, as Backspace does.
        case (.commandTap, .frontmost): return .focus(.global)
        case (.commandTap, .global): return .focus(.frontmost)
        case (.commandTap, .app): return .focus(.global)

        case (.zoomOut, .frontmost): return .focus(.global)
        case (.zoomOut, .global), (.zoomOut, .app): return .none

        case (.zoomIn, .global), (.zoomIn, .app): return .focus(.frontmost)
        case (.zoomIn, .frontmost): return .none

        // → walks into an app from any focus; from a chosen app it walks on to the next.
        case (.stepIn, _): return .focus(.app)

        case (.stepBack, .app): return .focus(.global)
        case (.stepBack, .global), (.stepBack, .frontmost): return .close
        }
    }
}
