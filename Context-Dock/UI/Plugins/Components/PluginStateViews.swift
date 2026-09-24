// Context-Dock
//
// The three things a panel shows when it is not showing content: nothing yet, nothing at all,
// and something wrong. All three are the kit's, so every plugin's empty state looks like the
// app rather than like whoever wrote the manifest.

import SwiftUI

struct PluginEmptyStateView: View {
    let title: String
    let message: String
    let traits: HostTraits

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: traits.widthClass == .compact ? 18 : 22, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title.isEmpty ? "Nothing here" : title)
                .font(.system(size: 13, weight: .semibold))
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PluginKit.leafHeight("emptyState", traits: traits))
    }
}

struct PluginLoadingView: View {
    let message: String
    let traits: HostTraits

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if !message.isEmpty {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PluginKit.leafHeight("loading", traits: traits))
    }
}

struct PluginDiagnosticsView: View {
    let diagnostics: [PluginDiagnostic]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                HStack(spacing: 6) {
                    Image(systemName: diagnostic.severity == .error
                        ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.secondary)
                    Text(diagnostic.message)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                }
                .frame(height: PluginKit.diagnosticHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: PluginKit.cornerRadius, style: .continuous)
                .fill(Theme.surface(scheme == .dark)))
    }
}
