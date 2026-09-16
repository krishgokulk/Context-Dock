import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct InspectRegistryTests {
    private let window = InspectWindowID(rawValue: 41)
    private let source = InspectSource(file: "Search/TestSurface.swift", line: 12, type: "body")

    private func registration(
        token: UUID = UUID(),
        windowID: InspectWindowID? = nil,
        id: InspectID = .generalChat.message,
        x: CGFloat = 0,
        y: CGFloat = 0,
        width: CGFloat = 100,
        height: CGFloat = 40,
        depth: Int = 0
    ) -> InspectRegistration {
        InspectRegistration(
            key: InspectRegistryKey(
                windowID: windowID ?? window,
                id: id,
                instanceToken: token
            ),
            frameInWindowRoot: CGRect(x: x, y: y, width: width, height: height),
            source: source,
            depth: depth
        )
    }

    @Test func twentyInstancesOfOneIDCoexist() {
        let registry = InspectRegistry()

        for offset in 0..<20 {
            registry.upsert(registration(y: CGFloat(offset * 50)))
        }

        #expect(registry.registrations(in: window).count == 20)
    }

    @Test func removingOneInstanceLeavesTheOtherNineteen() {
        let registry = InspectRegistry()
        let tokens = (0..<20).map { _ in UUID() }
        for (offset, token) in tokens.enumerated() {
            registry.upsert(registration(token: token, y: CGFloat(offset * 50)))
        }

        registry.remove(windowID: window, id: .generalChat.message, instanceToken: tokens[7])

        let remaining = registry.registrations(in: window)
        #expect(remaining.count == 19)
        #expect(!remaining.contains { $0.key.instanceToken == tokens[7] })
    }

    @Test func staleRemovalCannotDeleteAReplacementInstance() {
        let registry = InspectRegistry()
        let staleToken = UUID()
        let replacementToken = UUID()
        registry.upsert(registration(token: staleToken, y: 10))
        registry.upsert(registration(token: replacementToken, y: 20))

        registry.remove(windowID: window, id: .generalChat.message, instanceToken: staleToken)

        let remaining = registry.registrations(in: window)
        #expect(remaining.count == 1)
        #expect(remaining.first?.key.instanceToken == replacementToken)
    }

    @Test func purgingAWindowRemovesOnlyThatWindowsEntries() {
        let registry = InspectRegistry()
        let otherWindow = InspectWindowID(rawValue: 99)
        registry.upsert(registration())
        registry.upsert(registration(windowID: otherWindow))

        registry.purge(windowID: window)

        #expect(registry.registrations(in: window).isEmpty)
        #expect(registry.registrations(in: otherWindow).count == 1)
    }

    @Test func recreatingAWindowDoesNotRevivePurgedEntries() {
        let registry = InspectRegistry()
        let oldToken = UUID()
        let newToken = UUID()
        registry.upsert(registration(token: oldToken))
        registry.purge(windowID: window)

        registry.upsert(registration(token: newToken))

        let current = registry.registrations(in: window)
        #expect(current.count == 1)
        #expect(current.first?.key.instanceToken == newToken)
    }

    @Test func repeatedUpsertKeepsOnlyTheLatestGeometry() {
        let registry = InspectRegistry()
        let token = UUID()
        registry.upsert(registration(token: token, x: 10, y: 20))

        registry.upsert(registration(token: token, x: 70, y: 80))

        let current = registry.registrations(in: window)
        #expect(current.count == 1)
        #expect(current.first?.frameInWindowRoot == CGRect(x: 70, y: 80, width: 100, height: 40))
    }

    @Test func ordinalsFollowVerticalThenHorizontalFrameOrder() {
        let registry = InspectRegistry()
        let topRight = registration(token: UUID(), x: 200, y: 10)
        let bottom = registration(token: UUID(), x: 0, y: 200)
        let topLeft = registration(token: UUID(), x: 10, y: 10)
        registry.upsert(bottom)
        registry.upsert(topRight)
        registry.upsert(topLeft)

        #expect(registry.ordinal(for: topLeft.key) == 0)
        #expect(registry.ordinal(for: topRight.key) == 1)
        #expect(registry.ordinal(for: bottom.key) == 2)
    }

    @Test func geometryDoesNotAdvanceRevisionWhileEmissionIsDisabled() {
        let registry = InspectRegistry()
        let token = UUID()

        registry.upsert(registration(token: token, x: 10))
        registry.upsert(registration(token: token, x: 20))
        registry.remove(windowID: window, id: .generalChat.message, instanceToken: token)

        #expect(registry.revision == 0)
    }

    @Test func enabledEmissionAdvancesRevisionOnlyForRealChanges() {
        let registry = InspectRegistry()
        let token = UUID()
        let initial = registration(token: token, x: 10)
        registry.emitsChanges = true

        registry.upsert(initial)
        registry.upsert(initial)
        registry.upsert(registration(token: token, x: 20))
        registry.remove(windowID: window, id: .generalChat.message, instanceToken: UUID())
        registry.remove(windowID: window, id: .generalChat.message, instanceToken: token)

        #expect(registry.revision == 3)
    }
}
