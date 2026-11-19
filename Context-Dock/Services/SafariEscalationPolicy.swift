// SafariEscalationPolicy.swift
// Context-Dock
//
// Routes Safari operations between:
//  Engine 1 — Context-DockExtension (zero focus theft, live-tab content)
//  Engine 2 — /usr/bin/safaridriver --mcp (console logs, network, screenshots, automation)
//
// Rule: if the caller doesn't know which engine to use, ask the policy.
// The policy never starts Engine 2 itself — it only classifies the request.

import Foundation

// MARK: - Engine

/// Which Safari integration handles a given operation.
enum SafariEngine: String, Equatable, Sendable {
    /// Our own Safari Web Extension: tab metadata, page text, structured article extraction,
    /// link queries. Zero automation banner; zero focus theft; runs on live user tabs.
    case extensionLightweight = "Safari Extension (Live Tab)"
    /// Apple's safaridriver --mcp: console error logs, network traffic inspection,
    /// full-page screenshots, native dialog handling, complex form automation.
    case safariDriverMCP = "safaridriver --mcp (Automation Session)"

    /// Label for turn traces and progress panels ("Route: …").
    var routeLabel: String { "Route: \(rawValue)" }
}

// MARK: - Policy

enum SafariEscalationPolicy {

    // Engine 2 operations — anything requiring deep browser automation or inspection.
    private static let engine2CapabilityIDs: Set<String> = [
        "browser_console_messages",
        "list_network_requests",
        "get_network_request",
        "screenshot",
        "fullpage_screenshot",
        "browser_dialogs",
        "execute_script_automation",
        "network_inspect",
        "console_errors",
        "console_logs",
    ]

    // Keyword substrings that signal deep automation regardless of exact id.
    private static let engine2Keywords: [String] = [
        "console_message",
        "console_error",
        "console_log",
        "network_request",
        "network_traffic",
        "screenshot",
        "dialog",
        "automation",
    ]

    // MARK: - Classification

    /// Returns the engine that should handle `capabilityID`.
    static func engine(for capabilityID: String) -> SafariEngine {
        if engine2CapabilityIDs.contains(capabilityID) { return .safariDriverMCP }
        let lower = capabilityID.lowercased()
        for kw in engine2Keywords where lower.contains(kw) {
            return .safariDriverMCP
        }
        return .extensionLightweight
    }

    /// Human-readable route label for turn traces.
    /// Example: "Route: Safari Extension (Live Tab)"
    static func routeLabel(for capabilityID: String) -> String {
        engine(for: capabilityID).routeLabel
    }

    /// True when the operation must escalate to `safaridriver --mcp`.
    static func requiresDeepAutomation(_ capabilityID: String) -> Bool {
        engine(for: capabilityID) == .safariDriverMCP
    }
}
