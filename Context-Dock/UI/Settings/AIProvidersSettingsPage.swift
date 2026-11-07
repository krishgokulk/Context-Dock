import SwiftUI

/// AI Providers is now one job: choose a provider and configure it. Computer Use moved to
/// Permissions, the MCP server and provider diagnostics moved to Advanced, and the Claude
/// Code "continue editor session" toggle now shows only under the Claude Code provider
/// (owner 2026-11-07).
struct AIProvidersSettingsPage: View {
    var body: some View {
        AIProviderSettingsView()
    }
}
