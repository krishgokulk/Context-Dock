// SafariExtensionHookRegistry.swift
// Context-Dock
//
// Lightweight in-memory registry of extension hooks contributed by installed .doraxpack bundles.
// Hooks are executable JavaScript snippets that run in the user's real Safari tabs via
// SafariExtensionCommandBridge, registered here AND as callable AICapability tools in
// CapabilityRegistry (Task U8b) so the AI harness can invoke them directly.

import AppKit
import Foundation

// MARK: - Capability

/// A registered extension hook ready for execution through SafariExtensionCommandBridge.
struct ExtensionHookCapability: Identifiable, Equatable {
    /// Stable identifier matching DoraxExtensionHook.id (e.g. "safari.extractStructured").
    let id: String
    let name: String
    /// URL pattern the hook declares itself applicable to (e.g. "*" for all pages).
    let urlPattern: String
    /// Filename inside the pack's `page_scripts/` folder.
    let scriptFile: String
    /// Source pack identifier (e.g. "safari").
    let packID: String
    /// Target app bundle ID (defaults to "com.apple.Safari" for `safari.*` hooks).
    let bundleID: String?
    /// Loaded JavaScript source from the pack's `page_scripts/<scriptFile>`, if available.
    let scriptCode: String?

    init(
        id: String,
        name: String,
        urlPattern: String,
        scriptFile: String,
        packID: String,
        bundleID: String? = nil,
        scriptCode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.urlPattern = urlPattern
        self.scriptFile = scriptFile
        self.packID = packID
        self.bundleID = bundleID
        self.scriptCode = scriptCode
    }
}

// MARK: - Registry

/// Collects `ExtensionHookCapability` entries from every installed .doraxpack and registers
/// each as a callable `AICapability` in `CapabilityRegistry`.
/// Registered by `StorePackInstaller.installV2` and `installAllV2`; cleared on uninstall.
final class ExtensionHookRegistry: @unchecked Sendable {
    static let shared = ExtensionHookRegistry()
    init() {}

    private let lock = NSLock()
    private var _capabilities: [ExtensionHookCapability] = []

    var capabilities: [ExtensionHookCapability] {
        lock.lock()
        defer { lock.unlock() }
        return _capabilities
    }

    /// Register hooks contributed by a pack. Idempotent: re-registering the same `id` replaces
    /// the existing entry so reinstalls and updates stay consistent.
    /// Also registers each hook as a callable `AICapability` in `CapabilityRegistry`.
    func register(
        hooks: [DoraxExtensionHook],
        packID: String,
        bundleID: String? = nil,
        pageScripts: [DoraxPackScriptEntry] = [],
        registerInCapabilityRegistry: Bool = true
    ) {
        let scriptsByFilename = Dictionary(
            pageScripts.map { ($0.filename, $0.content) },
            uniquingKeysWith: { _, last in last })

        var registered: [ExtensionHookCapability] = []
        lock.lock()
        for hook in hooks {
            let resolvedBundleID = bundleID
                ?? (hook.id.hasPrefix("safari.") ? "com.apple.Safari" : nil)
            let cap = ExtensionHookCapability(
                id: hook.id,
                name: hook.name,
                urlPattern: hook.urlPattern,
                scriptFile: hook.scriptFile,
                packID: packID,
                bundleID: resolvedBundleID,
                scriptCode: scriptsByFilename[hook.scriptFile])
            if let idx = _capabilities.firstIndex(where: { $0.id == cap.id }) {
                _capabilities[idx] = cap
            } else {
                _capabilities.append(cap)
            }
            registered.append(cap)
        }
        lock.unlock()

        if registerInCapabilityRegistry {
            let toRegister = registered
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    for hookCap in toRegister {
                        CapabilityRegistry.shared.register(Self.makeAICapability(for: hookCap))
                    }
                }
            } else {
                Task { @MainActor in
                    for hookCap in toRegister {
                        CapabilityRegistry.shared.register(Self.makeAICapability(for: hookCap))
                    }
                }
            }
        }
    }

    /// Remove all hooks contributed by a pack (call on uninstall / replacement).
    func unregister(packID: String, removeFromCapabilityRegistry: Bool = true) {
        lock.lock()
        let removedIDs = _capabilities.filter { $0.packID == packID }.map(\.id)
        _capabilities.removeAll { $0.packID == packID }
        lock.unlock()

        if removeFromCapabilityRegistry, !removedIDs.isEmpty {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    for id in removedIDs {
                        CapabilityRegistry.shared.removeCapability(id: id)
                    }
                }
            } else {
                Task { @MainActor in
                    for id in removedIDs {
                        CapabilityRegistry.shared.removeCapability(id: id)
                    }
                }
            }
        }
    }

    func capability(for id: String) -> ExtensionHookCapability? {
        lock.lock()
        defer { lock.unlock() }
        return _capabilities.first { $0.id == id }
    }

    /// Converts an `ExtensionHookCapability` into a callable `AICapability` that executes
    /// via `SafariExtensionCommandBridge.executeExtensionHook(...)` (Engine 1: live tab).
    @MainActor
    static func makeAICapability(for hook: ExtensionHookCapability) -> AICapability {
        let targetBundleID = hook.bundleID
            ?? (hook.id.hasPrefix("safari.") ? "com.apple.Safari" : nil)
        return AICapability(
            id: hook.id,
            title: hook.name,
            appBundleID: targetBundleID,
            inputSchema: AICapabilityInputSchema(fields: [
                AICapabilityInputField(
                    name: "url",
                    description: "Optional page URL to check against sensitive-URL policy; defaults to the active Safari tab URL.",
                    required: false)
            ]),
            riskLevel: .low,
            runsWithoutAdapter: true,
            executor: { request in
                let engine = SafariEscalationPolicy.decide(for: hook.id)
                let bundle = targetBundleID ?? "com.apple.Safari"
                guard let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == bundle
                }) else {
                    return AICapabilityExecutionResult(
                        success: false,
                        output: "Safari is not running.",
                        laneSteps: [engine.routeLabel])
                }
                guard let script = hook.scriptCode, !script.isEmpty else {
                    return AICapabilityExecutionResult(
                        success: false,
                        output: "Extension hook '\(hook.id)' has no loaded script (\(hook.scriptFile)).",
                        laneSteps: [engine.routeLabel])
                }
                let pageURL = request.input["url"]
                    ?? SafariBrowserBridge.shared.currentContext()?.url
                do {
                    let result = try await SafariExtensionCommandBridge.shared.executeExtensionHook(
                        hookID: hook.id,
                        scriptCode: script,
                        pageURL: pageURL,
                        in: app)
                    let output = result.isUntrustedContent
                        ? UntrustedContent.fenced(result.text, from: "Safari extension hook \(hook.id)")
                        : result.text
                    return AICapabilityExecutionResult(
                        success: true,
                        output: output,
                        laneSteps: [result.route])
                } catch {
                    return AICapabilityExecutionResult(
                        success: false,
                        output: error.localizedDescription,
                        laneSteps: [engine.routeLabel])
                }
            })
    }
}
