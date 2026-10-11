// Context-DockTests/PluginPermissionsTests.swift
import Foundation
import Testing

@testable import Context_Dock

struct PluginPermissionsTests {
    private func manifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    @Test func aScriptActionImpliesTheShellPermission() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "actions": { "go": { "type": "bash", "script": "rm -rf /tmp/x" } } }"#)
        #expect(PluginPermissions.required(for: m).implied.contains("shell"))
    }

    @Test func anHttpDataSourceImpliesNetworkForItsHost() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "data": { "type": "http", "script": "https://api.example.com/v1/status" } }"#)
        #expect(PluginPermissions.required(for: m).implied.contains("network:api.example.com"))
    }

    @Test func aPermissionItNeedsButNeverDeclaredIsReported() throws {
        // The manifest's own list is a claim. What it needs comes from what it contains, and
        // the difference is what a person is asked about at install.
        let m = try manifest(#"{ "id": "x", "name": "X", "permissions": [], "actions": { "go": { "type": "bash", "script": "true" } } }"#)
        #expect(PluginPermissions.required(for: m).undeclared.contains("shell"))
    }

    @Test func aDeclaredPermissionItDoesNotNeedIsNotRequired() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "permissions": ["network:local"], "views": { "panel": { "title": "hi" } } }"#)
        let set = PluginPermissions.required(for: m)
        #expect(set.implied.isEmpty)
        #expect(set.undeclared.isEmpty)
    }

    @Test func readIsTheOnlyRiskThatRunsWithoutAsking() {
        #expect(PluginPermissions.needsApproval(PluginAction(type: "bash", script: "ls", risk: .read)) == false)
        #expect(PluginPermissions.needsApproval(PluginAction(type: "bash", script: "rm x", risk: .low)))
        #expect(PluginPermissions.needsApproval(PluginAction(type: "bash", script: "rm x", risk: .medium)))
        #expect(PluginPermissions.needsApproval(PluginAction(type: "bash", script: "rm x", risk: .high)))
    }

    @Test func aHostIsReachableOnlyWhenItWasDeclared() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "permissions": ["network:api.example.com"] }"#)
        #expect(PluginPermissions.allowsHost("api.example.com", manifest: m))
        #expect(PluginPermissions.allowsHost("evil.example.com", manifest: m) == false)
    }

    @Test func networkLocalCoversLoopbackAndNothingElse() throws {
        let m = try manifest(#"{ "id": "x", "name": "X", "permissions": ["network:local"] }"#)
        #expect(PluginPermissions.allowsHost("127.0.0.1", manifest: m))
        #expect(PluginPermissions.allowsHost("localhost", manifest: m))
        #expect(PluginPermissions.allowsHost("192.168.1.40", manifest: m))
        #expect(PluginPermissions.allowsHost("example.com", manifest: m) == false)
    }

    @Test func aPluginThatDeclaredNoNetworkReachesNothing() throws {
        let m = try manifest(#"{ "id": "x", "name": "X" }"#)
        #expect(PluginPermissions.allowsHost("example.com", manifest: m) == false)
        #expect(PluginPermissions.allowsHost("127.0.0.1", manifest: m) == false)
    }
}
