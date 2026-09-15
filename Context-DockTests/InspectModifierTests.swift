import Foundation
import Testing

@testable import Context_Dock

@MainActor
struct InspectModifierTests {
    private let windowID = InspectWindowID(rawValue: 23)
    private let source = InspectSource(file: "Search/GeneralChatSurface.swift", line: 31, type: "body")

    @Test func injectedIdentitySurvivesRepeatedRegistrationUpdates() {
        let token = UUID()
        let identity = InspectModifierIdentity(instanceToken: token)

        let first = identity.registration(
            windowID: windowID,
            id: .generalChat.thread,
            frame: CGRect(x: 0, y: 0, width: 300, height: 200),
            source: source,
            depth: 0
        )
        let second = identity.registration(
            windowID: windowID,
            id: .generalChat.thread,
            frame: CGRect(x: 20, y: 30, width: 320, height: 240),
            source: source,
            depth: 0
        )

        #expect(first.key.instanceToken == token)
        #expect(second.key.instanceToken == token)
    }

    @Test func defaultIdentitiesAreDistinct() {
        #expect(InspectModifierIdentity().instanceToken != InspectModifierIdentity().instanceToken)
    }

    @Test func explicitCallSiteValuesFlowIntoSourceMetadata() {
        let callSite = InspectCallSite(file: "Search/GeneralChatSurface.swift", line: 31, type: "body")

        #expect(callSite.source == source)
    }
}
