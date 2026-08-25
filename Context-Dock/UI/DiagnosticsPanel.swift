// DiagnosticsPanel.swift
// Context-Dock
//
// The last failure, in a form that can be acted on.
//
// Two buttons, because there are exactly two useful destinations for a fault report and
// they are not the same thing. Copy is for a human — an issue, a message, a note to
// self. Hand to Claude Code is for the only process on this Mac that can change the code
// that produced the fault: DoraX cannot rewrite and rebuild itself while it is the thing
// running, so the honest move is to package the evidence and pass it to something that can.

import AppKit
import SwiftUI

struct DiagnosticsPanel: View {
    @ObservedObject private var capture = DoraXDiagnosticCapture.shared

    @State private var copied = false
    @State private var handoff: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Diagnostics", systemImage: "stethoscope")
                    .font(.headline)
                Spacer()
                if !capture.recent.isEmpty {
                    Button("Clear") { capture.clear() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if let latest = capture.latest {
                report(latest)
            } else {
                Text("No failures recorded this session. When a request fails, its full "
                    + "state is captured here — provider, model, scope, what actually ran "
                    + "— so it can be diagnosed without reproducing it first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let handoff {
                Text(handoff)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func report(_ latest: DoraXDiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(latest.symptom)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let query = latest.query, !query.isEmpty {
                        Text("Query: \(query)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if capture.recent.count > 1 {
                        Text("\(capture.recent.count) failures captured this session")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button {
                    latest.copyToPasteboard()
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy report", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button {
                    handToClaudeCode(latest)
                } label: {
                    Label("Hand to Claude Code", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .disabled(!ClaudeCodeCLIService.isInstalled)
                .help(
                    ClaudeCodeCLIService.isInstalled
                        ? "Copies a repair prompt and opens the repository"
                        : "Needs Claude Code installed")
            }
        }
    }

    /// Deliberately not "run the fix". The prompt goes to the clipboard and the repo opens;
    /// the user starts the session and reads the diff. An app that rebuilds itself
    /// unattended can break itself with nobody watching and no diff to review — the speed
    /// gained is not worth the failure it invites.
    private func handToClaudeCode(_ report: DoraXDiagnosticReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.repairPrompt(), forType: .string)
        handoff = "Repair prompt copied. Open the DoraX repo in a terminal, run `claude`, "
            + "and paste it — that session has the tools to read the source and fix it."
    }
}
