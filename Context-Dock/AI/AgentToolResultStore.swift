// AgentToolResultStore.swift
// Context-Dock
//
// Large tool payloads do not belong in every later model round. Keep the complete result
// on disk and put only a bounded preview plus an opaque reference into the conversation.

import Foundation

enum AgentToolResultStore {
    static let offloadThreshold = 12_000
    static let previewLimit = 3_000
    static let maximumRead = 6_000

    private static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Context-Dock/tool-results")
    }

    /// Small results remain byte-for-byte unchanged, preserving prompt-cache stability.
    static func compactForModel(
        _ output: String,
        toolName: String,
        directory overrideDirectory: URL? = nil
    ) -> String {
        guard output.count > offloadThreshold else { return output }
        guard let id = store(output, directory: overrideDirectory) else {
            return boundedPrefix(output, limit: previewLimit)
                + "\n\n... (large result truncated because it could not be stored)"
        }
        let preview = boundedPrefix(output, limit: previewLimit)
        let bytes = output.lengthOfBytes(using: .utf8)
        return """
            \(preview)

            ... (large \(toolName) result offloaded)
            result_id: \(id)
            full_size: \(bytes) bytes
            Call read_tool_result with this result_id and an offset to read another bounded chunk.
            """
    }

    static func read(
        id: String,
        offset: Int,
        limit: Int,
        directory overrideDirectory: URL? = nil
    ) -> Result<String, Error> {
        guard UUID(uuidString: id) != nil else { return .failure(StoreError.invalidID) }
        let root = overrideDirectory ?? directory
        let url = root.appendingPathComponent(id).appendingPathExtension("txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(StoreError.notFound)
        }
        let safeOffset = min(max(offset, 0), text.count)
        let safeLimit = min(max(limit, 1), maximumRead)
        let start = text.index(text.startIndex, offsetBy: safeOffset)
        let length = min(safeLimit, text.distance(from: start, to: text.endIndex))
        let end = text.index(start, offsetBy: length)
        let chunk = String(text[start..<end])
        let nextOffset = safeOffset + chunk.count
        let suffix = nextOffset < text.count
            ? "\n\n[More available: call read_tool_result with offset \(nextOffset).]"
            : "\n\n[End of stored result.]"
        return .success(chunk + suffix)
    }

    private static func store(_ output: String, directory overrideDirectory: URL?) -> String? {
        let root = overrideDirectory ?? directory
        let id = UUID().uuidString.lowercased()
        let url = root.appendingPathComponent(id).appendingPathExtension("txt")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try output.write(to: url, atomically: true, encoding: .utf8)
            return id
        } catch {
            return nil
        }
    }

    private static func boundedPrefix(_ text: String, limit: Int) -> String {
        let head = String(text.prefix(limit))
        guard let lineBreak = head.lastIndex(of: "\n"),
              head.distance(from: head.startIndex, to: lineBreak) > limit / 2
        else { return head }
        return String(head[..<lineBreak])
    }

    enum StoreError: LocalizedError {
        case invalidID
        case notFound

        var errorDescription: String? {
            switch self {
            case .invalidID: return "The tool-result reference is invalid."
            case .notFound: return "That stored tool result is no longer available."
            }
        }
    }
}
