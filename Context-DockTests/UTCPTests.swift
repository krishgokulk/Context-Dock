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
}
