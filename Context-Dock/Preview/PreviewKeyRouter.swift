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

}
