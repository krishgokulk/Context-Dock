// FinderCoworkerCapabilities.swift
// Context-Dock
//
// The default "coworker" tool for Finder-scoped chat: a robust, privacy-first
// file toolkit so the assistant can actually complete file requests instead of
// saying "I can't access your files." Everything runs LOCALLY through FileManager
// and the app's built-in MarkItDown converter — no shell-outs, no network, no
// third-party service. Reads are low-risk (run freely); anything that changes the
// disk (trash) is high-risk and follows the normal approval path.

import AppKit
import Foundation

@MainActor
enum FinderCoworkerCapabilities {
    static let finderBundleID = "com.apple.finder"

    static func register(in registry: CapabilityRegistry) {
        registerSearch(in: registry)
        registerList(in: registry)
        registerRead(in: registry)
        registerInfo(in: registry)
        registerReveal(in: registry)
        registerTrash(in: registry)
        registerDiskUsage(in: registry)
        registerDuplicates(in: registry)
        registerStaleFiles(in: registry)
        registerDiskSpace(in: registry)
        registerRecentByKind(in: registry)
        registerOrganize(in: registry)
    }

    // MARK: - Shared scope resolution

    /// What the user means by "here", in the order a Finder co-worker should assume it:
    /// what they selected, then the folder they are looking at, then their usual roots.
    ///
    /// Selection first is the whole point of a co-worker. "Are these duplicates?" with six
    /// files highlighted is a question about those six, and answering it about Downloads
    /// instead is a different answer to a question nobody asked.
    private static func scopeURLs(
        from request: AICapabilityExecutionRequest, explicitPath: String? = nil
    ) -> (roots: [URL], describedAs: String) {
        if let explicit = resolveRoot(explicitPath) {
            return ([explicit], explicit.path)
        }
        let selected = selectedURLs(from: request)
        if !selected.isEmpty {
            return (
                selected,
                selected.count == 1
                    ? selected[0].lastPathComponent
                    : "\(selected.count) selected item(s)")
        }
        if let current = ContextDetector.shared.getCurrentFinderDirectory(), !current.isEmpty {
            let url = URL(fileURLWithPath: current)
            return ([url], url.path)
        }
        return (defaultRoots, "your Desktop, Documents and Downloads")
    }

