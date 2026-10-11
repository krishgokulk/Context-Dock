// LivePanelTerminalView.swift
// Context-Dock
//
// The live panel's terminal pane.
//
// Extracted for #25 as a reachable leaf. Both dependencies are controllers rather than
// launcher state: the host that owns the running terminal, and the worker pool it reports on.
import SwiftUI

struct LivePanelTerminalView: View {
    /// Written here, not only read: the pane creates the host the first time it draws and
    /// clears it when the terminal goes away.
    @Binding var terminalHost: TerminalHostController?
    @ObservedObject var workerPool: BackgroundWorkerPool

    var body: some View {
        VStack(spacing: 0) {
            // Terminal header
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Active workers indicator
                let active = workerPool.workers.values.filter { $0.status.isActive }
                if !active.isEmpty {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                            .opacity(0.8)
                        Text("\(active.count) running")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    terminalHost?.sendCommand("clear")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.4))

            // SwiftTerm embedded view
            if let host = terminalHost {
                TerminalNSViewRepresentable(terminalController: host)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Starting terminal…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    terminalHost = TerminalHostController()
                }
            }
        }
        .background(Color.black.opacity(0.55))
        .onAppear {
            if terminalHost == nil {
                terminalHost = TerminalHostController()
            }
        }
    }
}
