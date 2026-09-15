import AppKit
import Testing

@testable import Context_Dock

@MainActor
struct InspectCoordinateTests {
    private let windowID = InspectWindowID(rawValue: 7)
    private let source = InspectSource(file: "Search/Test.swift", line: 1, type: "body")

    private func registration(
        id: InspectID = .generalChat.thread,
        token: UUID = UUID(),
        windowID: InspectWindowID? = nil,
        frame: CGRect,
        depth: Int = 0
    ) -> InspectRegistration {
        InspectRegistration(
            key: InspectRegistryKey(
                windowID: windowID ?? self.windowID,
                id: id,
                instanceToken: token
            ),
            frameInWindowRoot: frame,
            source: source,
            depth: depth
        )
    }

    private func window(origin: CGPoint, rootOrigin: CGPoint = .zero) -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: 400, height: 300)),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let root = NSView(frame: CGRect(origin: rootOrigin, size: CGSize(width: 300, height: 200)))
        container.addSubview(root)
        window.contentView = container
        return (window, root)
    }

    @Test func smallestContainingRegionWins() {
        let registry = InspectRegistry()
        let ancestor = registration(frame: CGRect(x: 0, y: 0, width: 200, height: 200), depth: 0)
        let child = registration(
            id: .generalChat.input,
            frame: CGRect(x: 25, y: 25, width: 50, height: 30),
            depth: 1
        )
        registry.upsert(ancestor)
        registry.upsert(child)

        #expect(registry.hitTest(rootPoint: CGPoint(x: 40, y: 35), in: windowID)?.key == child.key)
    }

    @Test func equalAreaPrefersGreaterDepth() {
        let registry = InspectRegistry()
        let shallow = registration(frame: CGRect(x: 0, y: 0, width: 100, height: 100), depth: 1)
        let deep = registration(
            id: .generalChat.input,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            depth: 3
        )
        registry.upsert(shallow)
        registry.upsert(deep)

        #expect(registry.hitTest(rootPoint: CGPoint(x: 50, y: 50), in: windowID)?.key == deep.key)
    }

    @Test func remainingTieUsesIDThenToken() {
        let registry = InspectRegistry()
        let highToken = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let lowToken = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let thread = registration(
            id: .generalChat.thread,
            token: lowToken,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            depth: 1
        )
        let firstInput = registration(
            id: .generalChat.input,
            token: highToken,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            depth: 1
        )
        let secondInput = registration(
            id: .generalChat.input,
            token: lowToken,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            depth: 1
        )
        registry.upsert(thread)
        registry.upsert(firstInput)
        registry.upsert(secondInput)

        #expect(registry.hitTest(rootPoint: CGPoint(x: 50, y: 50), in: windowID)?.key == secondInput.key)
    }

    @Test func pointOutsideEveryRegionReturnsNil() {
        let registry = InspectRegistry()
        registry.upsert(registration(frame: CGRect(x: 0, y: 0, width: 20, height: 20)))

        #expect(registry.hitTest(rootPoint: CGPoint(x: 30, y: 30), in: windowID) == nil)
    }

    @Test func registrationsFromAnotherWindowNeverMatch() {
        let registry = InspectRegistry()
        let otherWindow = InspectWindowID(rawValue: 8)
        registry.upsert(registration(windowID: otherWindow, frame: CGRect(x: 0, y: 0, width: 100, height: 100)))

        #expect(registry.hitTest(rootPoint: CGPoint(x: 50, y: 50), in: windowID) == nil)
    }

    @Test func nonZeroScreenOriginConvertsToWindowRoot() {
        let (window, root) = window(origin: CGPoint(x: 100, y: 200))

        let point = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: CGPoint(x: 145, y: 260),
            window: window,
            rootView: root
        )

        #expect(abs(point.x - 45) < 0.001)
        #expect(abs(point.y - 60) < 0.001)
    }

    @Test func offsetRootViewIsAppliedAfterWindowConversion() {
        let (window, root) = window(origin: CGPoint(x: 100, y: 200), rootOrigin: CGPoint(x: 20, y: 30))

        let point = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: CGPoint(x: 150, y: 270),
            window: window,
            rootView: root
        )

        #expect(abs(point.x - 30) < 0.001)
        #expect(abs(point.y - 40) < 0.001)
    }

    @Test func differentWindowsProduceDifferentRootPoints() {
        let (firstWindow, firstRoot) = window(origin: CGPoint(x: 100, y: 100))
        let (secondWindow, secondRoot) = window(origin: CGPoint(x: 250, y: 200))
        let screenPoint = CGPoint(x: 300, y: 260)

        let first = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint, window: firstWindow, rootView: firstRoot
        )
        let second = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint, window: secondWindow, rootView: secondRoot
        )

        #expect(first != second)
    }

    @Test func screenConversionRoundTripsThroughTheRootView() {
        let (window, root) = window(origin: CGPoint(x: 130, y: 240), rootOrigin: CGPoint(x: 15, y: 25))
        let rootPoint = CGPoint(x: 35, y: 45)
        let windowPoint = root.convert(rootPoint, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        let converted = InspectCoordinateConverter.windowRootPoint(
            fromScreenPoint: screenPoint,
            window: window,
            rootView: root
        )

        #expect(abs(converted.x - rootPoint.x) < 0.001)
        #expect(abs(converted.y - rootPoint.y) < 0.001)
    }
}
