// Context-Dock
//
// What is wrong with a manifest, as a list the Creator can show and a test can assert.
// Errors stop a plugin from installing; warnings do not. Every rule here has a test in
// PluginSchemaTests named after it.

import Foundation

struct PluginDiagnostic: Equatable, CustomStringConvertible {
    enum Severity: Equatable { case error, warning }
    let severity: Severity
    let path: String
    let message: String

    var description: String {
        "\(severity == .error ? "error" : "warning") at \(path): \(message)"
    }
}

enum PluginSchema {
    static let allowedInputs: Set<String> = [
        "query", "selection.text", "selection.files", "selection.url", "selection.image",
        "clipboard.text", "clipboard.files", "clipboard.image", "clipboard.history",
    ]

    static func hasErrors(_ diagnostics: [PluginDiagnostic]) -> Bool {
        diagnostics.contains { $0.severity == .error }
    }

    static func validate(_ m: PluginManifest) -> [PluginDiagnostic] {
        var out: [PluginDiagnostic] = []
        func error(_ path: String, _ message: String) { out.append(.init(severity: .error, path: path, message: message)) }
        func warn(_ path: String, _ message: String) { out.append(.init(severity: .warning, path: path, message: message)) }

        // 12. id
        let slug = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]*$")
        if slug.firstMatch(in: m.id, range: NSRange(m.id.startIndex..., in: m.id)) == nil {
            error("id", "id \"\(m.id)\" must be a lowercase slug (a-z, 0-9, -)")
        }

        // 10. inputs
        for input in m.inputs + (m.agent?.inputs ?? []) {
            let base = input.hasSuffix("?") ? String(input.dropLast()) : input
            if !allowedInputs.contains(base) {
                error("inputs", "input \"\(input)\" is not one of \(allowedInputs.sorted().joined(separator: ", "))")
            }
        }

        // 6. something to show or run
        if m.declaredPresentations.isEmpty && m.primaryAction == nil && m.agent == nil {
            error("views", "nothing to show or run: declare a view, a primaryAction, or an agent")
        }
        if let primary = m.primaryAction, m.actions[primary] == nil {
            error("primaryAction", "primaryAction \"\(primary)\" is not declared in actions")
        }

        // 5. agent.tools
        for tool in m.agent?.tools ?? [] where m.actions[tool] == nil {
            error("agent.tools", "tool \"\(tool)\" is not a declared action")
        }

        // 7, 11. data
        if let data = m.data {
            if data.type == .http {
                let url = URL(string: data.script)
                if let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host {
                    let needed = "network:\(host)"
                    if !m.permissions.contains(needed) && !m.permissions.contains("network:local") {
                        error("permissions", "http data needs permission \"\(needed)\"")
                    }
                } else {
                    error("data.script", "http data script \"\(data.script)\" is not a URL")
                }
            }
            for (presentation, seconds) in data.refresh where seconds < 1 {
                error("data.refresh.\(presentation.rawValue)", "refresh.\(presentation.rawValue) must be at least 1 second")
            }
            if data.timeout < 1 || data.timeout > 60 {
                error("data.timeout", "timeout must be between 1 and 60 seconds")
            }
        }

        // 8, 9. actions
        for (name, action) in m.actions {
            if action.type == "shortcut" && !m.permissions.contains("system:shortcuts") {
                warn("actions.\(name)", "a shortcut action usually needs permission \"system:shortcuts\"")
            }
            if let target = action.pushTarget {
                if let presentation = PluginPresentation(rawValue: target) {
                    if !m.declaredPresentations.contains(presentation) {
                        error("actions.\(name)", "push:\(target) targets a view this plugin has not declared")
                    }
                } else {
                    error("actions.\(name)", "push:\(target) is not a presentation")
                }
            }
            if let undo = action.undo, m.actions[undo] == nil {
                error("actions.\(name)", "undo \"\(undo)\" is not a declared action")
            }
        }

        // 1–4. views
        let sampleKeys = Set(m.sample.keys)
        for node in m.allNodes {
            let path = "views.\(node.component)"
            if !PluginComponentCatalog.isKnown(node.component) {
                error(path, "unknown component \"\(node.component)\"")
                continue
            }
            if !node.children.isEmpty && !PluginComponentCatalog.takesChildren(node.component) {
                error(path, "\"\(node.component)\" does not take children")
            }
            for (prop, value) in node.props {
                if let key = value.bindingKey {
                    let top = String(key.split(separator: ".").first ?? Substring(key))
                    let implicit = top == "item" || top == "lines" || top == "value"
                    if !implicit && !sampleKeys.contains(top) {
                        warn("\(path).\(prop)", "binding \"\(top)\" is not in sample; the preview will show it empty")
                    }
                } else if PluginComponentCatalog.actionProps.contains(prop), let name = value.stringValue {
                    if m.actions[name] == nil {
                        error("\(path).\(prop)", "action \"\(name)\" is not declared")
                    }
                }
            }
        }

        return out
    }
}
