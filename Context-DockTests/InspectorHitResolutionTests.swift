import AppKit
import Foundation
import Testing

@testable import Context_Dock

// The screen-to-root path is the one place this subsystem can be quietly, permanently wrong:
// SwiftUI's `.global` space is not macOS screen space, and conflating them produces hit testing
// that looks random and is nearly impossible to diagnose from the symptom. These tests drive
// the real AppKit conversion with real windows rather than re-deriving the arithmetic, so a
// change to the conversion cannot pass by also changing the test's copy of the maths.

@MainActor
struct InspectorHitResolutionTests {
    private func makeWindow(origin: CGPoint) -> NSWindow {
        NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: 500, height: 400)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    @Test func aScreenPointResolvesToTheSmallestRegisteredRegionInThatWindow() {
        let window = makeWindow(origin: CGPoint(x: 200, y: 150))
        let root = window.contentView!
        let registry = InspectRegistry()
        let windowID = InspectWindowID(rawValue: 61)

        let outerToken = UUID()
        let innerToken = UUID()
        registry.upsert(
            registration(
                windowID, .generalChat.thread,
                CGRect(x: 0, y: 0, width: 400, height: 300), outerToken, depth: 0
            )
        )
        registry.upsert(
            registration(
                windowID, .generalChat.input,
                CGRect(x: 20, y: 40, width: 120, height: 60), innerToken, depth: 1
            )
        )

        let rootPoint = CGPoint(x: 60, y: 70)
        let screenPoint = window.convertPoint(toScreen: root.convert(rootPoint, to: nil))
        let resolvedRoot = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint, window: window, rootView: root
        )

        #expect(abs(resolvedRoot.x - rootPoint.x) < 0.001)
        #expect(abs(resolvedRoot.y - rootPoint.y) < 0.001)
        #expect(registry.hitTest(rootPoint: resolvedRoot, in: windowID)?.key.instanceToken == innerToken)
    }

    @Test func aPointInsideOnlyTheAncestorResolvesToTheAncestor() {
        let window = makeWindow(origin: CGPoint(x: 40, y: 60))
        let root = window.contentView!
        let registry = InspectRegistry()
        let windowID = InspectWindowID(rawValue: 62)

        let outerToken = UUID()
        registry.upsert(
            registration(
                windowID, .generalChat.thread,
                CGRect(x: 0, y: 0, width: 400, height: 300), outerToken, depth: 0
            )
        )
        registry.upsert(
            registration(
                windowID, .generalChat.input,
                CGRect(x: 20, y: 40, width: 120, height: 60), UUID(), depth: 1
            )
        )

        let rootPoint = CGPoint(x: 300, y: 250)
        let screenPoint = window.convertPoint(toScreen: root.convert(rootPoint, to: nil))
        let resolvedRoot = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint, window: window, rootView: root
        )

        #expect(registry.hitTest(rootPoint: resolvedRoot, in: windowID)?.key.instanceToken == outerToken)
    }

    @Test func twoWindowsAtDifferentOriginsResolveOneScreenPointDifferently() {
        let first = makeWindow(origin: CGPoint(x: 0, y: 0))
        let second = makeWindow(origin: CGPoint(x: 300, y: 200))
        let screenPoint = CGPoint(x: 320, y: 240)

        let firstRoot = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint, window: first, rootView: first.contentView!
        )
        let secondRoot = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint, window: second, rootView: second.contentView!
        )

        #expect(firstRoot != secondRoot)
    }

    @Test func aPointOutsideEveryRegionResolvesToNothing() {
        let registry = InspectRegistry()
        let windowID = InspectWindowID(rawValue: 63)
        registry.upsert(
            registration(
                windowID, .generalChat.thread,
                CGRect(x: 0, y: 0, width: 100, height: 100), UUID(), depth: 0
            )
        )

        #expect(registry.hitTest(rootPoint: CGPoint(x: 400, y: 380), in: windowID) == nil)
    }

    @Test func aWindowWithNoLiveBindingProducesNoHit() {
        let registry = InspectRegistry()
        let bindings = InspectRootBindings()
        let windowID = InspectWindowID(rawValue: 64)
        registry.upsert(
            registration(
                windowID, .generalChat.thread,
                CGRect(x: 0, y: 0, width: 400, height: 300), UUID(), depth: 0
            )
        )

        let controller = InspectorSessionController(registry: registry, bindings: bindings)

        // No binding was ever made, so there is no root space to convert into. The session
        // fails closed rather than approximating with screen coordinates.
        #expect(controller.resolveHit(atScreenPoint: CGPoint(x: 10, y: 10)) == nil)
    }

    private func registration(
        _ windowID: InspectWindowID,
        _ id: InspectID,
        _ frame: CGRect,
        _ token: UUID,
        depth: Int
    ) -> InspectRegistration {
        InspectRegistration(
            key: InspectRegistryKey(windowID: windowID, id: id, instanceToken: token),
            frameInWindowRoot: frame,
            source: InspectSource(file: "Developer/Test.swift", line: 1, type: "body"),
            depth: depth
        )
    }
}
