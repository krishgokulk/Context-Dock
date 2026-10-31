//  UTCPDirectExecutor.swift
//  Context-Dock
//
//  Direct, proxy-free executor for UTCP tools.
//  Executes HTTP requests directly via native URLSession (with Keychain auth)
//  and CLI tools via Process, eliminating external Node/Python wrapper daemons.

import Foundation

actor UTCPDirectExecutor {
    static let shared = UTCPDirectExecutor()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Executes an HTTP UTCP tool call directly without intermediate daemons.
    func executeHTTP(
        execution: UTCPExecution.HTTPExecution,
        baseURL: URL,
        apiKey: String? = nil,
        defaultHeaders: [String: String]? = nil,
        arguments: [String: Any]
    ) async -> (success: Bool, output: String) {
        var path = execution.path

        // 1. Path parameter interpolation: replace {param} with argument values
        for (key, val) in arguments {
            let placeholder = "{\(key)}"
            if path.contains(placeholder) {
                let stringVal = "\(val)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "\(val)"
                path = path.replacingOccurrences(of: placeholder, with: stringVal)
            }
        }

        // 2. Resolve URL
        guard let resolvedURL = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            return (false, "UTCP error: Invalid URL resolved from base '\(baseURL.absoluteString)' and path '\(path)'.")
        }

        var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: true)

        // 3. Query parameters
        var queryItems: [URLQueryItem] = components?.queryItems ?? []
        for qName in execution.queryParams {
            if let val = arguments[qName], !(path.contains("{\(qName)}")) {
                queryItems.append(URLQueryItem(name: qName, value: "\(val)"))
            }
        }
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }

        guard let finalURL = components?.url else {
            return (false, "UTCP error: Unable to construct valid URL components for '\(resolvedURL)'.")
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = execution.method
        request.timeoutInterval = 30.0

        // 4. Headers
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let defaultHeaders {
            for (k, v) in defaultHeaders {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }
        for hName in execution.headerParams {
            if let val = arguments[hName] {
                request.setValue("\(val)", forHTTPHeaderField: hName)
            }
        }

        // 5. Auth / Secret injection
        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            if request.value(forHTTPHeaderField: "Authorization") == nil {
                if apiKey.hasPrefix("Bearer ") || apiKey.hasPrefix("Basic ") || apiKey.hasPrefix("Token ") {
                    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
                } else {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
            }
        }

        // 6. Request Body
        if ["POST", "PUT", "PATCH"].contains(execution.method) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var bodyDict: [String: Any] = [:]
            if !execution.bodyParamNames.isEmpty {
                for bName in execution.bodyParamNames {
                    if let val = arguments[bName] {
                        bodyDict[bName] = val
                    }
                }
            } else {
                // If bodyParamNames was not explicitly enumerated, include arguments not consumed by path/query/headers
                let consumedKeys = Set(execution.queryParams + execution.headerParams)
                for (k, v) in arguments {
                    if !consumedKeys.contains(k) && !path.contains("{\(k)}") {
                        bodyDict[k] = v
                    }
                }
            }

            if !bodyDict.isEmpty {
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
                } catch {
                    return (false, "UTCP error: Failed to serialize request body: \(error.localizedDescription)")
                }
            }
        }

        // 7. Dispatch via URLSession
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "UTCP error: Received non-HTTP response.")
            }

            let text = String(data: data, encoding: .utf8) ?? "(binary or unreadable output: \(data.count) bytes)"
            let isSuccess = (200...299).contains(httpResponse.statusCode)

            if !isSuccess {
                return (false, "HTTP \(httpResponse.statusCode) error: \(text)")
            }

            let compacted = AgentToolResultStore.compactForModel(text, toolName: finalURL.lastPathComponent)
            return (true, compacted)
        } catch {
            return (false, "UTCP network error: \(error.localizedDescription)")
        }
    }

    /// Executes a CLI UTCP tool call directly.
    func executeCLI(
        execution: UTCPExecution.CLIExecution,
        arguments: [String: Any]
    ) async -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var fullArgs: [String] = [execution.command]
        fullArgs.append(contentsOf: execution.args)

        for (k, v) in arguments {
            fullArgs.append("--\(k)")
            fullArgs.append("\(v)")
        }

        process.arguments = fullArgs

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let success = (process.terminationStatus == 0)

            let compacted = AgentToolResultStore.compactForModel(output, toolName: execution.command)
            return (success, compacted)
        } catch {
            return (false, "UTCP CLI execution error: \(error.localizedDescription)")
        }
    }
}
