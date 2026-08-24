import Foundation
import Testing

@testable import Context_Dock

struct AgentToolResultStoreTests {
    @Test func resultReaderSurvivesAggressiveToolTrimming() {
        var tools: [[String: Any]] = (0..<30).map { index in
            [
                "type": "function",
                "function": ["name": "irrelevant_\(index)", "description": "unrelated"],
            ]
        }
        tools.append([
            "type": "function",
            "function": ["name": "read_tool_result", "description": "read stored output"],
        ])
        let trimmed = AIToolBudget.trim(
            tools, query: "summarize records", provider: .onDevice)
        #expect(trimmed.contains { AIToolBudget.toolName($0) == "read_tool_result" })
        #expect(trimmed.count <= AIToolBudget.maxTools(for: .onDevice))
    }

    @Test func smallResultsStayInlineWithoutCreatingAFile() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = "three useful rows"
        #expect(AgentToolResultStore.compactForModel(
            output, toolName: "test", directory: root) == output)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func largeResultsBecomeBoundedReadableReferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = (0..<1_500).map { "record \($0): useful payload" }.joined(separator: "\n")

        let compacted = AgentToolResultStore.compactForModel(
            output, toolName: "records.list", directory: root)

        #expect(compacted.count < AgentToolResultStore.offloadThreshold)
        #expect(compacted.contains("large records.list result offloaded"))
        let idLine = try #require(
            compacted.split(separator: "\n").first { $0.hasPrefix("result_id: ") })
        let id = idLine.replacingOccurrences(of: "result_id: ", with: "")
        let first = try AgentToolResultStore.read(
            id: id, offset: 0, limit: 500, directory: root).get()
        #expect(first.contains("record 0"))
        #expect(first.contains("More available"))
        #expect(first.count < 700)
    }

    @Test func readersRejectPaths() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let invalid = AgentToolResultStore.read(
            id: "../../secret", offset: 0, limit: 99_999, directory: root)
        #expect(throws: AgentToolResultStore.StoreError.self) { try invalid.get() }
    }
}
