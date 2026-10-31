//  OpenAPISpecParser.swift
//  Context-Dock
//
//  Parses OpenAPI 3.0 / 3.1 specifications and converts them into
//  declarative UTCPManual and UTCPToolDefinition structures for
//  zero-proxy direct HTTP calling.

import Foundation

enum OpenAPISpecParserError: LocalizedError {
    case invalidJSON
    case missingPaths
    case unsupportedVersion(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The provided document is not valid JSON."
        case .missingPaths:
            return "OpenAPI specification does not contain a valid 'paths' object."
        case .unsupportedVersion(let v):
            return "Unsupported OpenAPI / Swagger version: \(v)"
        }
    }
}

enum OpenAPISpecParser {
    /// Sanitizes an operation ID or path into an alphanumeric + underscore tool name.
    static func sanitizeToolName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let cleaned = raw.replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .unicodeScalars.filter { allowed.contains($0) }
        let result = String(cleaned)
            .split(separator: "_")
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return result.isEmpty ? "api_tool" : result
    }

    /// Parses OpenAPI 3.x JSON data into a UTCPManual.
    static func parse(data: Data) throws -> UTCPManual {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAPISpecParserError.invalidJSON
        }

        // Check version
        let openapiVersion = (json["openapi"] as? String) ?? (json["swagger"] as? String) ?? "3.0.0"
        let info = json["info"] as? [String: Any] ?? [:]
        let title = (info["title"] as? String) ?? "OpenAPI Service"
        let description = (info["description"] as? String) ?? "Auto-generated tools from OpenAPI spec"

        // Base URL from servers
        var baseURL = ""
        if let servers = json["servers"] as? [[String: Any]],
           let firstServer = servers.first,
           let urlString = firstServer["url"] as? String {
            baseURL = urlString
        }

        guard let paths = json["paths"] as? [String: [String: Any]] else {
            throw OpenAPISpecParserError.missingPaths
        }

        var tools: [UTCPToolDefinition] = []
        let supportedMethods = ["get", "post", "put", "delete", "patch"]

        for (path, pathItem) in paths {
            for method in supportedMethods {
                guard let operation = pathItem[method] as? [String: Any] else { continue }

                let summary = (operation["summary"] as? String) ?? ""
                let desc = (operation["description"] as? String) ?? summary
                let opDescription = desc.isEmpty ? "\(method.uppercased()) \(path)" : desc

                // Tool name resolution
                let rawName: String = {
                    if let opId = operation["operationId"] as? String, !opId.trimmingCharacters(in: .whitespaces).isEmpty {
                        return opId
                    }
                    return "\(method)_\(path)"
                }()
                let toolName = sanitizeToolName(rawName)

                var propertiesSchema: [String: UTCPJSONValue] = [:]
                var requiredParams: [String] = []
                var queryParams: [String] = []
                var headerParams: [String] = []
                var bodyParamNames: [String] = []

                // Parse parameters
                if let parameters = operation["parameters"] as? [[String: Any]] {
                    for param in parameters {
                        guard let pName = param["name"] as? String else { continue }
                        let pIn = (param["in"] as? String) ?? "query"
                        let pRequired = (param["required"] as? Bool) ?? false
                        let pDesc = (param["description"] as? String) ?? ""

                        var schemaDict: [String: Any] = ["description": pDesc]
                        if let subSchema = param["schema"] as? [String: Any] {
                            for (k, v) in subSchema { schemaDict[k] = v }
                        } else {
                            schemaDict["type"] = "string"
                        }

                        propertiesSchema[pName] = UTCPJSONValue.from(any: schemaDict)

                        if pRequired {
                            requiredParams.append(pName)
                        }

                        if pIn == "query" {
                            queryParams.append(pName)
                        } else if pIn == "header" {
                            headerParams.append(pName)
                        }
                    }
                }

                // Parse requestBody (application/json)
                if let requestBody = operation["requestBody"] as? [String: Any],
                   let content = requestBody["content"] as? [String: Any],
                   let jsonContent = content["application/json"] as? [String: Any],
                   let bodySchema = jsonContent["schema"] as? [String: Any] {
                    
                    if let bodyProps = bodySchema["properties"] as? [String: Any] {
                        let bodyRequired = (bodySchema["required"] as? [String]) ?? []
                        for (propName, propValue) in bodyProps {
                            propertiesSchema[propName] = UTCPJSONValue.from(any: propValue)
                            bodyParamNames.append(propName)
                            if bodyRequired.contains(propName) && !requiredParams.contains(propName) {
                                requiredParams.append(propName)
                            }
                        }
                    }
                }

                let safety = UTCPToolSafety.infer(method: method, name: toolName)
                let tags = (operation["tags"] as? [String]) ?? []

                let httpExec = UTCPExecution.HTTPExecution(
                    method: method.uppercased(),
                    path: path,
                    queryParams: queryParams,
                    headerParams: headerParams,
                    bodyParamNames: bodyParamNames
                )

                let toolDef = UTCPToolDefinition(
                    name: toolName,
                    description: opDescription,
                    parametersSchema: propertiesSchema,
                    requiredParameters: requiredParams,
                    execution: .http(httpExec),
                    safety: safety,
                    tags: tags
                )

                tools.append(toolDef)
            }
        }

        let protocolsConfig = UTCPProtocolsConfig(
            http: UTCPProtocolsConfig.HTTPConfig(baseURL: baseURL, defaultHeaders: nil),
            cli: nil
        )

        return UTCPManual(
            utcpVersion: "1.0",
            name: sanitizeToolName(title),
            description: description,
            protocols: protocolsConfig,
            tools: tools
        )
    }
}
