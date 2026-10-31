//  UTCPTests.swift
//  Context-DockTests
//
//  Tests for UTCP models, OpenAPI ingestion, and manual parsing.

import Foundation
import Testing

@testable import Context_Dock

struct UTCPTests {
    @Test func decodesNativeUTCPManual() throws {
        let json = """
        {
          "utcp_version": "1.0",
          "name": "linear_service",
          "description": "Linear Issue Tracker API",
          "protocols": {
            "http": {
              "baseURL": "https://api.linear.app"
            }
          },
          "tools": [
            {
              "name": "list_issues",
              "description": "Lists all issues in a team",
              "parametersSchema": {
                "teamId": { "string": "Team identifier" }
              },
              "requiredParameters": ["teamId"],
              "execution": {
                "http": {
                  "method": "GET",
                  "path": "/issues",
                  "queryParams": ["teamId"],
                  "headerParams": [],
                  "bodyParamNames": []
                }
              },
              "safety": "read",
              "tags": ["issues", "linear"]
            }
          ]
        }
        """

        let manual = try UTCPManualParser.parse(text: json)
        #expect(manual.name == "linear_service")
        #expect(manual.tools.count == 1)

        let tool = try #require(manual.tools.first)
        #expect(tool.name == "list_issues")
        #expect(tool.safety == .read)
        #expect(!tool.safety.requiresApproval)
        #expect(tool.requiredParameters == ["teamId"])
    }

    @Test func parsesOpenAPI3SpecIntoUTCPManual() throws {
        let openapi = """
        {
          "openapi": "3.0.1",
          "info": {
            "title": "GitHub Issues API",
            "description": "Interact with repository issues",
            "version": "1.0.0"
          },
          "servers": [
            { "url": "https://api.github.com" }
          ],
          "paths": {
            "/repos/{owner}/{repo}/issues": {
              "get": {
                "operationId": "listRepoIssues",
                "summary": "List issues for a repository",
                "parameters": [
                  {
                    "name": "owner",
                    "in": "path",
                    "required": true,
                    "schema": { "type": "string" }
                  },
                  {
                    "name": "repo",
                    "in": "path",
                    "required": true,
                    "schema": { "type": "string" }
                  },
                  {
                    "name": "state",
                    "in": "query",
                    "required": false,
                    "description": "Filter by state: open, closed, all",
                    "schema": { "type": "string" }
                  }
                ]
              },
              "post": {
                "operationId": "createRepoIssue",
                "summary": "Create an issue in a repository",
                "parameters": [
                  {
                    "name": "owner",
                    "in": "path",
                    "required": true,
                    "schema": { "type": "string" }
                  },
                  {
                    "name": "repo",
                    "in": "path",
                    "required": true,
                    "schema": { "type": "string" }
                  }
                ],
                "requestBody": {
                  "required": true,
                  "content": {
                    "application/json": {
                      "schema": {
                        "type": "object",
                        "required": ["title"],
                        "properties": {
                          "title": { "type": "string", "description": "The title of the issue" },
                          "body": { "type": "string", "description": "The contents of the issue" }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """

        let manual = try UTCPManualParser.parse(text: openapi)
        #expect(manual.protocols.http?.baseURL == "https://api.github.com")
        #expect(manual.tools.count == 2)

        // Verify read operation
        let listTool = try #require(manual.tools.first { $0.name == "listRepoIssues" })
        #expect(listTool.safety == .read)
        #expect(!listTool.safety.requiresApproval)
        #expect(listTool.requiredParameters.contains("owner"))
        #expect(listTool.requiredParameters.contains("repo"))

        // Verify write operation
        let createTool = try #require(manual.tools.first { $0.name == "createRepoIssue" })
        #expect(createTool.safety == .write)
        #expect(createTool.safety.requiresApproval)
        #expect(createTool.requiredParameters.contains("title"))
        #expect(createTool.parametersSchema["body"] != nil)
    }

    @Test func safetyInferenceHandlesEdgeCases() {
        #expect(UTCPToolSafety.infer(method: "GET", name: "fetch_data") == .read)
        #expect(UTCPToolSafety.infer(method: "POST", name: "create_record") == .write)
        #expect(UTCPToolSafety.infer(method: "DELETE", name: "delete_record") == .write)
        #expect(UTCPToolSafety.infer(method: "CUSTOM", name: "search_logs") == .read)
        #expect(UTCPToolSafety.infer(method: "CUSTOM", name: "delete_logs") == .write)
    }

