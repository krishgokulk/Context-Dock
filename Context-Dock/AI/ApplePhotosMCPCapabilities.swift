import Foundation

// First-party Apple Photos capabilities registered in CapabilityRegistry.
// Wraps AppleAppsAPI (Photos framework) reads. Both are read-only → .low risk.
//   photos.recent → most recent photos
//   photos.search → search the library by keyword / people / places

@MainActor
enum ApplePhotosMCPCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registerRecent(registry)
        registerSearch(registry)
    }

    // MARK: - photos.recent

    private static func registerRecent(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "photos.recent",
                title: "Get Recent Photos",
                appBundleID: "com.apple.Photos",
                inputSchema: .init(fields: [
                    .init(name: "limit", description: "How many recent photos (default 10)", required: false)
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.photosMCPEnabled else {
                    throw AICapabilityError.blocked("Photos access is disabled in Settings.")
                }
                let limit = max(1, min(Int(request.input["limit"] ?? "10") ?? 10, 50))
                let photos = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: AppleAppsAPI.shared.getRecentPhotos(limit: limit))
                    }
                }
                return .init(success: true, output: Self.describe(photos, header: "Recent photos"))
            }
        )
    }

    // MARK: - photos.search

    private static func registerSearch(_ registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "photos.search",
                title: "Search Photos",
                appBundleID: "com.apple.Photos",
                inputSchema: .init(fields: [
                    .init(name: "query", description: "Keyword, person, place, or date to search", required: true),
                    .init(name: "limit", description: "Max results (default 20)", required: false),
                ]),
                riskLevel: .low
            ) { request in
                guard AppSettings.shared.photosMCPEnabled else {
                    throw AICapabilityError.blocked("Photos access is disabled in Settings.")
                }
                guard let query = request.input["query"], !query.isEmpty else {
                    throw AICapabilityError.missingInput("query")
                }
                let limit = max(1, min(Int(request.input["limit"] ?? "20") ?? 20, 50))
                let photos = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(
                            returning: AppleAppsAPI.shared.searchPhotos(query: query, limit: limit))
                    }
                }
                return .init(
                    success: true, output: Self.describe(photos, header: "Photos matching “\(query)”"))
            }
        )
    }

    // MARK: - Formatting

    private static func describe(_ photos: [[String: Any]], header: String) -> String {
        guard !photos.isEmpty else { return "No photos found." }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let lines = photos.prefix(30).map { p -> String in
            let name = p["filename"] as? String ?? (p["localIdentifier"] as? String ?? "Photo")
            let date = (p["creationDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let dateStr = date.map { " — \(df.string(from: $0))" } ?? ""
            let path = (p["path"] as? String).flatMap { $0.isEmpty ? nil : "\n  \($0)" } ?? ""
            return "• \(name)\(dateStr)\(path)"
        }
        return "\(header) (\(photos.count)):\n\(lines.joined(separator: "\n"))"
    }
}
