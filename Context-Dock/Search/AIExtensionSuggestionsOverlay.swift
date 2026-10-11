// AIExtensionSuggestionsOverlay.swift
// Context-Dock
//
// The AI suggestions sheet that sits over the launcher, as a type of its own.
//
// It lived inline in `LauncherView.body`, and that is why the Release build could not be
// made. Under `-O` with cross-module optimisation the compiler aborts in
// `substOpaqueTypesWithUnderlyingTypes` — "Possible non-terminating type substitution
// detected" — while lowering `LauncherView.body`, and the AST it prints on the way down ends
// at `View._trait` applied to `AIModeView` with `TransitionTraitKey`: this `.transition`, on
// this view, inside a body already built from hundreds of opaque modifier types.
//
// A named struct is a nominal type. The chain of `some View` inside it terminates here
// instead of unrolling into the body that contains it, which is what the compiler could not
// finish. Nothing about what is drawn changes.
import SwiftUI

struct AIExtensionSuggestionsOverlay: View {
    @Binding var currentContext: AppUserContext
    @Binding var isVisible: Bool

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.3)) {
                        isVisible = false
                    }
                }

            // AI Suggestions View
            AIModeView(
                currentContext: $currentContext,
                isVisible: $isVisible
            )
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}
