// CompareCaptionPill.swift
// Context-Dock
//
// The caption under a compare value, when the row offers a choice behind it.
//
// The first attempt rewrote the dock query to a drill token, which leaked the
// extension's private vocabulary into the input ("1 from?"). This instead runs the
// extension out-of-band with that token and renders whatever rows come back as a
// scrollable dropdown, so the input never changes and the token stays internal.

import Combine
import SwiftUI

/// Shared so chrome that must yield to an open dropdown — the running-app capsule —
/// can see it without the pill reaching up through the view tree.
@MainActor
final class ComparePickerState: ObservableObject {
    static let shared = ComparePickerState()
    @Published var isOpen = false
    private init() {}
}

struct CompareCaptionPill: View {
    let caption: String
    let drillQuery: String
    let commandID: UUID
    /// Called after a choice is made so the scope can re-run and show the new result.
    let onPicked: () -> Void

    @State private var isPresented = false
    @State private var rows: [CustomListRow] = []
    @State private var isLoading = false
    @State private var filter = ""

    private var command: SystemCommand? {
        SystemCommandsRegistry.shared.commands.first { $0.id == commandID }
    }

    private var visibleRows: [CustomListRow] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.title.lowercased().contains(q)
                || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 3) {
                Text(caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            dropdown
        }
        .onChange(of: isPresented) { _, open in
            ComparePickerState.shared.isOpen = open
            if open { load() } else { filter = "" }
        }
    }

    private var dropdown: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Search", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider().opacity(0.4)

            if isLoading && rows.isEmpty {
                ProgressView().controlSize(.small).padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleRows) { row in
                            Button {
                                choose(row)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: row.icon ?? "circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(
                                            row.badge == "current" ? Color.accentColor : .secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.title)
                                            .font(.system(size: 12, weight: .medium))
                                        if let sub = row.subtitle, !sub.isEmpty {
                                            Text(sub)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 280, height: 340)
    }

    private func load() {
        guard let command, !isLoading else { return }
        isLoading = true
        Task {
            let output = await CustomListProviderService.testRun(
                script: command.script,
                interpreter: command.actionType,
                query: drillQuery)
            await MainActor.run {
                rows = CustomListProviderService.testParse(output)
                isLoading = false
            }
        }
    }

    private func choose(_ row: CustomListRow) {
        guard let command else { return }
        CustomListProviderService.shared.runAction(command, row: row, query: drillQuery)
        isPresented = false
        // The action mutates state the rows script reads, so the card behind the
        // dropdown is stale until the scope re-runs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onPicked() }
    }
}
