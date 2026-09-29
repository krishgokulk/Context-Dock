import Foundation
import Testing

@testable import Context_Dock

// Output files (task 16c): a temp-directory fixture, no network, no real approval sheet.

struct OutputFileWriterTests {

    private static func makeFolder() -> (folder: URL, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("outputfiles-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        // Not created: `write` must create the outputs folder on first use.
        let folder = base.appendingPathComponent("Documents/DoraX Outputs")
        return (folder, { try? FileManager.default.removeItem(at: base) })
    }

    // MARK: - Names

    @Test func stemIsSanitised() throws {
        #expect(try OutputFileWriter.sanitisedStem("  Passport files ", format: .csv) == "Passport files")
        #expect(try OutputFileWriter.sanitisedStem("report.csv", format: .csv) == "report")
        #expect(try OutputFileWriter.sanitisedStem("REPORT.CSV", format: .csv) == "REPORT")
        #expect(try OutputFileWriter.sanitisedStem("v1.2 notes", format: .md) == "v1.2 notes")
        #expect(try OutputFileWriter.sanitisedStem(".hidden", format: .txt) == "hidden")
        #expect(try OutputFileWriter.sanitisedStem("a:b\u{7}c", format: .txt) == "a-bc")
        #expect(try OutputFileWriter.sanitisedStem(String(repeating: "x", count: 500), format: .md).count
            == OutputFileWriter.maxStemLength)
    }

    @Test func pathsAndEmptyNamesAreRefused() {
        for bad in ["../x", "a/b", "/etc/passwd", "..\\x", "sub/../x"] {
            #expect(throws: OutputFileWriter.Refusal.notAName) {
                try OutputFileWriter.sanitisedStem(bad, format: .md)
            }
        }
        for empty in ["", "   ", "..", "...", "."] {
            #expect(throws: OutputFileWriter.Refusal.emptyName) {
                try OutputFileWriter.sanitisedStem(empty, format: .md)
            }
        }
    }

    // MARK: - Formats and confinement

    @Test func onlyAllowListedFormatsWrite() throws {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        for good in ["md", "txt", "csv", "docx", ".CSV", " md "] {
            _ = try OutputFileWriter.write(name: "n-\(good.count)", format: good, content: "x", folder: folder)
        }
        for bad in ["sh", "exe", "app", "html", "", "md/../../x"] {
            #expect(throws: OutputFileWriter.Refusal.unsupportedFormat(bad)) {
                try OutputFileWriter.write(name: "n", format: bad, content: "x", folder: folder)
            }
        }
    }

    @Test func traversalNeverLeavesTheFolder() throws {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        let outside = folder.deletingLastPathComponent().appendingPathComponent("x.md")
        #expect(throws: OutputFileWriter.Refusal.notAName) {
            try OutputFileWriter.write(name: "../x", format: "md", content: "no", folder: folder)
        }
        #expect(throws: OutputFileWriter.Refusal.notAName) {
            try OutputFileWriter.write(name: "/tmp/x", format: "md", content: "no", folder: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func foldersAreCreatedOnFirstUse() throws {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let url = try OutputFileWriter.write(name: "a", format: "md", content: "hi", folder: folder)
        #expect(url.deletingLastPathComponent().path == folder.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func defaultFolderIsDocumentsDoraXOutputs() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(OutputFileWriter.defaultFolder(home: home).path == "/Users/me/Documents/DoraX Outputs")
    }

    // MARK: - Never overwrite

    @Test func existingNamesGetNumbered() throws {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        let first = try OutputFileWriter.write(name: "list", format: "csv", content: "one", folder: folder)
        let second = try OutputFileWriter.write(name: "list", format: "csv", content: "two", folder: folder)
        let third = try OutputFileWriter.write(name: "list.csv", format: "csv", content: "three", folder: folder)
        #expect(first.lastPathComponent == "list.csv")
        #expect(second.lastPathComponent == "list 2.csv")
        #expect(third.lastPathComponent == "list 3.csv")
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two")
        // Another format with the same stem is a different file.
        let md = try OutputFileWriter.write(name: "list", format: "md", content: "m", folder: folder)
        #expect(md.lastPathComponent == "list.md")
    }

    // MARK: - Contents

    @Test func plainTextFormatsAreByteExact() throws {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        let csv = "name,path\r\n\"Passport, scan\",/Users/me/a.pdf\r\nÜmlaut,é\r\n"
        let md = "# Title\n\n- one\n- **two**\n"
        let txt = "line one\n\nline three, no trailing newline"
        for (format, content) in [("csv", csv), ("md", md), ("txt", txt)] {
            let url = try OutputFileWriter.write(name: "t", format: format, content: content, folder: folder)
            #expect(try Data(contentsOf: url) == Data(content.utf8))
            #expect(url.pathExtension == format)
        }
    }

    @Test func oversizeContentIsRefused() {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        let big = String(repeating: "a", count: OutputFileWriter.maxContentBytes + 1)
        #expect(throws: OutputFileWriter.Refusal.tooLarge) {
            try OutputFileWriter.write(name: "big", format: "txt", content: big, folder: folder)
        }
    }

    // MARK: - docx

    @Test func docxIsAValidZipOfTheThreeParts() throws {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        let url = try OutputFileWriter.write(
            name: "memo", format: "docx", content: "Hello & <world>\n\nSecond \"line\"", folder: folder)
        let entries = try Self.readStoredZip(Data(contentsOf: url))
        #expect(entries.map(\.name) == ["[Content_Types].xml", "_rels/.rels", "word/document.xml"])
        for entry in entries {
            #expect(ZipWriter.crc32(entry.data) == entry.crc, "crc for \(entry.name)")
            // Every part is well-formed XML.
            let parser = XMLParser(data: entry.data)
            #expect(parser.parse(), "\(entry.name): \(String(describing: parser.parserError))")
        }
        let document = String(decoding: entries[2].data, as: UTF8.self)
        #expect(document.contains("Hello &amp; &lt;world&gt;"))
        #expect(document.contains("<w:p/>"))  // the blank line
        #expect(document.contains("Second &quot;line&quot;"))
    }

    @Test func crc32MatchesTheKnownCheckValue() {
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func docxDropsCharactersXMLCannotCarry() {
        #expect(DocxWriter.escape("a\u{0}b\u{8}c") == "abc")
    }

    /// A tiny reader for what ZipWriter emits (stored entries), walking the central directory.
    private static func readStoredZip(_ data: Data) throws -> [(name: String, crc: UInt32, data: Data)] {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        let end = bytes.count - 22
        #expect(u32(end) == 0x0605_4B50)
        let count = u16(end + 10)
        var cursor = Int(u32(end + 16))
        var out: [(String, UInt32, Data)] = []
        for _ in 0..<count {
            #expect(u32(cursor) == 0x0201_4B50)
            let method = u16(cursor + 10)
            #expect(method == 0)
            let crc = u32(cursor + 16)
            let size = Int(u32(cursor + 24))
            let nameLength = u16(cursor + 28)
            let local = Int(u32(cursor + 42))
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            #expect(u32(local) == 0x0403_4B50)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            out.append((name, crc, Data(bytes[start..<(start + size)])))
            cursor += 46 + nameLength + u16(cursor + 30) + u16(cursor + 32)
        }
        return out
    }
}

