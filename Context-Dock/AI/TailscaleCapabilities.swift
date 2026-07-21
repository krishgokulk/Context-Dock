import Foundation

@MainActor
enum TailscaleCapabilities {
    static func register(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "tailscale.status",
                title: "Tailscale Status",
                appBundleID: "io.tailscale.ipn.macsys",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                let result = await TerminalCommandExecutor.shared.run(
                    "tailscale status",
                    purpose: "Inspect Tailscale connection status"
                )
                return .init(success: result.success, output: result.output)
            }
        )

        registry.register(
            AICapability(
                id: "tailscale.netcheck",
                title: "Tailscale Network Check",
                appBundleID: "io.tailscale.ipn.macsys",
                inputSchema: .init(fields: []),
                riskLevel: .low
            ) { _ in
                let result = await TerminalCommandExecutor.shared.run(
                    "tailscale netcheck",
                    purpose: "Inspect Tailscale network connectivity"
                )
                return .init(success: result.success, output: result.output)
            }
        )
    }
}
