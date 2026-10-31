//  UTCPManualParser.swift
//  Context-Dock
//
//  Unified ingestion gateway for UTCP manuals and OpenAPI 3.x specifications.
//  Auto-detects format and returns a normalized UTCPManual.

import Foundation

enum UTCPManualParserError: LocalizedError {
    case unreadableData
    case unrecognizedFormat

    var errorDescription: String? {
        switch self {
        case .unreadableData:
            return "Unable to parse JSON data."
        case .unrecognizedFormat:
            return "Unrecognized tool specification. Expected a UTCP manual or OpenAPI 3.x specification."
        }
    }
}

enum UTCPManualParser {
    /// Ingests either a native UTCP manual or an OpenAPI 3.x document and produces a normalized UTCPManual.
    static func parse(data: Data) throws -> UTCPManual {
        // Attempt native UTCP decode first
        let decoder = JSONDecoder()
        if let manual = try? decoder.decode(UTCPManual.self, from: data) {
            return manual
        }

        // Check if it's an OpenAPI or Swagger document
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UTCPManualParserError.unreadableData
        }

        if json["openapi"] != nil || json["swagger"] != nil || json["paths"] != nil {
            return try OpenAPISpecParser.parse(data: data)
        }

        throw UTCPManualParserError.unrecognizedFormat
    }

    /// Convenience overload for parsing UTF-8 strings.
    static func parse(text: String) throws -> UTCPManual {
        guard let data = text.data(using: .utf8) else {
            throw UTCPManualParserError.unreadableData
        }
        return try parse(data: data)
    }
}
