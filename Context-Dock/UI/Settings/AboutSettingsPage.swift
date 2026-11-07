import SwiftUI

struct AboutSettingsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black)
                            .frame(width: 72, height: 72)
                        Image("DoraXD")
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 72)
                            .blendMode(.screen)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("Context Dock")
                                .font(.system(size: 24, weight: .bold))
                            Text("BETA")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.15), in: Capsule())
                        }
                        Text(bundleVersion)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("com.krishgokul.ContextDock")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                CardSection(title: "Developer", systemImage: "person.fill") {
                    VStack(spacing: 0) {
                        SettingsPageRow(
                            icon: "person.crop.circle.fill",
                            iconColor: .blue,
                            title: "Gokula Kannan",
                            subtitle: "gokulparkerr@gmail.com"
                        ) { EmptyView() }
                    }
                }

                CardSection(title: "Legal", systemImage: "doc.text.fill") {
                    VStack(spacing: 0) {
                        SettingsPageRow(
                            icon: "c.circle.fill",
                            iconColor: .secondary,
                            title: "Copyright",
                            subtitle: "© 2025–2026 Gokula Kannan. All rights reserved."
                        ) { EmptyView() }
                        Divider()
                        SettingsPageRow(
                            icon: "checkmark.shield.fill",
                            iconColor: .green,
                            title: "Privacy",
                            subtitle: "On-device providers keep everything local. Cloud providers receive only the prompt and context you approve for that request — never a continuous screen feed."
                        ) { EmptyView() }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var bundleVersion: String { AppVersionInfo.full }
}
