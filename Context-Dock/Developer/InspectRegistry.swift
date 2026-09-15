#if DEBUG
import AppKit
import CoreGraphics
import Foundation

struct InspectWindowID: RawRepresentable, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

struct InspectSource: Equatable, Sendable {
    let file: String
    let line: Int
    let type: String
}

struct InspectRegistryKey: Hashable, Sendable {
    let windowID: InspectWindowID
    let id: InspectID
    let instanceToken: UUID
}

struct InspectRegistration: Equatable, Sendable {
    let key: InspectRegistryKey
    var frameInWindowRoot: CGRect
    var source: InspectSource
    var depth: Int
}

@MainActor
final class InspectRegistry {
    static let shared = InspectRegistry()

    var emitsChanges = false
    private(set) var revision: UInt64 = 0

    private var registrationsByKey: [InspectRegistryKey: InspectRegistration] = [:]

    func upsert(_ registration: InspectRegistration) {
        let changed = registrationsByKey[registration.key] != registration
        registrationsByKey[registration.key] = registration
        recordMutation(changed: changed)
    }

    func remove(windowID: InspectWindowID, id: InspectID, instanceToken: UUID) {
        let key = InspectRegistryKey(windowID: windowID, id: id, instanceToken: instanceToken)
        let changed = registrationsByKey.removeValue(forKey: key) != nil
        recordMutation(changed: changed)
    }

    func purge(windowID: InspectWindowID) {
        let keys = registrationsByKey.keys.filter { $0.windowID == windowID }
        guard !keys.isEmpty else { return }

        for key in keys {
            registrationsByKey.removeValue(forKey: key)
        }
        recordMutation(changed: true)
    }

    func registrations(in windowID: InspectWindowID) -> [InspectRegistration] {
        registrationsByKey.values
            .filter { $0.key.windowID == windowID }
            .sorted(by: Self.snapshotOrder)
    }

    /// Every window that currently holds at least one registration.
    ///
    /// Overlay reconciliation is derived from this: a window with no registrations is not
    /// eligible for an overlay, and a window that has gone away is not in the list at all.
    func windowIDs() -> [InspectWindowID] {
        let ids = Set(registrationsByKey.keys.map(\.windowID))
        return ids.sorted { $0.rawValue < $1.rawValue }
    }

    /// Exact-key lookup. A stale token misses rather than matching a replacement instance —
    /// the same property that makes `remove` safe when one of twenty messages disappears.
    func registration(for key: InspectRegistryKey) -> InspectRegistration? {
        registrationsByKey[key]
    }

    func ordinal(for key: InspectRegistryKey) -> Int? {
        registrationsByKey.values
            .filter { $0.key.windowID == key.windowID && $0.key.id == key.id }
            .sorted(by: Self.ordinalOrder)
            .firstIndex { $0.key == key }
    }

    func hitTest(rootPoint: CGPoint, in windowID: InspectWindowID) -> InspectRegistration? {
        registrationsByKey.values
            .filter {
                $0.key.windowID == windowID && $0.frameInWindowRoot.contains(rootPoint)
            }
            .sorted(by: Self.hitTestOrder)
            .first
    }

    private func recordMutation(changed: Bool) {
        guard changed, emitsChanges else { return }
        revision &+= 1
    }

    private static func snapshotOrder(_ lhs: InspectRegistration, _ rhs: InspectRegistration) -> Bool {
        if lhs.key.id.rawValue != rhs.key.id.rawValue {
            return lhs.key.id.rawValue < rhs.key.id.rawValue
        }
        return ordinalOrder(lhs, rhs)
    }

    private static func ordinalOrder(_ lhs: InspectRegistration, _ rhs: InspectRegistration) -> Bool {
        if lhs.frameInWindowRoot.minY != rhs.frameInWindowRoot.minY {
            return lhs.frameInWindowRoot.minY < rhs.frameInWindowRoot.minY
        }
        if lhs.frameInWindowRoot.minX != rhs.frameInWindowRoot.minX {
            return lhs.frameInWindowRoot.minX < rhs.frameInWindowRoot.minX
        }
        return lhs.key.instanceToken.uuidString < rhs.key.instanceToken.uuidString
    }

    private static func hitTestOrder(_ lhs: InspectRegistration, _ rhs: InspectRegistration) -> Bool {
        let lhsArea = abs(lhs.frameInWindowRoot.width * lhs.frameInWindowRoot.height)
        let rhsArea = abs(rhs.frameInWindowRoot.width * rhs.frameInWindowRoot.height)
        if lhsArea != rhsArea {
            return lhsArea < rhsArea
        }
        if lhs.depth != rhs.depth {
            return lhs.depth > rhs.depth
        }
        if lhs.key.id.rawValue != rhs.key.id.rawValue {
            return lhs.key.id.rawValue < rhs.key.id.rawValue
        }
        return lhs.key.instanceToken.uuidString < rhs.key.instanceToken.uuidString
    }
}

enum InspectCoordinateConverter {
    /// Converts a macOS screen point into the coordinate space used by registry frames.
    static func windowRootPoint(
        fromScreenPoint screenPoint: CGPoint,
        window: NSWindow,
        rootView: NSView
    ) -> CGPoint {
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return rootView.convert(windowPoint, from: nil)
    }
}
#endif
