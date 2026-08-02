// ListExtensionTester.swift
// Context-Dock
//
// Runs a list extension's rows script at authoring time and shows what the dock
// would render.
//
// Without this, a malformed NDJSON line is invisible until the panel opens empty
// and the author has nothing to debug against — which is exactly how a currency
// converter that filtered instead of computed shipped looking broken.

import SwiftUI

struct ListExtensionTester: View {
    let script: String
    let scriptType: String

    @State private var query = ""
    @State private var rows: [CustomListRow] = []
    @State private var rawOutput = ""
    @State private var isRunning = false
    @State private var hasRun = false

    private var readsQuery: Bool {
        CustomListProviderService.scriptReadsQuery(script)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    run()
                } label: {
                    Label(isRunning ? "Running…" : "Test rows",
                          systemImage: "play.circle")
                }
                .controlSize(.small)
                .disabled(isRunning || script.trimmingCharacters(in: .whitespaces).isEmpty)

                if readsQuery {
                    TextField("$CD_QUERY", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .onSubmit { run() }
                }
                Spacer()
            }

            // Reading the query is what makes a panel computed rather than browsed,
            // so say which one the author has actually written.
            Text(readsQuery
                 ? "Computed panel — re-runs as the user types. Rows are never filtered."
                 : "Browse panel — rows are filtered by what the user types.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if hasRun {
                if rows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No rows parsed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(rawOutput.isEmpty
                             ? "The script printed nothing."
                             : "Script output wasn't one JSON object per line:")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if !rawOutput.isEmpty {
                            Text(rawOutput.prefix(400))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.orange.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows.prefix(8)) { row in
                            HStack(spacing: 8) {
                                Image(systemName: symbolName(row.icon) ?? "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tint)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title).font(.system(size: 11, weight: .medium))
                                    if let sub = row.subtitle, !sub.isEmpty {
                                        Text(sub).font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let badge = row.badge, !badge.isEmpty {
                                    Text(badge).font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                        }
                        if rows.count > 8 {
                            Text("+ \(rows.count - 8) more")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 4)
                        }
                    }
                    .background(Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func symbolName(_ icon: String?) -> String? {
        guard let icon, !icon.isEmpty, !icon.contains("/") else { return "doc" }
        return icon
    }

    private func run() {
        isRunning = true
        let script = self.script
        let type = SystemCommandActionType.normalize(scriptType)
        let query = self.query

        Task {
            let output = await CustomListProviderService.testRun(
                script: script, interpreter: type, query: query)
            await MainActor.run {
                rawOutput = output
                rows = CustomListProviderService.testParse(output)
                isRunning = false
                hasRun = true
            }
        }
    }
}
