import Testing

@testable import Context_Dock

struct InspectIDTests {
    @Test func p0VocabularyIsUnique() {
        let values = InspectID.allCases.map(\.rawValue)

        #expect(Set(values).count == values.count)
    }

    @Test func p0VocabularyContainsTheApprovedFeatureBoundaries() {
        #expect(InspectID.allCases.contains(.generalChat.thread))
        #expect(InspectID.allCases.contains(.generalChat.input))
        #expect(InspectID.allCases.contains(.generalChat.send))
        #expect(InspectID.allCases.contains(.contextDockChat.thread))
        #expect(InspectID.allCases.contains(.shared.messageBubble))
        #expect(InspectID.allCases.contains(.shared.codeBlock))
    }
}
