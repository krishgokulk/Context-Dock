// RemChatBubble.swift
// Context-Dock
//
// One message in the app panel's chat, as a type of its own.
//
// Extracted for #25. `LauncherView.body` lowers into a single opaque type holding the whole
// launcher UI, and SILGen cannot finish substituting it. A computed property or a method
// returning `some View` is not a boundary — only a nominal type is — so the way out is to
// turn view members into `struct`s, starting with the ones that call no other view member.
// This was the largest of those: 187 lines, reaching nothing but itself.
//
// What it needed turned out to be small. The message, the terminal bridge it watches to tell
// whether an approval card is still live, and four closures. `searchState` looked like a
// fifth input until the brew-retry block moved behind `onBrewToolInstalled`, which is where
// that logic belonged anyway: this view should say a tool was installed, not decide what to
// re-run.
import SwiftUI

struct RemChatBubble: View {
    let message: AIChatMessage

    /// Watched, not just read. A global bridge can only wait for one command, so the card
    /// compares against the pending command and dims itself once that is no longer this one.
    @ObservedObject var terminalBridge: TerminalAIBridge

    /// "brew install X" mentioned in an assistant message.
    let brewInstalls: (String) -> [String]

    /// A short numbered question becomes buttons instead of a request to type a list number.
    let choiceOptions: (String) -> [String]

    /// A tool finished installing; the caller decides what to re-run.
    let onBrewToolInstalled: () -> Void

    let submitChoice: (String) -> Void

    var body: some View {
        switch message.role {
        case .tool:
            // Terminal command chip — shown inline while command runs
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green.opacity(0.8))
                Text(message.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.9))
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5)
            )
            .frame(maxWidth: .infinity, alignment: .leading)

        case .approval:
            // Inline approval card — like Claude Code's "run this command?" prompt
            let parts = (message.structuredData ?? "").components(separatedBy: "|||/")
            let purpose = parts.first ?? ""
            let risk = parts.count > 1 ? parts[1] : "Unknown"
            let isHighRisk =
                risk.lowercased().contains("high") || risk.lowercased().contains("critical")
            // A global terminal bridge can only wait for one command. Match the
            // command itself so an old card cannot approve a later command.
            let isPending = terminalBridge.pendingApproval?.command == message.content

            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHighRisk ? Color.orange : Color.accentColor)
                    Text("Run command?")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if isHighRisk {
                        Text(risk)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                // Purpose
                if !purpose.isEmpty {
                    Text(purpose)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // Command
                Text(message.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Buttons
                HStack(spacing: 8) {
                    Button("Deny") {
                        TerminalAIBridge.shared.denyCommand()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(!isPending)

                    Button {
                        TerminalAIBridge.shared.approveCommand(message.content)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 9))
                            Text("Approve & Run")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(
                        isHighRisk ? Color.orange : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .disabled(!isPending)
                }
            }
            .padding(10)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHighRisk ? Color.orange.opacity(0.35) : Color.accentColor.opacity(0.25),
                        lineWidth: 0.75)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isPending ? 1 : 0.5)

        case .user:
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 24)
                Text(message.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .frame(maxWidth: 180, alignment: .trailing)
            }
        case .assistant:
            let brewTools = brewInstalls(message.content)
            let choices = choiceOptions(message.content)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 0) {
                    Text(message.content)
                        .font(.system(size: 12))
                        .foregroundStyle(message.isError ? .red : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            message.isError
                                ? AnyShapeStyle(Color.red.opacity(0.1))
                                : AnyShapeStyle(Color.primary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .frame(maxWidth: 180, alignment: .leading)
                    Spacer(minLength: 24)
                }
                // Inline install buttons — appear whenever AI says "brew install X"
                if !brewTools.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(brewTools, id: \.self) { tool in
                            BrewInstallButton(toolName: tool, onInstalled: onBrewToolInstalled)
                        }
                    }
                    .padding(.leading, 4)
                }
                // A clarification should be an interaction, not a request for the
                // user to type an arbitrary list number. Keep this deliberately
                // narrow: only short, explicit numbered questions become actions.
                if !choices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(choices, id: \.self) { choice in
                            Button {
                                submitChoice(choice)
                            } label: {
                                Text(choice)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.32)))
                            }
                            .buttonStyle(.plain)
                            .help("Choose \(choice)")
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }
}
