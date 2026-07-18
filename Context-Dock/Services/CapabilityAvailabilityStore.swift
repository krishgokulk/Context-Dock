//  CapabilityAvailabilityStore.swift
//  Context-Dock
//
//  Failure-driven capability invalidation for DoraX Action Chat. Most invalidation is
//  already LIVE (the resolver reads connected MCP tools, installed CLI packages, the
//  installed-apps catalog), so a disconnected/uninstalled capability simply stops producing
//  candidates. This store adds the missing piece: when a route FAILS at execution/verify,
//  skip it for a short cooldown so General Chat immediately falls back to the next safest
//  route instead of proposing the broken one again.
//
//  In-memory + session-scoped on purpose: a reinstalled tool or reconnected server is
//  re-detected live, so we never want a stale on-disk "unavailable" flag suppressing it.

import Foundation

@MainActor
final class CapabilityAvailabilityStore {
    static let shared = CapabilityAvailabilityStore()

    struct Entry {
        var lastSeenAvailable: Date?
        var lastFailureReason: String?
        var unavailableUntil: Date?
    }

    /// Default cooldown after a route fails. Short, so a transient failure doesn't hide a
    /// route for long; long enough to fall back on the immediate retry.
    nonisolated static let defaultCooldown: TimeInterval = 120

    private var entries: [String: Entry] = [:]

    private init() {}

    /// Stable identity for a route: class + app/tool + capability.
    static func key(route: String, bundleID: String, capabilityID: String, id: String) -> String {
        "\(route)|\(bundleID)|\(capabilityID)|\(id)"
    }

    func isAvailable(key: String) -> Bool {
        guard let until = entries[key]?.unavailableUntil else { return true }
        return Date() >= until
    }

    func markUnavailable(key: String, reason: String, cooldown: TimeInterval = defaultCooldown) {
        var entry = entries[key] ?? Entry()
        entry.lastFailureReason = reason
        entry.unavailableUntil = Date().addingTimeInterval(cooldown)
        entries[key] = entry
    }

    /// Clear any unavailable flag and record that the route just worked.
    func markAvailable(key: String) {
        var entry = entries[key] ?? Entry()
        entry.lastSeenAvailable = Date()
        entry.unavailableUntil = nil
        entry.lastFailureReason = nil
        entries[key] = entry
    }

    func failureReason(key: String) -> String? { entries[key]?.lastFailureReason }
}
