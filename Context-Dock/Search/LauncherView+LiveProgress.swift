// LauncherView+LiveProgress.swift
// Context-Dock
//
// Where the live activity block is drawn while a turn runs.
//
// It used to be a sibling appended after the whole message list. The assistant message is
// added as soon as streaming starts, so the answer rendered above while the activity stayed
// pinned below — and when the turn ended that block was destroyed and a *different* collapsed
// one (`routerTraceView`) was drawn inside the message. Two views, two places, no shared
// identity, which is why the reasoning read as arriving after the result.
//
// Now the steps are handed to the message that is being written, so they appear above the
// answer and collapse in place when it lands. These decide when that is possible: until there
// is an assistant message to hand them to, the trailing block is still the right place,
// because the end of the list is exactly where the answer will appear.

import Foundation

extension LauncherView {


    // MARK: - Context Dock chat




    // MARK: - General chat


}
