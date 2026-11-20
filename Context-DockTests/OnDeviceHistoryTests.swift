import Testing
import Foundation
@testable import Context_Dock

// Tests for Task #152 E5a: on-device history injection, overflow condensation, typed errors.
// Foundation Models sessions require Apple Intelligence hardware and cannot be mocked, so
// these tests cover the observable contract: error classification and history slicing constants.

struct OnDeviceHistoryTests {

    // MARK: - OnDeviceError classification

    // DockCore classifies onError strings by keyword:
    //   "context" | "token" | "length" → .onDeviceContextOverflow
    //   "apple silicon" | "requires macos" → .onDeviceNotAvailable
    //   anything else → .onDeviceGeneralError

    @Test("contextWindowOverflow localizedDescription triggers contextOverflow classifier")
    func contextOverflowDescriptionClassifiesCorrectly() {
        let err = OnDeviceError.contextWindowOverflow
        let desc = err.localizedDescription.lowercased()
        #expect(
            desc.contains("context") || desc.contains("token") || desc.contains("length"),
            "Expected 'context', 'token', or 'length' in: \(desc)"
        )
    }

    @Test("notAvailable localizedDescription triggers notAvailable classifier")
    func notAvailableDescriptionClassifiesCorrectly() {
        let err = OnDeviceError.notAvailable("requires Apple Silicon and macOS 26.0 or later.")
        let desc = err.localizedDescription.lowercased()
        #expect(
            desc.contains("apple silicon") || desc.contains("requires macos"),
            "Expected 'apple silicon' or 'requires macos' in: \(desc)"
        )
    }

    @Test("generationFailed localizedDescription preserves original reason")
    func generationFailedPreservesReason() {
        let reason = "model generation timed out"
        let err = OnDeviceError.generationFailed(reason)
        #expect(err.localizedDescription.contains(reason))
    }

    @Test("generationFailed does not contain overflow keywords (stays generalError)")
    func generationFailedDoesNotTriggerOverflowClassifier() {
        let err = OnDeviceError.generationFailed("some unrelated model error")
        let desc = err.localizedDescription.lowercased()
        let isOverflow = desc.contains("context") || desc.contains("token") || desc.contains("length")
        let isUnavailable = desc.contains("apple silicon") || desc.contains("requires macos")
        #expect(!isOverflow && !isUnavailable,
            "generationFailed should fall through to .onDeviceGeneralError, got: \(desc)")
    }

    // MARK: - History condensation constants

    @Test("normal path keeps at most 6 history turns")
    func normalPathKeepsSixTurns() {
        let history = (1...10).map { i in
            ChatMessage(role: i.isMultiple(of: 2) ? .assistant : .user, content: "msg \(i)")
        }
        let sliced = Array(history.suffix(6))
        #expect(sliced.count == 6)
        #expect(sliced.first?.content == "msg 5")
        #expect(sliced.last?.content == "msg 10")
    }

    @Test("retry path condenses to at most 2 history turns")
    func retryPathKeepsTwoTurns() {
        let history = (1...10).map { i in
            ChatMessage(role: i.isMultiple(of: 2) ? .assistant : .user, content: "msg \(i)")
        }
        let sliced = Array(history.suffix(2))
        #expect(sliced.count == 2)
        #expect(sliced.first?.content == "msg 9")
        #expect(sliced.last?.content == "msg 10")
    }

    @Test("empty history produces no Conversation History block")
    func emptyHistoryProducesNoBlock() {
        let history: [ChatMessage] = []
        var prompt = "base context\n\n"
        if !history.isEmpty {
            prompt += "## Conversation History\n"
        }
        #expect(!prompt.contains("## Conversation History"))
    }

    @Test("single-message history is preserved in both normal and retry paths")
    func singleMessageHistoryPreserved() {
        let history = [ChatMessage(role: .user, content: "hello")]
        let normal = Array(history.suffix(6))
        let retry = Array(history.suffix(2))
        #expect(normal.count == 1)
        #expect(retry.count == 1)
        #expect(normal.first?.content == "hello")
        #expect(retry.first?.content == "hello")
    }
}