    @Test func directExecutorPerformsHTTPAndInjectsAuth() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockUTCPURLProtocol.self]
        let session = URLSession(configuration: config)
        let executor = UTCPDirectExecutor(session: session)

        MockUTCPURLProtocol.requestHandler = { request in
            #expect(request.url?.absoluteString == "https://api.github.com/repos/apple/swift/issues?state=open")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret_test_token")
            #expect(request.httpMethod == "GET")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = """
            [{"id": 1, "title": "Fix bug"}]
            """.data(using: .utf8)!
            return (response, data)
        }

        let exec = UTCPExecution.HTTPExecution(
            method: "GET",
            path: "/repos/{owner}/{repo}/issues",
            queryParams: ["state"],
            headerParams: [],
            bodyParamNames: []
        )

        let (success, output) = await executor.executeHTTP(
            execution: exec,
            baseURL: URL(string: "https://api.github.com")!,
            apiKey: "secret_test_token",
            arguments: [
                "owner": "apple",
                "repo": "swift",
                "state": "open"
            ]
        )

        #expect(success)
        #expect(output.contains("Fix bug"))
    }

    @MainActor
    @Test func toolBridgeRegistersAndUnregistersWithRegistry() throws {
        let manual = UTCPManual(
            utcpVersion: "1.0",
            name: "sample_service",
            description: "Test service",
            protocols: UTCPProtocolsConfig(http: .init(baseURL: "https://api.example.com")),
            tools: [
                UTCPToolDefinition(
                    name: "get_status",
                    description: "Fetch status",
                    execution: .http(.init(method: "GET", path: "/status")),
                    safety: .read
                )
            ]
        )

        let bridge = UTCPToolBridge.shared
        let groupKey = "test_group_\(UUID().uuidString)"
        let registered = bridge.register(manual: manual, groupKey: groupKey, prefix: "testapi")
        #expect(registered == ["testapi_get_status"])

        let tool = AgentToolRegistry.shared.tool(named: "testapi_get_status")
        #expect(tool != nil)
        #expect(tool?.name == "testapi_get_status")

        bridge.unregisterGroup(groupKey)
        #expect(AgentToolRegistry.shared.tool(named: "testapi_get_status") == nil)
    }

    @MainActor
    @Test func apiConnectionStoreRegistersAndUnregistersTools() throws {
        let spec = """
        {
          "utcp_version": "1.0",
          "name": "notion_service",
          "description": "Notion API",
          "protocols": {
            "http": {
              "baseURL": "https://api.notion.com"
            }
          },
          "tools": [
            {
              "name": "search_pages",
              "description": "Search Notion pages",
              "parametersSchema": {
                "query": { "string": "Search query" }
              },
              "requiredParameters": ["query"],
              "execution": {
                "http": {
                  "method": "POST",
                  "path": "/v1/search",
                  "queryParams": [],
                  "headerParams": [],
                  "bodyParamNames": ["query"]
                }
              },
              "safety": "read"
            }
          ]
        }
        """

        let bundleId = "test.bundle.\(UUID().uuidString)"
        let store = APIConnectionStore.shared
        let conn = store.connect(
            name: "Notion",
            baseURL: "https://api.notion.com",
            apiKey: "ntn_mock_key",
            bundleId: bundleId,
            specText: spec
        )

        #expect(conn.toolCount == 1)
        #expect(conn.specText != nil)
        #expect(AgentToolRegistry.shared.tool(named: "notion_search_pages") != nil)

        store.disconnect(id: conn.id)
        #expect(AgentToolRegistry.shared.tool(named: "notion_search_pages") == nil)
    }

    @MainActor
    @Test func appPetManifestRegistersBundledUTCPManuals() throws {
        let manual = UTCPManual(
            utcpVersion: "1.0",
            name: "jira_service",
            description: "Jira Issue Tracker",
            protocols: UTCPProtocolsConfig(http: .init(baseURL: "https://jira.example.com")),
            tools: [
                UTCPToolDefinition(
                    name: "get_ticket",
                    description: "Fetch a ticket by key",
                    execution: .http(.init(method: "GET", path: "/issue/{key}")),
                    safety: .read
                )
            ]
        )

        let manifest = AppPetManifest(
            id: "com.atlassian.Jira",
            appName: "Jira",
            bundleID: "com.atlassian.Jira",
            summary: "Jira Pet companion",
            utcpManuals: [manual]
        )

        let registry = AppPetManifestRegistry.shared
        registry.register(manifest)

        // Wait for main dispatch
        let toolName = "jira_get_ticket"
        let bridge = UTCPToolBridge.shared
        bridge.register(manual: manual, groupKey: "pet:\(manifest.id)", prefix: manifest.appName)

        #expect(AgentToolRegistry.shared.tool(named: toolName) != nil)
        bridge.unregisterGroup("pet:\(manifest.id)")
        #expect(AgentToolRegistry.shared.tool(named: toolName) == nil)
    }
}

final class MockUTCPURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockUTCPURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

