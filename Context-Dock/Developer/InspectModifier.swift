import SwiftUI

#if DEBUG
import AppKit

struct InspectModifierIdentity {
    let instanceToken: UUID

    init(instanceToken: UUID = UUID()) {
        self.instanceToken = instanceToken
    }

    func registration(
        windowID: InspectWindowID,
        id: InspectID,
        frame: CGRect,
        source: InspectSource,
        depth: Int
    ) -> InspectRegistration {
        InspectRegistration(
            key: InspectRegistryKey(windowID: windowID, id: id, instanceToken: instanceToken),
            frameInWindowRoot: frame,
            source: source,
            depth: depth
        )
    }
}

struct InspectCallSite: Equatable {
    let source: InspectSource

    init(file: String, line: Int, type: String) {
        source = InspectSource(file: file, line: line, type: type)
    }
}

private enum InspectCoordinateSpace {
    static let windowRoot = "dorax.developer-inspector.window-root"
}

private struct InspectWindowIDKey: EnvironmentKey {
    static let defaultValue: InspectWindowID? = nil
}

private extension EnvironmentValues {
    var inspectWindowID: InspectWindowID? {
        get { self[InspectWindowIDKey.self] }
        set { self[InspectWindowIDKey.self] = newValue }
    }
}

private struct InspectViewModifier: ViewModifier {
    let id: InspectID
    let source: InspectSource
    let depth: Int

    @Environment(\.inspectWindowID) private var windowID
    @State private var identity = InspectModifierIdentity()
    @State private var frameInWindowRoot = CGRect.zero

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(id.rawValue)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(InspectCoordinateSpace.windowRoot))
            } action: { newFrame in
                frameInWindowRoot = newFrame
                upsert(frame: newFrame, windowID: windowID)
            }
            .onChange(of: windowID) { oldWindowID, newWindowID in
                if let oldWindowID, oldWindowID != newWindowID {
                    InspectRegistry.shared.remove(
                        windowID: oldWindowID,
                        id: id,
                        instanceToken: identity.instanceToken
                    )
                }
                upsert(frame: frameInWindowRoot, windowID: newWindowID)
            }
            .onDisappear {
                guard let windowID else { return }
                InspectRegistry.shared.remove(
                    windowID: windowID,
                    id: id,
                    instanceToken: identity.instanceToken
                )
            }
    }

    private func upsert(frame: CGRect, windowID: InspectWindowID?) {
        guard let windowID else { return }
        InspectRegistry.shared.upsert(
            identity.registration(
                windowID: windowID,
                id: id,
                frame: frame,
                source: source,
                depth: depth
            )
        )
    }
}

private struct InspectRootModifier: ViewModifier {
    @State private var windowID: InspectWindowID?

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: InspectCoordinateSpace.windowRoot)
            .environment(\.inspectWindowID, windowID)
            .background(InspectWindowReader(windowID: $windowID))
    }
}

private struct InspectWindowReader: NSViewRepresentable {
    @Binding var windowID: InspectWindowID?

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindowChange = report
        return view
    }

    func updateNSView(_ view: WindowReportingView, context: Context) {
        view.onWindowChange = report
        view.reportCurrentWindow()
    }

    /// Publishes the window id and, alongside it, the AppKit pair the session needs to convert
    /// a screen point into the space these frames were measured in.
    ///
    /// The root is the window's `contentView` — the same view the named coordinate space is
    /// established on. Substituting any other view would put the conversion in a different
    /// space from the measurement, which is the failure this subsystem exists to avoid.
    private func report(_ view: WindowReportingView) {
        let window = view.window
        let newValue = window.map { InspectWindowID(rawValue: $0.windowNumber) }

        // A root that left its window takes its registrations with it. Window teardown gives
        // no ordering guarantee for descendant `onDisappear`, so the purge is unconditional.
        if let previous = windowID, previous != newValue {
            InspectRootBindings.shared.unbind(windowID: previous)
            InspectRegistry.shared.purge(windowID: previous)
        }

        if let newValue, let window, let root = window.contentView {
            InspectRootBindings.shared.bind(windowID: newValue, window: window, rootView: root)
        }

        guard newValue != windowID else { return }
        DispatchQueue.main.async {
            windowID = newValue
        }
    }

    final class WindowReportingView: NSView {
        var onWindowChange: ((WindowReportingView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportCurrentWindow()
        }

        func reportCurrentWindow() {
            onWindowChange?(self)
        }
    }
}
#endif

extension View {
    @ViewBuilder
    func doraxInspect(
        _ id: InspectID,
        file: String = #fileID,
        line: Int = #line,
        type: String = #function,
        depth: Int = 0
    ) -> some View {
        #if DEBUG
        modifier(
            InspectViewModifier(
                id: id,
                source: InspectSource(file: file, line: line, type: type),
                depth: depth
            )
        )
        #else
        accessibilityIdentifier(id.rawValue)
        #endif
    }

    @ViewBuilder
    func doraxInspectionRoot() -> some View {
        #if DEBUG
        modifier(InspectRootModifier())
        #else
        self
        #endif
    }
}
