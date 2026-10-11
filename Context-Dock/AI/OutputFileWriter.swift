// OutputFileWriter.swift
// Context-Dock
//
// The pure core of `write_output_file`: turn a name, a format and some text into one new file in
// the DoraX outputs folder, and say where it went.
//
// The model chooses a name and a format; it never chooses a folder. The name is a stem only —
// anything with a path separator is refused rather than tidied, so a model that asks for "../x"
// learns it asked for something it may not have. A file is never overwritten: the first free name
// of "stem", "stem 2", "stem 3"… is claimed with an exclusive create, so two writes at once cannot
// land on the same file. Extensions come from a short allow-list.
//
// Nothing here touches the model or the network; the folder is a parameter so tests use a temp
// directory.

import Foundation

nonisolated enum OutputFileWriter {

    enum Format: String, CaseIterable, Sendable {
        case md, txt, csv, docx

        init?(model raw: String) {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            self.init(rawValue: cleaned)
        }

        static var allowedList: String { allCases.map { ".\($0.rawValue)" }.joined(separator: ", ") }
    }

    enum Refusal: Error, Equatable, LocalizedError, Sendable {
        case emptyName
        case notAName
        case unsupportedFormat(String)
        case tooLarge
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "write_output_file needs a 'name' for the file."
            case .notAName:
                return "'name' must be a plain file name, not a path. The folder is fixed "
                    + "(DoraX Outputs); do not include folders or '..'."
            case .unsupportedFormat(let raw):
                return "Format '\(raw)' is not supported. Use one of: \(Format.allowedList)."
            case .tooLarge:
                return "The content is larger than \(OutputFileWriter.maxContentBytes / 1_000_000) MB."
            case .cannotWrite(let why):
                return "The file could not be written: \(why)"
            }
        }
    }

    static let folderName = "DoraX Outputs"
    static let maxStemLength = 80
    static let maxContentBytes = 5_000_000
    private static let maxNumbering = 999

    /// `~/Documents/DoraX Outputs`. Not created here; `write` creates it on first use.
    static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: - Names

    /// The file name stem for `raw`, or a refusal. A trailing extension that matches `format`
    /// is dropped ("report.csv" for csv is "report"), so the model may say either.
    static func sanitisedStem(_ raw: String, format: Format) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Refusal.emptyName }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else {
            throw Refusal.notAName
        }

        var name = trimmed
        let suffix = "." + format.rawValue
        if name.lowercased().hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }

        var cleaned = ""
        for scalar in name.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            if scalar == ":" { cleaned.append("-"); continue }
            cleaned.unicodeScalars.append(scalar)
        }
        // Leading dots would hide the file (and ".." is nothing); trailing dots and spaces
        // are trouble on other systems.
        cleaned = String(cleaned.drop(while: { $0 == "." || $0 == " " }))
        if cleaned.count > maxStemLength { cleaned = String(cleaned.prefix(maxStemLength)) }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !cleaned.isEmpty else { throw Refusal.emptyName }
        return cleaned
    }

    // MARK: - Writing

    /// Writes `content` as a new file in `folder` and returns its URL.
    static func write(
        name: String, format rawFormat: String, content: String,
        folder: URL = defaultFolder(), fileManager: FileManager = .default
    ) throws -> URL {
        guard let format = Format(model: rawFormat) else {
            throw Refusal.unsupportedFormat(rawFormat)
        }
        let stem = try sanitisedStem(name, format: format)
        let data = encoded(content, format: format)
        guard data.count <= maxContentBytes else { throw Refusal.tooLarge }

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Refusal.cannotWrite(error.localizedDescription)
        }

        let root = folder.standardizedFileURL.path
        for number in 1...(maxNumbering + 1) {
            let candidate = number == 1 ? stem : "\(stem) \(number)"
            let url = folder.appendingPathComponent("\(candidate).\(format.rawValue)")
            // The stem is already a plain name; the write is the last place a mistake can
            // still be caught.
            guard url.deletingLastPathComponent().standardizedFileURL.path == root else {
                throw Refusal.notAName
            }
            do {
                // Exclusive create: fails, never replaces, when the name is taken.
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError
            {
                continue
            } catch {
                throw Refusal.cannotWrite(error.localizedDescription)
            }
        }
        throw Refusal.cannotWrite("too many files with that name")
    }

    static func encoded(_ content: String, format: Format) -> Data {
        switch format {
        case .md, .txt, .csv: return Data(content.utf8)
        case .docx: return DocxWriter.document(text: content)
        }
    }
}

