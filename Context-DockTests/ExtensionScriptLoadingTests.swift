// Context-DockTests/ExtensionScriptLoadingTests.swift
//
// Where an installed extension's script comes from: its script file, or the script embedded
// in its metadata. An empty script path used to wipe the embedded script, so the extension
// ran and did nothing.

import Foundation
import Testing

@testable import Context_Dock

@Suite("Extension script loading")
struct ExtensionScriptLoadingTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("An empty script path keeps the embedded script")
    func emptyPathKeepsEmbedded() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LayeredExtensionManager.scriptContent(
            embedded: "echo hi", scriptPath: "", folder: dir) == "echo hi")
    }

    @Test("A readable script file wins over the embedded script")
    func scriptFileWins() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "echo from file".write(
            to: dir.appendingPathComponent("script.sh"), atomically: true, encoding: .utf8)
        #expect(LayeredExtensionManager.scriptContent(
            embedded: "echo hi", scriptPath: "script.sh", folder: dir) == "echo from file")
    }

    @Test("A missing script file keeps the embedded script")
    func missingFileKeepsEmbedded() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LayeredExtensionManager.scriptContent(
            embedded: "echo hi", scriptPath: "gone.sh", folder: dir) == "echo hi")
    }
}