    /// Every file under the given roots, hidden files skipped. One walker for the whole
    /// co-worker so the rules about what it may touch live in a single place.
    private static func files(under roots: [URL], limit: Int = 20_000) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for root in roots {
            let isDir = (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else {
                out.append(root)
                continue
            }
            guard let walker = fm.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in walker {
                let dir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !dir { out.append(url) }
                if out.count >= limit { return out }
            }
        }
        return out
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private static var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

    // MARK: - Duplicates

    /// Same name and same byte count, in more than one place. Not a hash comparison: reading
    /// every candidate to prove identity costs minutes on a Downloads folder, and name+size
    /// is enough to show the user where to look. The answer says which test was used, so
    /// nobody deletes on a promise the check did not make.
    private static func registerDuplicates(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.duplicates",
                title: "Find likely duplicate files (same name and size) in a folder or the selection",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "Folder to check (defaults to the selection or current folder)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let scope = scopeURLs(from: request, explicitPath: request.input["path"])
                let all = files(under: scope.roots)
                var groups: [String: [URL]] = [:]
                for url in all {
                    let key = "\(url.lastPathComponent)|\(size(of: url))"
                    groups[key, default: []].append(url)
                }
                let duplicates = groups.values.filter { $0.count > 1 }
                    .sorted { size(of: $0[0]) * Int64($0.count) > size(of: $1[0]) * Int64($1.count) }
                guard !duplicates.isEmpty else {
                    return .init(success: true, output: "No duplicate names and sizes in \(scope.describedAs).")
                }
                let formatter = byteFormatter
                var reclaimable: Int64 = 0
                var lines: [String] = []
                for group in duplicates.prefix(15) {
                    let each = size(of: group[0])
                    reclaimable += each * Int64(group.count - 1)
                    lines.append(
                        "- \(group[0].lastPathComponent) — \(group.count) copies, "
                        + "\(formatter.string(fromByteCount: each)) each")
                    for url in group.prefix(4) {
                        lines.append("    \(url.deletingLastPathComponent().path)")
                    }
                }
                return .init(
                    success: true,
                    output:
                        "\(duplicates.count) set(s) of likely duplicates in \(scope.describedAs) — "
                        + "matched on name and size, not contents.\n"
                        + "Reclaimable if you keep one of each: \(formatter.string(fromByteCount: reclaimable))\n\n"
                        + lines.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Stale files

    private static func registerStaleFiles(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.staleFiles",
                title: "Find files untouched for months, with how much space they hold",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "months", description: "How many months untouched counts as stale (default 6)", required: false),
                    .init(name: "path", description: "Folder to check (defaults to the selection or current folder)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                let months = Int(request.input["months"] ?? "") ?? 6
                let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date())
                    ?? Date.distantPast
                let scope = scopeURLs(from: request, explicitPath: request.input["path"])
                let stale = files(under: scope.roots)
                    .filter { modified($0) < cutoff }
                    .sorted { size(of: $0) > size(of: $1) }
                guard !stale.isEmpty else {
                    return .init(
                        success: true,
                        output: "Nothing in \(scope.describedAs) has been untouched for \(months) months.")
                }
                let formatter = byteFormatter
                let total = stale.reduce(Int64(0)) { $0 + size(of: $1) }
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .medium
                let lines = stale.prefix(20).map { url in
                    "- \(url.lastPathComponent) — \(formatter.string(fromByteCount: size(of: url))), "
                        + "last touched \(dateFormatter.string(from: modified(url)))"
                }
                return .init(
                    success: true,
                    output:
                        "\(stale.count) file(s) in \(scope.describedAs) untouched for \(months)+ months, "
                        + "holding \(formatter.string(fromByteCount: total)).\n\n"
                        + lines.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Disk space

    private static func registerDiskSpace(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.diskSpace",
                title: "Report free and total space on the startup volume",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                let home = URL(fileURLWithPath: NSHomeDirectory())
                guard let values = try? home.resourceValues(forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey,
                    .volumeTotalCapacityKey,
                ]),
                    let available = values.volumeAvailableCapacityForImportantUsage,
                    let total = values.volumeTotalCapacity
                else {
                    return .init(success: false, output: "Couldn't read the volume's capacity.")
                }
                let formatter = byteFormatter
                let used = Int64(total) - available
                let percent = Int((Double(used) / Double(total)) * 100)
                return .init(
                    success: true,
                    output:
                        "\(formatter.string(fromByteCount: available)) free of "
                        + "\(formatter.string(fromByteCount: Int64(total))) — \(percent)% used.")
            }
        )
    }

    // MARK: - Recent by kind

    private static func registerRecentByKind(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.recentByKind",
                title: "List recent files of a kind — screenshots, PDFs, images, documents, archives",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "kind", description: "screenshot, pdf, image, document, archive, video, audio", required: true),
                    .init(name: "days", description: "How far back to look (default 7)", required: false),
                    .init(name: "path", description: "Folder to search (defaults to the selection or your usual folders)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                let kind = (request.input["kind"] ?? "").lowercased()
                let days = Int(request.input["days"] ?? "") ?? 7
                let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
                    ?? Date.distantPast
                let extensions: [String: [String]] = [
                    "pdf": ["pdf"],
                    "image": ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"],
                    "screenshot": ["png", "jpg", "jpeg"],
                    "document": ["doc", "docx", "pages", "txt", "md", "rtf", "key", "numbers", "xlsx"],
                    "archive": ["zip", "dmg", "pkg", "tar", "gz", "xip"],
                    "video": ["mp4", "mov", "m4v", "avi", "mkv"],
                    "audio": ["mp3", "m4a", "wav", "aiff", "flac"],
                ]
                let wanted = extensions[kind] ?? [kind]
                let scope = scopeURLs(from: request, explicitPath: request.input["path"])
                var matches = files(under: scope.roots).filter { url in
                    wanted.contains(url.pathExtension.lowercased()) && modified(url) >= cutoff
                }
                // "Screenshot" is a name convention, not a file type — every screenshot is a
                // PNG but almost no PNG is a screenshot.
                if kind == "screenshot" {
                    matches = matches.filter {
                        let name = $0.lastPathComponent.lowercased()
                        return name.contains("screenshot") || name.contains("screen shot")
                            || name.hasPrefix("scr-")
                    }
                }
                matches.sort { modified($0) > modified($1) }
                guard !matches.isEmpty else {
                    return .init(
                        success: true,
                        output: "No \(kind) files in \(scope.describedAs) from the last \(days) day(s).")
                }
                let formatter = byteFormatter
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .medium
                dateFormatter.timeStyle = .short
                let lines = matches.prefix(20).map { url in
                    "- \(url.lastPathComponent) — \(formatter.string(fromByteCount: size(of: url))), "
                        + "\(dateFormatter.string(from: modified(url)))\n    \(url.deletingLastPathComponent().path)"
                }
                return .init(
                    success: true,
                    output:
                        "\(matches.count) \(kind) file(s) in the last \(days) day(s):\n\n"
                        + lines.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Organise

    /// Moves files into folders by kind or by month. Medium risk, so it goes through the
    /// approval sheet: this rearranges someone's filing, and a wrong guess is tedious to
    /// undo even though nothing is destroyed.
    private static func registerOrganize(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.organize",
                title: "Move files into folders by kind or by month",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "by", description: "kind or month (default kind)", required: false),
                    .init(name: "path", description: "Folder to organise (defaults to the selection or current folder)", required: false),
                ]),
                riskLevel: .medium
            ) { request in
                let by = (request.input["by"] ?? "kind").lowercased()
                let scope = scopeURLs(from: request, explicitPath: request.input["path"])
                guard let destination = scope.roots.first(where: { $0.hasDirectoryPath })
                    ?? scope.roots.first?.deletingLastPathComponent()
                else { return .init(success: false, output: "No folder to organise.") }

                let fm = FileManager.default
                // Only the top level. Recursing would reorganise folders the user already
                // arranged, which is a bigger promise than the request makes.
                let items =
                    (try? fm.contentsOfDirectory(
                        at: destination, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles])) ?? []
                let files = items.filter {
                    !((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                }
                guard !files.isEmpty else {
                    return .init(success: true, output: "Nothing to organise in \(destination.path).")
                }

                let monthFormatter = DateFormatter()
                monthFormatter.dateFormat = "yyyy-MM"
                var moved = 0
                var perFolder: [String: Int] = [:]
                for file in files {
                    let folderName: String
                    if by == "month" {
                        folderName = monthFormatter.string(from: modified(file))
                    } else {
                        let ext = file.pathExtension.lowercased()
                        folderName = ext.isEmpty ? "Other" : ext.uppercased()
                    }
                    let folder = destination.appendingPathComponent(folderName, isDirectory: true)
                    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent(file.lastPathComponent)
                    // Never overwrite: a name collision keeps both, because losing a file to
                    // tidying would be the worst possible outcome of a tidy-up.
                    guard !fm.fileExists(atPath: target.path) else { continue }
                    do {
                        try fm.moveItem(at: file, to: target)
                        moved += 1
                        perFolder[folderName, default: 0] += 1
                    } catch { continue }
                }
                let summary = perFolder.sorted { $0.value > $1.value }
                    .map { "- \($0.key): \($0.value) file(s)" }
                return .init(
                    success: true,
                    output:
                        "Moved \(moved) of \(files.count) file(s) in \(destination.path) by \(by).\n"
                        + (summary.isEmpty ? "" : summary.joined(separator: "\n"))
                        + (moved < files.count
                            ? "\n\nSkipped \(files.count - moved) — a file of that name already existed in the target folder."
                            : ""))
            }
        )
    }

    // MARK: - Disk usage

    /// "How much space does Downloads take?" had no capability behind it, so the model
    /// answered that the size was unavailable and told the user to go look in Finder —
    /// while Finder itself was the scope of the conversation. A folder's size is a fact
    /// the machine can produce; it should never be a suggestion to check manually.
    private static func registerDiskUsage(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.folderSize",
                title: "Measure a folder's total size and its largest items",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(
                        name: "path",
                        description:
                            "Folder to measure, e.g. ~/Downloads (defaults to the selected "
                            + "folder or the current Finder folder)",
                        required: false)
                ]),
                riskLevel: .low
            ) { request in
                let scope = scopeURLs(from: request, explicitPath: request.input["path"])
                guard let root = scope.roots.first(where: { $0.hasDirectoryPath }) ?? scope.roots.first
                else { return .init(success: false, output: "No folder to measure.") }

                let fm = FileManager.default
                var total: Int64 = 0
                var fileCount = 0
                var folderCount = 0
                /// Size per immediate child, so the answer can say what is actually taking
                /// the space rather than only how much there is.
                var perChild: [(name: String, bytes: Int64)] = []

                let children =
                    (try? fm.contentsOfDirectory(
                        at: root, includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles])) ?? []

                for child in children {
                    var childTotal: Int64 = 0
                    let isDir =
                        (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDir {
                        folderCount += 1
                        // Enumerated rather than shelling out to du: no approval prompt, no
                        // shell, and it stops at the user's own folder either way.
                        if let walker = fm.enumerator(
                            at: child, includingPropertiesForKeys: [.fileSizeKey],
                            options: [.skipsHiddenFiles])
                        {
                            for case let url as URL in walker {
                                let size =
                                    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                                childTotal += Int64(size)
                            }
                        }
                    } else {
                        fileCount += 1
                        childTotal = Int64(
                            (try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    }
                    total += childTotal
                    perChild.append((child.lastPathComponent, childTotal))
                }

                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let largest = perChild.sorted { $0.bytes > $1.bytes }.prefix(8)
                    .map { "- \($0.name): \(formatter.string(fromByteCount: $0.bytes))" }

                var out = [
                    "\(root.path)",
                    "Total: \(formatter.string(fromByteCount: total))",
                    "\(fileCount) file(s), \(folderCount) folder(s) at the top level",
                ]
                if !largest.isEmpty {
                    out.append("")
                    out.append("Largest items:")
                    out += largest
                }
                return .init(success: true, output: out.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Roots the tool may touch

    /// Common user roots searched when no explicit path is given. Kept to the
    /// user's own directories — never the whole disk — as a privacy default.
    private static var defaultRoots: [URL] {
        let fm = FileManager.default
        return [
            .desktopDirectory, .documentDirectory, .downloadsDirectory,
        ].compactMap { try? fm.url(for: $0, in: .userDomainMask, appropriateFor: nil, create: false) }
    }

    /// Resolve a user-supplied path (tilde/relative allowed), constrained to the
    /// user's home tree so the tool never wanders outside it.
    private static func resolveRoot(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        guard url.path == home || url.path.hasPrefix(home + "/") else { return nil }
        return url
    }

    // MARK: - Search

    private static func registerSearch(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.searchFiles",
                title: "Search files by name under the user's folders (Desktop/Documents/Downloads or a given path)",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Substring or *.ext glob to match file names", required: true),
                    .init(name: "path", description: "Optional folder to search under (defaults to user roots)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                let query = (request.input["query"] ?? "").lowercased()
                guard !query.isEmpty else { throw AICapabilityError.missingInput("query") }
                let roots = resolveRoot(request.input["path"]).map { [$0] } ?? defaultRoots
                let ext = query.hasPrefix("*.") ? String(query.dropFirst(2)) : nil

                var hits: [URL] = []
                let fm = FileManager.default
                for root in roots {
                    guard
                        let e = fm.enumerator(
                            at: root,
                            includingPropertiesForKeys: [.isRegularFileKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    else { continue }
                    for case let url as URL in e {
                        let name = url.lastPathComponent.lowercased()
                        let match =
                            ext != nil ? name.hasSuffix("." + ext!) : name.contains(query)
                        if match { hits.append(url) }
                        if hits.count >= 60 { break }
                    }
                    if hits.count >= 60 { break }
                }
                guard !hits.isEmpty else {
                    return .init(success: true, output: "No files matched \"\(query)\".")
                }
                let list = hits.prefix(60).map { "- \($0.path)" }.joined(separator: "\n")
                return .init(success: true, output: "Found \(hits.count) file(s):\n\(list)")
            }
        )
    }

    // MARK: - List

    private static func registerList(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.listFolder",
                title: "List the contents of a folder",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "Folder to list (defaults to the selected folder or Desktop)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let root =
                    resolveRoot(request.input["path"])
                    ?? selectedURLs(from: request).first(where: { $0.hasDirectoryPath })
                    ?? defaultRoots.first
                guard let root else { return .init(success: false, output: "No folder to list.") }
                let fm = FileManager.default
                let items =
                    (try? fm.contentsOfDirectory(
                        at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                        options: [.skipsHiddenFiles])) ?? []
                guard !items.isEmpty else {
                    return .init(success: true, output: "\(root.path) is empty.")
                }
                let lines = items.prefix(100).map { url -> String in
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    return "\(isDir ? "📁" : "📄") \(url.lastPathComponent)"
                }
                return .init(
                    success: true,
                    output: "\(root.path) — \(items.count) item(s):\n" + lines.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Read (token-reduced via MarkItDown)

    private static func registerRead(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.readFile",
                title: "Read a file's contents (PDF/Office/text converted to Markdown to save tokens)",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "File to read (defaults to the selected file)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let url =
                    resolveRoot(request.input["path"])
                    ?? selectedURLs(from: request).first
                guard let url, FileManager.default.fileExists(atPath: url.path) else {
                    return .init(success: false, output: "File not found.")
                }
                if MarkItDownService.supports(url),
                    let converted = MarkItDownService.convert(url, characterBudget: 8_000),
                    !converted.markdown.isEmpty
                {
                    return .init(
                        success: true,
                        output: converted.markdown
                            + (converted.wasTruncated ? "\n\n…(truncated)" : ""))
                }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    return .init(success: true, output: String(text.prefix(8_000)))
                }
                return .init(success: false, output: "Couldn't read \(url.lastPathComponent) as text.")
            }
        )
    }

    // MARK: - Info

    private static func registerInfo(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.fileInfo",
                title: "Get size, kind and dates for a file or folder",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "File/folder (defaults to the selected item)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let url = resolveRoot(request.input["path"]) ?? selectedURLs(from: request).first
                guard let url else { return .init(success: false, output: "No item to inspect.") }
                let keys: [URLResourceKey] = [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                    .creationDateKey, .localizedTypeDescriptionKey,
                ]
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else {
                    return .init(success: false, output: "Couldn't read \(url.lastPathComponent).")
                }
                var lines = ["Name: \(url.lastPathComponent)", "Path: \(url.path)"]
                if let kind = v.localizedTypeDescription { lines.append("Kind: \(kind)") }
                if let size = v.fileSize {
                    lines.append(
                        "Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                }
                if let modified = v.contentModificationDate {
                    lines.append("Modified: \(modified.formatted())")
                }
                if let created = v.creationDate { lines.append("Created: \(created.formatted())") }
                return .init(success: true, output: lines.joined(separator: "\n"))
            }
        )
    }

    // MARK: - Reveal

    private static func registerReveal(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.reveal",
                title: "Reveal a file or folder in Finder",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "Item to reveal (defaults to the selected item)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                let url = resolveRoot(request.input["path"]) ?? selectedURLs(from: request).first
                guard let url else { return .init(success: false, output: "Nothing to reveal.") }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return .init(success: true, output: "Revealed \(url.lastPathComponent) in Finder.")
            }
        )
    }

    // MARK: - Trash (destructive → approval)

    private static func registerTrash(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.trash",
                title: "Move files to the Trash (recoverable)",
                appBundleID: finderBundleID,
                inputSchema: .init(fields: [
                    .init(name: "path", description: "File/folder to trash; defaults to the selection", required: false)
                ]),
                riskLevel: .high
            ) { request in
                let urls =
                    resolveRoot(request.input["path"]).map { [$0] } ?? selectedURLs(from: request)
                guard !urls.isEmpty else { return .init(success: false, output: "Nothing to trash.") }
                var trashed: [String] = []
                for url in urls {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    trashed.append(url.lastPathComponent)
                }
                return .init(
                    success: true,
                    output: "Moved to Trash: \(trashed.joined(separator: ", "))")
            }
        )
    }

    // MARK: - Shared

    static func selectedURLs(from request: AICapabilityExecutionRequest) -> [URL] {
        if case .filesSelected(let urls) = request.context { return urls }
        return AXContextReader.shared.current.selectedFilePaths.map(URL.init(fileURLWithPath:))
    }
}