// MARK: - .docx

/// A minimal, valid Word document: three OOXML parts in a stored (uncompressed) zip. Each line
/// of text is a paragraph; nothing else is interpreted (Markdown syntax is written as typed).
nonisolated enum DocxWriter {

    static func document(text: String) -> Data {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", rootRels)
        zip.add("word/document.xml", documentXML(text))
        return zip.finish()
    }

    static func documentXML(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let paragraphs = lines.map { line -> String in
            let escaped = escape(line)
            return escaped.isEmpty
                ? "<w:p/>"
                : "<w:p><w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            + "<w:body>\(paragraphs)"
            + "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/>"
            + "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" "
            + "w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
            + "</w:body></w:document>"
    }

    /// XML-escapes and drops characters XML 1.0 cannot carry (most control characters).
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                switch scalar {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                default: out.unicodeScalars.append(scalar)
                }
            default: continue
            }
        }
        return out
    }

    private static let contentTypes =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        + "<Override PartName=\"/word/document.xml\" "
        + "ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        + "</Types>"

    private static let rootRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" "
        + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" "
        + "Target=\"word/document.xml\"/></Relationships>"
}

/// A zip writer for a handful of small entries: method 0 (stored), no zip64, fixed timestamp.
nonisolated struct ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }
    private var body = Data()
    private var entries: [Entry] = []

    // 2026-01-01 00:00:00 in DOS time/date.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = UInt16(((2026 - 1980) << 9) | (1 << 5) | 1)

    mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    mutating func add(_ name: String, _ data: Data) {
        let nameBytes = Array(name.utf8)
        let crc = Self.crc32(data)
        let offset = UInt32(body.count)
        body.append(le32: 0x0403_4B50)
        body.append(le16: 20)  // version needed
        body.append(le16: 0x0800)  // UTF-8 names
        body.append(le16: 0)  // stored
        body.append(le16: Self.dosTime)
        body.append(le16: Self.dosDate)
        body.append(le32: crc)
        body.append(le32: UInt32(data.count))
        body.append(le32: UInt32(data.count))
        body.append(le16: UInt16(nameBytes.count))
        body.append(le16: 0)
        body.append(contentsOf: nameBytes)
        body.append(data)
        entries.append(Entry(name: nameBytes, crc: crc, size: UInt32(data.count), offset: offset))
    }

    func finish() -> Data {
        var out = body
        let directoryStart = UInt32(out.count)
        for entry in entries {
            out.append(le32: 0x0201_4B50)
            out.append(le16: 20)  // made by
            out.append(le16: 20)  // needed
            out.append(le16: 0x0800)
            out.append(le16: 0)
            out.append(le16: Self.dosTime)
            out.append(le16: Self.dosDate)
            out.append(le32: entry.crc)
            out.append(le32: entry.size)
            out.append(le32: entry.size)
            out.append(le16: UInt16(entry.name.count))
            out.append(le16: 0)  // extra
            out.append(le16: 0)  // comment
            out.append(le16: 0)  // disk
            out.append(le16: 0)  // internal attrs
            out.append(le32: 0)  // external attrs
            out.append(le32: entry.offset)
            out.append(contentsOf: entry.name)
        }
        let directorySize = UInt32(out.count) - directoryStart
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: UInt16(entries.count))
        out.append(le16: UInt16(entries.count))
        out.append(le32: directorySize)
        out.append(le32: directoryStart)
        out.append(le16: 0)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
}

nonisolated private extension Data {
    mutating func append(le16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(le32 value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}
