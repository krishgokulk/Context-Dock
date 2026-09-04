import Foundation

/// The one implementation of "remove this app integration".
///
/// Two Settings surfaces offer removal while the Integrations workspace is being built, and
/// the sequence is not obvious: deleting the adapter alone leaves the app's custom entries,
/// tool extensions, and CLI links pointing at something that no longer exists. Keeping the
/// steps here means the two callers cannot drift apart.
///
/// What it does not touch is deliberate: skills, MCP servers, and API connections live in
/// their own stores and survive removal, so nothing here silently discards a Keychain-backed
/// connection the user would have to reconnect.
enum IntegrationRemovalService {
    @MainActor
    static func removeAppIntegration(bundleId: String) async {
        await AppAdapterManager.shared.deleteAdapter(bundleId: bundleId)

        let settings = AppSettings.shared
        let packageManager = TerminalPackageManager.shared

        settings.customAppEntries.removeAll {
            $0.key == bundleId || $0.appPath == bundleId
        }
        settings.appToolExtensions.removeAll { $0.appKey == bundleId }

        for package in packageManager.packages
        where package.contextAppBundleIds.contains(bundleId) {
            var updated = package
            updated.contextAppBundleIds.removeAll { $0 == bundleId }
            packageManager.updatePackage(updated)
        }

        // A CLI-backed identity also carries a pin and a synthetic app entry.
        guard bundleId.hasPrefix("cli://") else { return }
        let command = String(bundleId.dropFirst("cli://".count))
        settings.unpinCLITool(command)
        settings.customAppEntries.removeAll {
            $0.key == "cli_\(command)" || $0.appPath == "cli://\(command)"
        }
        if let package = packageManager.packages.first(where: { $0.command == command }) {
            var updated = package
            updated.contextAppBundleIds.removeAll {
                $0 == bundleId || $0 == "cli_\(command)"
            }
            packageManager.updatePackage(updated)
        }
    }
}
