import AppKit
import Foundation
import Testing

@testable import Context_Dock

// The bindings are what turn a pointer location back into the space the registry measured in.
// They are weak by design, so the tests that matter are the ones about absence: a window that
// went away must stop resolving rather than hand back a stale pair.

@MainActor
struct InspectRootBindingsTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    @Test func bindingResolvesTheWindowAndRootItWasGiven() {
        let bindings = InspectRootBindings()
        let window = makeWindow()
        let root = window.contentView!

        bindings.bind(windowID: InspectWindowID(rawValue: 11), window: window, rootView: root)

        let resolved = bindings.binding(for: InspectWindowID(rawValue: 11))
        #expect(resolved?.window === window)
        #expect(resolved?.rootView === root)
    }

    @Test func unbindingRemovesOnlyThatWindow() {
        let bindings = InspectRootBindings()
        let first = makeWindow()
        let second = makeWindow()

        bindings.bind(windowID: InspectWindowID(rawValue: 1), window: first, rootView: first.contentView!)
        bindings.bind(windowID: InspectWindowID(rawValue: 2), window: second, rootView: second.contentView!)
        bindings.unbind(windowID: InspectWindowID(rawValue: 1))

        #expect(bindings.binding(for: InspectWindowID(rawValue: 1)) == nil)
        #expect(bindings.binding(for: InspectWindowID(rawValue: 2)) != nil)
        #expect(bindings.boundWindowIDs() == [InspectWindowID(rawValue: 2)])
    }

    @Test func rebindingReplacesTheEarlierBindingForThatWindowID() {
        let bindings = InspectRootBindings()
        let window = makeWindow()
        let firstRoot = window.contentView!
        let secondRoot = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(secondRoot)

        bindings.bind(windowID: InspectWindowID(rawValue: 7), window: window, rootView: firstRoot)
        bindings.bind(windowID: InspectWindowID(rawValue: 7), window: window, rootView: secondRoot)

        #expect(bindings.binding(for: InspectWindowID(rawValue: 7))?.rootView === secondRoot)
        #expect(bindings.boundWindowIDs().count == 1)
    }

    @Test func registryEnumeratesEveryWindowThatHasRegistrations() {
        let registry = InspectRegistry()
        registry.upsert(makeRegistration(window: 1, id: .generalChat.thread))
        registry.upsert(makeRegistration(window: 1, id: .generalChat.input))
        registry.upsert(makeRegistration(window: 2, id: .contextDockChat.thread))

        #expect(Set(registry.windowIDs().map(\.rawValue)) == [1, 2])
    }

    @Test func purgingAWindowRemovesItFromTheEnumeration() {
        let registry = InspectRegistry()
        registry.upsert(makeRegistration(window: 1, id: .generalChat.thread))
        registry.upsert(makeRegistration(window: 2, id: .contextDockChat.thread))

        registry.purge(windowID: InspectWindowID(rawValue: 1))

        #expect(registry.windowIDs() == [InspectWindowID(rawValue: 2)])
    }

    @Test func registryLooksUpAnExactKeyAndMissesAStaleToken() {
        let registry = InspectRegistry()
        let registration = makeRegistration(window: 3, id: .generalChat.thread)
        registry.upsert(registration)

        #expect(registry.registration(for: registration.key) == registration)

        let staleKey = InspectRegistryKey(
            windowID: registration.key.windowID,
            id: registration.key.id,
            instanceToken: UUID()
        )
        #expect(registry.registration(for: staleKey) == nil)
    }

    private func makeRegistration(window: Int, id: InspectID) -> InspectRegistration {
        InspectRegistration(
            key: InspectRegistryKey(
                windowID: InspectWindowID(rawValue: window),
                id: id,
                instanceToken: UUID()
            ),
            frameInWindowRoot: CGRect(x: 0, y: 0, width: 100, height: 40),
            source: InspectSource(file: "Developer/Test.swift", line: 1, type: "body"),
            depth: 0
        )
    }
}
