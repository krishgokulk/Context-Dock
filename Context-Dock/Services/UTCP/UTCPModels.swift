//  UTCPModels.swift
//  Context-Dock
//
//  Universal Tool Calling Protocol (UTCP) specifications and data models.
//  Represents declarative manuals and tool definitions for direct, proxy-free
//  execution via native protocols (HTTP URLSession and CLI Process).

import Foundation

/// Type-safe JSON value representation for Codable schemas and parameters.
enum UTCPJSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case object([String: UTCPJSONValue])
    case array([UTCPJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .boolean(b)
        } else if let i = try? container.decode(Int.self) {
            self = .integer(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([UTCPJSONValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: UTCPJSONValue].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .integer(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .boolean(let b): try container.encode(b)
        case .object(let dict): try container.encode(dict)
        case .array(let arr): try container.encode(arr)
        case .null: try container.encodeNil()
        }
    }

    /// Converts into a standard Foundation property list object (`[String: Any]`, `[Any]`, etc.)
    var rawAny: Any {
        switch self {
        case .string(let s): return s
        case .integer(let i): return i
        case .double(let d): return d
        case .boolean(let b): return b
        case .object(let dict): return dict.mapValues { $0.rawAny }
        case .array(let arr): return arr.map { $0.rawAny }
        case .null: return NSNull()
        }
    }

    /// Creates a `UTCPJSONValue` from an untyped Foundation object.
    static func from(any: Any) -> UTCPJSONValue {
        switch any {
        case let s as String: return .string(s)
        case let b as Bool: return .boolean(b)
        case let i as Int: return .integer(i)
        case let d as Double: return .double(d)
        case let dict as [String: Any]: return .object(dict.mapValues { from(any: $0) })
        case let arr as [Any]: return .array(arr.map { from(any: $0) })
        default: return .null
        }
    }
}

/// Safety governance for UTCP tools matching DoraX's approval model.
enum UTCPToolSafety: String, Codable, Sendable, Equatable, Hashable {
    case read
    case write
    case unknown

    var requiresApproval: Bool { self != .read }

    static func infer(method: String, name: String) -> UTCPToolSafety {
        let m = method.uppercased()
        if m == "GET" || m == "HEAD" {
            return .read
        }
        if ["POST", "PUT", "PATCH", "DELETE"].contains(m) {
            return .write
        }
        // Fall back to name-based classification
        let lower = name.lowercased()
        let writePrefixes = ["create", "add", "delete", "remove", "update", "post", "send", "archive"]
        if writePrefixes.contains(where: { lower.contains($0) }) {
            return .write
        }
        let readPrefixes = ["get", "list", "search", "find", "fetch", "show", "read", "status"]
        if readPrefixes.contains(where: { lower.contains($0) }) {
            return .read
        }
        return .unknown
    }
}

/// Execution instructions for a single UTCP tool.
enum UTCPExecution: Codable, Sendable, Equatable, Hashable {
    case http(HTTPExecution)
    case cli(CLIExecution)

    enum CodingKeys: String, CodingKey {
        case http
        case cli
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.http) {
            let httpExec = try container.decode(HTTPExecution.self, forKey: .http)
            self = .http(httpExec)
        } else if container.contains(.cli) {
            let cliExec = try container.decode(CLIExecution.self, forKey: .cli)
            self = .cli(cliExec)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Expected either 'http' or 'cli' key in execution object"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .http(let httpExec):
            try container.encode(httpExec, forKey: .http)
        case .cli(let cliExec):
            try container.encode(cliExec, forKey: .cli)
        }
    }

    struct HTTPExecution: Codable, Sendable, Equatable, Hashable {
        var method: String
        var path: String
        var queryParams: [String]
        var headerParams: [String]
        var bodyParamNames: [String]

        enum CodingKeys: String, CodingKey {
            case method, path, queryParams, headerParams, bodyParamNames
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            method = try container.decode(String.self, forKey: .method).uppercased()
            path = try container.decode(String.self, forKey: .path)
            queryParams = try container.decodeIfPresent([String].self, forKey: .queryParams) ?? []
            headerParams = try container.decodeIfPresent([String].self, forKey: .headerParams) ?? []
            bodyParamNames = try container.decodeIfPresent([String].self, forKey: .bodyParamNames) ?? []
        }

        init(
            method: String,
            path: String,
            queryParams: [String] = [],
            headerParams: [String] = [],
            bodyParamNames: [String] = []
        ) {
            self.method = method.uppercased()
            self.path = path
            self.queryParams = queryParams
            self.headerParams = headerParams
            self.bodyParamNames = bodyParamNames
        }
    }

    struct CLIExecution: Codable, Sendable, Equatable, Hashable {
        var command: String
        var args: [String]

        enum CodingKeys: String, CodingKey {
            case command, args
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decode(String.self, forKey: .command)
            args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        }

        init(command: String, args: [String] = []) {
            self.command = command
            self.args = args
        }
    }
}

/// A single callable tool definition declared in a UTCP manual or generated from OpenAPI.
struct UTCPToolDefinition: Codable, Sendable, Identifiable, Equatable, Hashable {
    var id: String { name }
    var name: String
    var description: String
    var parametersSchema: [String: UTCPJSONValue]
    var requiredParameters: [String]
    var execution: UTCPExecution
    var safety: UTCPToolSafety
    var tags: [String]

    enum CodingKeys: String, CodingKey {
        case name, description, parametersSchema, requiredParameters, execution, safety, tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        parametersSchema = try container.decodeIfPresent([String: UTCPJSONValue].self, forKey: .parametersSchema) ?? [:]
        requiredParameters = try container.decodeIfPresent([String].self, forKey: .requiredParameters) ?? []
        execution = try container.decode(UTCPExecution.self, forKey: .execution)
        safety = try container.decodeIfPresent(UTCPToolSafety.self, forKey: .safety) ?? .unknown
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    init(
        name: String,
        description: String,
        parametersSchema: [String: UTCPJSONValue] = [:],
        requiredParameters: [String] = [],
        execution: UTCPExecution,
        safety: UTCPToolSafety = .unknown,
        tags: [String] = []
    ) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
        self.requiredParameters = requiredParameters
        self.execution = execution
        self.safety = safety
        self.tags = tags
    }

    /// Parameter schema formatted for provider tool loops (`[String: Any]`).
    var schemaPropertiesForProvider: [String: Any] {
        parametersSchema.mapValues { $0.rawAny }
    }
}

/// Protocol definitions in a UTCP manual.
struct UTCPProtocolsConfig: Codable, Sendable, Equatable, Hashable {
    struct HTTPConfig: Codable, Sendable, Equatable, Hashable {
        var baseURL: String
        var defaultHeaders: [String: String]?
    }

    struct CLIConfig: Codable, Sendable, Equatable, Hashable {
        var executable: String?
        var defaultArgs: [String]?
    }

    var http: HTTPConfig?
    var cli: CLIConfig?
}

/// A complete UTCP Manual specifying tools, metadata, and protocols.
struct UTCPManual: Codable, Sendable, Identifiable, Equatable, Hashable {
    var id: String { name }
    var utcpVersion: String
    var name: String
    var description: String
    var protocols: UTCPProtocolsConfig
    var tools: [UTCPToolDefinition]

    enum CodingKeys: String, CodingKey {
        case utcpVersion = "utcp_version"
        case name
        case description
        case protocols
        case tools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utcpVersion = try container.decodeIfPresent(String.self, forKey: .utcpVersion) ?? "1.0"
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        protocols = try container.decodeIfPresent(UTCPProtocolsConfig.self, forKey: .protocols) ?? UTCPProtocolsConfig()
        tools = try container.decodeIfPresent([UTCPToolDefinition].self, forKey: .tools) ?? []
    }

    init(
        utcpVersion: String = "1.0",
        name: String,
        description: String,
        protocols: UTCPProtocolsConfig,
        tools: [UTCPToolDefinition]
    ) {
        self.utcpVersion = utcpVersion
        self.name = name
        self.description = description
        self.protocols = protocols
        self.tools = tools
    }
}