@MainActor
struct OutputFileToolTests {

    private static func makeFolder() -> (folder: URL, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("outputtool-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        return (base.appendingPathComponent("DoraX Outputs"), { try? FileManager.default.removeItem(at: base) })
    }

    @Test func isRegisteredAndRequiresAllThreeArguments() {
        let tool = AgentToolRegistry.shared.tool(named: "write_output_file")
        #expect(tool != nil)
        #expect(tool?.required == ["name", "format", "content"])
    }

    @Test func approvalIsRequired() {
        // The same question every approval path asks.
        #expect(OutputFileTool.capability().riskLevel.requiresApproval)
        #expect(ApprovalRisk(OutputFileTool.capability().riskLevel) >= .medium)
    }

    @Test func approvedWriteReturnsAPathThatBecomesACard() async throws {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        var asked: [AIActionPlan] = []
        let result = await AgentToolRegistry.runWriteOutputFile(
            name: "passport files", format: "csv", content: "name\nA\n", scope: nil,
            attended: true, folder: folder
        ) { plan, capability in
            asked.append(plan)
            #expect(capability.riskLevel.requiresApproval)
            return true
        }
        #expect(result.success)
        #expect(asked.count == 1)
        #expect(asked[0].capability == OutputFileTool.capabilityID)
        #expect(asked[0].input["folder"] == folder.path)
        let path = folder.appendingPathComponent("passport files.csv").path
        #expect(result.output.contains(path))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "name\nA\n")

        // A path with a space in the folder name still comes out as one card.
        let cards = TurnFileExtractor.files(answer: "", stepOutputs: [result.output])
        #expect(cards.map(\.path) == [path])
    }

    @Test func declinedWritesNothing() async {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        let result = await AgentToolRegistry.runWriteOutputFile(
            name: "a", format: "md", content: "x", scope: nil, attended: true, folder: folder
        ) { _, _ in false }
        #expect(!result.success)
        #expect(result.deniedByUser)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func unattendedMCPCallerIsRefusedWithoutAsking() async {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        var asked = false
        let result = await AgentToolRegistry.runWriteOutputFile(
            name: "a", format: "md", content: "x", scope: nil, attended: false, folder: folder
        ) { _, _ in asked = true; return true }
        #expect(!result.success)
        #expect(!asked)
        #expect(result.output.contains("unattended"))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func unattendedRunRefusesTheRealApprovalSheet() async throws {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        let (result, requested) = await AICapabilityApprovalCenter.withUnattendedRun {
            await AgentToolRegistry.runWriteOutputFile(
                name: "a", format: "md", content: "x", scope: nil, attended: true, folder: folder)
        }
        #expect(!result.success)
        #expect(requested == [OutputFileTool.capabilityID])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func badRequestsAreRefusedBeforeAnyApproval() async {
        let (folder, cleanup) = Self.makeFolder()
        defer { cleanup() }
        for (name, format) in [("../x", "md"), ("ok", "sh"), ("", "md")] {
            var asked = false
            let result = await AgentToolRegistry.runWriteOutputFile(
                name: name, format: format, content: "x", scope: nil, attended: true, folder: folder
            ) { _, _ in asked = true; return true }
            #expect(!result.success)
            #expect(!asked)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func mcpServerListsTheTool() {
        for attended in [true, false] {
            let names = DoraXMCPServer.toolDefinitions(attended: attended).compactMap { $0["name"] as? String }
            #expect(names.contains("dorax_write_output_file"))
        }
    }

    @Test func aFileSentenceIsOfferedTheTool() {
        let plan = FrontmostAppTaskPlan.make(
            query: "write a csv of my passport files", bundleId: "com.apple.finder", appName: "Finder")
        #expect(plan.allowedToolNames.contains("write_output_file"))
        let other = FrontmostAppTaskPlan.make(
            query: "what is on this page", bundleId: "com.apple.finder", appName: "Finder")
        #expect(!other.allowedToolNames.contains("write_output_file"))
    }
}
