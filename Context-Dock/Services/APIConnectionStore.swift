//  APIConnectionStore.swift
//  Context-Dock
//
//  First-class API integrations for App Adapters. Connection METADATA persists to
//  disk; the SECRET (API key / token) lives only in the macOS Keychain, never on
//  disk and never in the adapter manifest. A connection is disabled until the
//  user explicitly connects.

import Combine
import Foundation

struct APIConnection: Identifiable, Codable, Equatable {
    let id: String
    var adapterBundleId: String
    var name: String
    var baseURL: String
    var permissions: String      // freeform scope notes shown to the user
    var createdAt: Date
    var lastSync: Date?

    enum Status: String, Codable { case connected, disconnected }
    var status: Status

    var specText: String? = nil
    var toolCount: Int = 0

    var keychainAccount: String { "apiconn:\(id)" }
}

@MainActor
final class APIConnectionStore: ObservableObject {
    static let shared = APIConnectionStore()

    @Published private(set) var connections: [APIConnection] = []

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("DoraX/APIConnections.json", isDirectory: false)
    }()

    private init() { load() }

    func connections(for bundleId: String) -> [APIConnection] {
        connections.filter { $0.adapterBundleId == bundleId }
    }

    /// Create a connection and store its secret in the Keychain. The secret is
    /// never persisted to disk. Optionally attaches a UTCP manual or OpenAPI specification.
    @discardableResult
    func connect(
        name: String,
        baseURL: String,
        apiKey: String,
        bundleId: String,
        specText: String? = nil
    ) -> APIConnection {
        let trimmedSpec = specText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let manual: UTCPManual? = {
            guard let text = trimmedSpec, !text.isEmpty else { return nil }
            return try? UTCPManualParser.parse(text: text)
        }()

        var conn = APIConnection(
            id: UUID().uuidString,
            adapterBundleId: bundleId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            permissions: "",
            createdAt: Date(),
            lastSync: nil,
            status: .connected,
            specText: trimmedSpec?.isEmpty == false ? trimmedSpec : nil,
            toolCount: manual?.tools.count ?? 0)

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { KeychainStore.shared.set(key, for: conn.keychainAccount) }

        if let manual {
            UTCPToolBridge.shared.register(
                manual: manual,
                groupKey: conn.id,
                prefix: conn.name,
                apiKey: key.isEmpty ? nil : key
            )
        }

        connections.append(conn)
        save()
        return conn
    }

    func disconnect(id: String) {
        guard let conn = connections.first(where: { $0.id == id }) else { return }
        UTCPToolBridge.shared.unregisterGroup(id)
        KeychainStore.shared.delete(account: conn.keychainAccount)
        connections.removeAll { $0.id == id }
        save()
    }

    /// The stored secret for a connection (Keychain only). Empty if none.
    func token(for id: String) -> String {
        guard let conn = connections.first(where: { $0.id == id }) else { return "" }
        return KeychainStore.shared.string(for: conn.keychainAccount)
    }

    func markSynced(id: String) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[idx].lastSync = Date()
        save()
    }

    // MARK: - Persistence (metadata only)

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? decoder.decode([APIConnection].self, from: data)
        else { return }
        connections = decoded

        // Restore UTCP tool registrations for active connections
        for conn in connections where conn.status == .connected {
            guard let specText = conn.specText, !specText.isEmpty,
                  let manual = try? UTCPManualParser.parse(text: specText)
            else { continue }
            let secret = KeychainStore.shared.string(for: conn.keychainAccount)
            UTCPToolBridge.shared.register(
                manual: manual,
                groupKey: conn.id,
                prefix: conn.name,
                apiKey: secret.isEmpty ? nil : secret
            )
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(connections) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
