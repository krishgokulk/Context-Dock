import SwiftUI

/// Confirmation preview for an App Adapter Pack before install — icon, name,
/// action count, categories, version, author. Native macOS sheet.
struct AdapterPackImportPreviewSheet: View {
    let preview: AdapterPackPreview
    let onCancel: () -> Void
    let onImport: () -> Void

    private var manifest: AdapterPackManifest { preview.manifest }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 14) {
                Image(systemName: manifest.icon ?? "app.dashed")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(manifest.name)
                        .font(.system(size: 17, weight: .semibold))
                    Text(manifest.bundleId)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(preview.actionCount) action\(preview.actionCount == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tint)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Metadata
            VStack(alignment: .leading, spacing: 10) {
                if let v = manifest.version, !v.isEmpty {
                    metaRow("Version", v)
                }
                if let a = manifest.author, !a.isEmpty {
                    metaRow("Author", a)
                }
                if let d = manifest.description, !d.isEmpty {
                    metaRow("About", d)
                }
                if !preview.categories.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CATEGORIES")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        FlowChips(preview.categories)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Spacer(minLength: 0)
            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: onImport)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 420, height: 360)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Simple wrapping chip row for category tags.
private struct FlowChips: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 60), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}
