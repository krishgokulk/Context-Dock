import Foundation

@MainActor
enum FinderFileChangeCapabilities {
    static func register(in registry: CapabilityRegistry) {
        registerRename(in: registry)
        registerTransfer(id: "finder.moveFiles", title: "Move Finder Files", copy: false, registry: registry)
        registerTransfer(id: "finder.copyFiles", title: "Copy Finder Files", copy: true, registry: registry)
        registerNewFolder(in: registry)
    }

    static func selectedURLs(from request: AICapabilityExecutionRequest) -> [URL] {
        if case .filesSelected(let urls) = request.context { return urls }
        return AXContextReader.shared.current.selectedFilePaths.map(URL.init(fileURLWithPath:))
    }

    private static func registerRename(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.renameFiles",
                title: "Rename Finder Files",
                appBundleID: "com.apple.finder",
                inputSchema: .init(fields: [
                    .init(name: "pattern", description: "Pattern using {name}, {ext}, and {n}", required: true)
                ]),
                riskLevel: .high
            ) { request in
                guard let pattern = request.input["pattern"], !pattern.isEmpty else {
                    throw AICapabilityError.missingInput("pattern")
                }
                let urls = selectedURLs(from: request)
                guard !urls.isEmpty else { return .init(success: false, output: "No Finder files selected") }
                let moves = urls.enumerated().map { index, source in
                    (source, source.deletingLastPathComponent().appendingPathComponent(
                        renamedName(source: source, pattern: pattern, index: index + 1)
                    ))
                }
                let unchanged = Set(
                    moves.filter { $0.0.standardizedFileURL == $0.1.standardizedFileURL }
                        .map { $0.1.standardizedFileURL }
                )
                try validateDestinations(moves.map(\.1), excluding: unchanged)
                for (source, destination) in moves where source.standardizedFileURL != destination.standardizedFileURL {
                    try FileManager.default.moveItem(at: source, to: destination)
                }
                return .init(success: true, output: preview(moves, verb: "Renamed"))
            }
        )
    }

    private static func registerTransfer(
        id: String,
        title: String,
        copy: Bool,
        registry: CapabilityRegistry
    ) {
        registry.register(
            AICapability(
                id: id,
                title: title,
                appBundleID: "com.apple.finder",
                inputSchema: .init(fields: [
                    .init(name: "destination", description: "Absolute destination folder", required: true)
                ]),
                // Move claims mv only when a whole folder is not being reorganised;
                // finder.organize claims it for that, and whichever the registry finds
                // first is the one the gate names.
                riskLevel: .high,
                supersedesShellVerbs: copy ? ["cp", "ditto"] : []
            ) { request in
                guard let path = request.input["destination"], !path.isEmpty else {
                    throw AICapabilityError.missingInput("destination")
                }
                let destinationFolder = URL(fileURLWithPath: path, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else { return .init(success: false, output: "Destination folder does not exist: \(path)") }
                let urls = selectedURLs(from: request)
                guard !urls.isEmpty else { return .init(success: false, output: "No Finder files selected") }
                let transfers = urls.map { ($0, destinationFolder.appendingPathComponent($0.lastPathComponent)) }
                try validateDestinations(transfers.map(\.1), excluding: [])
                for (source, destination) in transfers {
                    if copy {
                        try FileManager.default.copyItem(at: source, to: destination)
                    } else {
                        try FileManager.default.moveItem(at: source, to: destination)
                    }
                }
                return .init(success: true, output: preview(transfers, verb: copy ? "Copied" : "Moved"))
            }
        )
    }

    private static func registerNewFolder(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "finder.newFolder",
                title: "Create Finder Folder",
                appBundleID: "com.apple.finder",
                inputSchema: .init(fields: [
                    .init(name: "destination", description: "Absolute parent directory", required: true),
                    .init(name: "name", description: "New folder name", required: true),
                ]),
                riskLevel: .medium,
                supersedesShellVerbs: ["mkdir"]
            ) { request in
                guard let destination = request.input["destination"], !destination.isEmpty else {
                    throw AICapabilityError.missingInput("destination")
                }
                guard let name = request.input["name"], !name.isEmpty, !name.contains("/") else {
                    throw AICapabilityError.missingInput("name")
                }
                let url = URL(fileURLWithPath: destination, isDirectory: true).appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    return .init(success: false, output: "Folder already exists: \(url.path)")
                }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return .init(success: true, output: "Created \(url.path)")
            }
        )
    }

    private static func renamedName(source: URL, pattern: String, index: Int) -> String {
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        var value = pattern
            .replacingOccurrences(of: "{name}", with: base)
            .replacingOccurrences(of: "{ext}", with: ext)
            .replacingOccurrences(of: "{n}", with: String(index))
        if !ext.isEmpty && !value.hasSuffix(".\(ext)") { value += ".\(ext)" }
        return value
    }

    private static func validateDestinations(_ urls: [URL], excluding: Set<URL>) throws {
        guard Set(urls.map(\.standardizedFileURL)).count == urls.count else {
            throw AICapabilityError.blocked("Multiple files would receive same destination name")
        }
        for url in urls where !excluding.contains(url.standardizedFileURL) {
            if FileManager.default.fileExists(atPath: url.path) {
                throw AICapabilityError.blocked("Destination already exists: \(url.path)")
            }
        }
    }

    private static func preview(_ pairs: [(URL, URL)], verb: String) -> String {
        "\(verb) \(pairs.count) item(s):\n" + pairs.prefix(50)
            .map { "\($0.0.path) -> \($0.1.path)" }
            .joined(separator: "\n")
    }
}
