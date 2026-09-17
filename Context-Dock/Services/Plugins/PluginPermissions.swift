// Context-Dock
//
// What a manifest is allowed to do. A plugin is a text file that asks to run shell, so the
// rule here is that its own `permissions` list is a CLAIM, not a grant: what it actually needs
// is derived from what it contains, and anything it needs but never declared is reported rather
// than quietly allowed. Spec §9.

import Foundation

struct PluginPermissionSet: Equatable {
    /// Derived from the manifest's contents — what it cannot run without.
    let implied: Set<String>
    /// What the manifest says it wants.
    let declared: Set<String>
    /// Needed, never declared. This is the list a person is asked about at install.
    let undeclared: Set<String>
}

enum PluginPermissions {
    static func required(for manifest: PluginManifest) -> PluginPermissionSet {
        var implied: Set<String> = []

        func note(type: String, script: String?) {
            guard let kind = PluginScriptType(rawValue: type) else { return }  // built-ins imply nothing
            switch kind {
            case .bash, .applescript, .jxa, .scriptFile:
                implied.insert("shell")
            case .shortcut:
                implied.insert("shortcuts")
            case .http:
                if let host = host(of: script) { implied.insert("network:\(host)") }
            }
        }

        if let data = manifest.data { note(type: data.type.rawValue, script: data.script) }
        for action in manifest.actions.values { note(type: action.type, script: action.script) }

        let declared = Set(manifest.permissions)
        return PluginPermissionSet(
            implied: implied, declared: declared,
            undeclared: implied.subtracting(declared))
    }

    /// Read is the only risk that runs unasked. Every other level reaches the approval centre,
    /// which is the app's one approval surface rather than a second one grown here.
    static func needsApproval(_ action: PluginAction) -> Bool { action.risk != .read }

    /// A host is reachable only when the manifest declared it. `network:local` covers loopback
    /// and the private ranges — the Sonos case, where the speaker is on the LAN and has no
    /// public name — and nothing else. A manifest that declared no network reaches nothing.
    static func allowsHost(_ host: String, manifest: PluginManifest) -> Bool {
        let declared = Set(manifest.permissions)
        if declared.contains("network:\(host)") { return true }
        guard declared.contains("network:local") else { return false }
        return isLocal(host)
    }

    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasSuffix(".local") { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        // 172.16.0.0 – 172.31.255.255, which is the half of 172.* that is private.
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "172", let second = Int(parts[1]),
            (16...31).contains(second) {
            return true
        }
        return false
    }

    private static func host(of script: String?) -> String? {
        guard let script, let url = URL(string: script.trimmingCharacters(in: .whitespaces)),
            let host = url.host, !host.isEmpty
        else { return nil }
        return host
    }
}
