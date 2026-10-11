// LauncherApprovalSubscriptions.swift
// Context-Dock
//
// The dock's approval and status subscriptions, as one modifier instead of six.
//
// This exists for the compiler, not for the reader. `LauncherView.body` ended in six chained
// `.onReceive` calls, and each one wraps its input in another `SubscriptionView<…>`, so the
// body's opaque type carried six more layers on top of an already deep chain of `some View`
// properties. Lowering it aborts:
//
//     Abort: substOpaqueTypesWithUnderlyingTypes at TypeSubstitution.cpp:1077
//             Possible non-terminating type substitution detected
//
// which is why no Release build has been produced since July (#25). The substituted type the
// compiler printed on the way down was `SubscriptionView<Published.Publisher<…>>` — these.
//
// A `ViewModifier` is a nominal type. `body` now ends in one `ModifiedContent<_, _>` rather
// than six nested subscriptions, and the six live inside this struct's own body, which is a
// different function to lower. Five levels of nesting leave the body's type without a single
// `AnyView` and without a re-render cost — the subscriptions, their publishers and their
// handlers are exactly what they were.
//
// The handlers stay closures written in `LauncherView.body` because that is the only place
// with access to its state; this type holds no state and decides nothing.
import Combine
import SwiftUI

struct LauncherApprovalSubscriptions<
    AdapterRequest, CapabilityRequest, PrivacyRequest, CommandRequest, RunningCommand
>: ViewModifier {
    let adapter: AnyPublisher<AdapterRequest, Never>
    let onAdapter: (AdapterRequest) -> Void

    let capability: AnyPublisher<CapabilityRequest, Never>
    let onCapability: (CapabilityRequest) -> Void

    let privacy: AnyPublisher<PrivacyRequest, Never>
    let onPrivacy: (PrivacyRequest) -> Void

    let command: AnyPublisher<CommandRequest, Never>
    let onCommand: (CommandRequest) -> Void

    /// The same publisher as `capability`, watched a second time for a different reason: one
    /// call draws the card, this one keeps the chat's status line honest while the card is up.
    let capabilityStatus: AnyPublisher<CapabilityRequest, Never>
    let onCapabilityStatus: (CapabilityRequest) -> Void

    let runningCommand: AnyPublisher<RunningCommand, Never>
    let onRunningCommand: (RunningCommand) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(adapter, perform: onAdapter)
            .onReceive(capability, perform: onCapability)
            .onReceive(privacy, perform: onPrivacy)
            .onReceive(command, perform: onCommand)
            .onReceive(capabilityStatus, perform: onCapabilityStatus)
            .onReceive(runningCommand, perform: onRunningCommand)
    }
}
