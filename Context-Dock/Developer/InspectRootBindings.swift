#if DEBUG
import AppKit
import Foundation

/// Where a window's inspection root actually lives, so a screen point can be converted back
/// into the space the registry measured in.
///
/// The registry stores frames in a window's root coordinate space and deliberately knows
/// nothing about AppKit. Turning a pointer location into one of those frames needs the real
/// `NSWindow` and the real root `NSView`, and nothing else in the subsystem holds them.
///
/// References are weak on purpose. A window closing is ordinary, and the right response is for
/// its binding to disappear on its own rather than for something elsewhere to remember to call
/// `unbind` at exactly the right moment. A binding whose window has gone is indistinguishable
/// from one that was never made, which is the behaviour the session wants: fail closed, no
/// overlay, no hit.
@MainActor
final class InspectRootBindings {
    static let shared = InspectRootBindings()

    private struct Binding {
        weak var window: NSWindow?
        weak var rootView: NSView?

        var resolved: (window: NSWindow, rootView: NSView)? {
            guard let window, let rootView else { return nil }
            return (window, rootView)
        }
    }

    private var bindingsByWindowID: [InspectWindowID: Binding] = [:]

    init() {}

    func bind(windowID: InspectWindowID, window: NSWindow, rootView: NSView) {
        bindingsByWindowID[windowID] = Binding(window: window, rootView: rootView)
    }

    func unbind(windowID: InspectWindowID) {
        bindingsByWindowID.removeValue(forKey: windowID)
    }

    func binding(for windowID: InspectWindowID) -> (window: NSWindow, rootView: NSView)? {
        guard let resolved = bindingsByWindowID[windowID]?.resolved else {
            bindingsByWindowID.removeValue(forKey: windowID)
            return nil
        }
        return resolved
    }

    func boundWindowIDs() -> [InspectWindowID] {
        for (windowID, binding) in bindingsByWindowID where binding.resolved == nil {
            bindingsByWindowID.removeValue(forKey: windowID)
        }
        return bindingsByWindowID.keys.sorted { $0.rawValue < $1.rawValue }
    }
}
#endif
