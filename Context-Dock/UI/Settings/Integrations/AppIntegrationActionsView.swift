import SwiftUI

/// The two action groups an app integration can have, kept apart because they execute on
/// different surfaces: app actions drive the app itself, browser actions run in the page.
///
/// This view renders and reports; every mutation goes back out through a callback to the
/// managers that already own it.
struct AppIntegrationActionsView: View {
    let bundleID: String
    let appActions: [AdapterAction]
    let browserActions: [AdapterAction]
    let onAdd: () -> Void
    let onEdit: (AdapterAction) -> Void
    let onRemove: (AdapterAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if appActions.isEmpty && browserActions.isEmpty {
                    emptyState
                } else {
                    if !appActions.isEmpty {
                        section(
                            title: "App Actions",
                            caption: "Run against the app when it is frontmost.",
                            actions: appActions)
                    }
                    if !browserActions.isEmpty {
                        section(
                            title: "Browser Actions",
                            caption: "Run as JavaScript in the active page.",
                            actions: browserActions)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func section(
        title: String,
        caption: String,
        actions: [AdapterAction]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(title) · \(actions.count)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    if index > 0 { Divider() }
                    row(action)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    private func row(_ action: AdapterAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .font(.system(size: 13))
                .foregroundStyle(.teal)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.name)
                    .font(.system(size: 12, weight: .medium))
                Text(action.description.isEmpty ? action.type.displayName : action.description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(action.type.displayName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())

            Button {
                onEdit(action)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit action")
            .accessibilityLabel("Edit \(action.name)")

            Button(role: .destructive) {
                onRemove(action)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Remove action")
            .accessibilityLabel("Remove \(action.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No actions yet")
                .font(.system(size: 13, weight: .medium))
            Text("Add an action to give this integration something to run.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                onAdd()
            } label: {
                Label("Add Action", systemImage: "plus")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor)))
    }
}
