import SwiftUI

struct AppleNotesMCPSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                enableCard
                if settings.noteMCPEnabled {
                    readPermissionsCard
                    scopeCard
                    aiPrivacyCard
                    advancedCard
                    labelsCard
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Cards

    private var enableCard: some View {
        CardSection(title: "Apple Notes MCP", systemImage: "note.text") {
            SettingsPageRow(
                icon: "note.text",
                iconColor: .yellow,
                title: "Enable Apple Notes MCP",
                subtitle: "Disabled by default. Allows AI tools to search and interact with Apple Notes in Context Dock."
            ) {
                Toggle("", isOn: $settings.noteMCPEnabled)
                    .labelsHidden()
                    .onChange(of: settings.noteMCPEnabled) { enabled in
                        if enabled {
                            Task { @MainActor in
                                AppleNotesMCPCapabilities.register(in: CapabilityRegistry.shared)
                            }
                        }
                    }
            }
        }
    }

    private var readPermissionsCard: some View {
        CardSection(title: "Read Permissions", systemImage: "eye.fill") {
            VStack(spacing: 0) {
                SettingsPageRow(
                    icon: "magnifyingglass",
                    iconColor: .blue,
                    title: "Allow Metadata Search",
                    subtitle: "AI can search note titles, folders, and short snippets. Full content is never read during search."
                ) {
                    Toggle("", isOn: $settings.noteMCPAllowMetadataSearch)
                        .labelsHidden()
                }
                Divider()
                SettingsPageRow(
                    icon: "doc.text.fill",
                    iconColor: .teal,
                    title: "Persistent Full-Note Reads",
                    subtitle: "Skip per-call approval when reading full note content. Off by default — each read requires approval."
                ) {
                    Toggle("", isOn: $settings.noteMCPAllowPersistentFullRead)
                        .labelsHidden()
                }
            }
        }
    }

    private var scopeCard: some View {
        CardSection(title: "Scope", systemImage: "globe") {
            SettingsPageRow(
                icon: "globe",
                iconColor: .indigo,
                title: "Allow Global Access",
                subtitle: "Show Notes tools in all surfaces. By default, tools only appear when Apple Notes is the frontmost app."
            ) {
                Toggle("", isOn: $settings.noteMCPAllowGlobalAccess)
                    .labelsHidden()
            }
        }
    }

    private var aiPrivacyCard: some View {
        CardSection(title: "AI & Privacy", systemImage: "lock.shield.fill") {
            VStack(spacing: 0) {
                SettingsPageRow(
                    icon: "cpu",
                    iconColor: .purple,
                    title: "Prefer Local AI for Notes",
                    subtitle: "Use on-device AI when summarizing or processing note content instead of cloud providers."
                ) {
                    Toggle("", isOn: $settings.noteMCPPreferLocalAI)
                        .labelsHidden()
                }
                Divider()
                SettingsPageRow(
                    icon: "icloud.slash.fill",
                    iconColor: .pink,
                    title: "Require Approval Before Cloud Send",
                    subtitle: "Ask for confirmation before sending any note content to a cloud AI provider."
                ) {
                    Toggle("", isOn: $settings.noteMCPRequireCloudApproval)
                        .labelsHidden()
                }
            }
        }
    }

    private var advancedCard: some View {
        CardSection(title: "Advanced", systemImage: "slider.horizontal.3") {
            VStack(spacing: 0) {
                SettingsPageRow(
                    icon: "arrow.up.doc.fill",
                    iconColor: .orange,
                    title: "Allow Bulk Export",
                    subtitle: "Enable exporting multiple notes at once. Disabled by default to prevent accidental mass export."
                ) {
                    Toggle("", isOn: $settings.noteMCPAllowBulkExport)
                        .labelsHidden()
                }
                Divider()
                SettingsPageRow(
                    icon: "trash.fill",
                    iconColor: .red,
                    title: "Allow Delete Tools",
                    subtitle: "Enable the notes.delete tool. Deleted notes cannot be recovered. Requires approval on every call."
                ) {
                    Toggle("", isOn: $settings.noteMCPAllowDelete)
                        .labelsHidden()
                }
            }
        }
    }

    private var labelsCard: some View {
        CardSection(title: "Active Policy Labels", systemImage: "tag.fill") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(activeLabels, id: \.label) { entry in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(entry.color)
                            .frame(width: 7, height: 7)
                        Text(entry.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Policy label logic

    private struct LabelEntry { let label: String; let color: Color }

    private var activeLabels: [LabelEntry] {
        var items: [LabelEntry] = [
            LabelEntry(label: "Apple Notes MCP", color: .blue),
            LabelEntry(label: "Private data", color: .yellow),
        ]
        if !settings.noteMCPEnabled {
            items.append(LabelEntry(label: "Disabled by default", color: .orange))
        }
        if settings.noteMCPAllowMetadataSearch {
            items.append(LabelEntry(label: "Metadata search: on", color: .blue))
        }
        if !settings.noteMCPAllowPersistentFullRead {
            items.append(LabelEntry(label: "Full reads require approval", color: .yellow))
        }
        if !settings.noteMCPAllowGlobalAccess {
            items.append(LabelEntry(label: "Global access disabled", color: .orange))
        }
        if settings.noteMCPRequireCloudApproval {
            items.append(LabelEntry(label: "Cloud AI requires approval", color: .yellow))
        }
        if !settings.noteMCPAllowBulkExport {
            items.append(LabelEntry(label: "Bulk export disabled", color: .orange))
        }
        if !settings.noteMCPAllowDelete {
            items.append(LabelEntry(label: "Delete blocked by default", color: .red))
        }
        return items
    }
}
