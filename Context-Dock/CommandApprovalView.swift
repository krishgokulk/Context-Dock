import SwiftUI
import Combine

// MARK: - Command Approval View

/// Shows a dialog for user to approve, edit, or deny AI-suggested terminal commands
struct CommandApprovalView: View {
    let command: String
    let classification: TerminalCommandClassifier.CommandClassification
    let purpose: String
    let onApprove: (String) -> Void
    let onDeny: () -> Void

    @State private var editedCommand: String
    @State private var isEditing = false
    @State private var rememberChoice = false
    @Environment(\.dismiss) private var dismiss

    init(
        command: String,
        classification: TerminalCommandClassifier.CommandClassification,
        purpose: String,
        onApprove: @escaping (String) -> Void,
        onDeny: @escaping () -> Void
    ) {
        self.command = command
        self.classification = classification
        self.purpose = purpose
        self.onApprove = onApprove
        self.onDeny = onDeny
        self._editedCommand = State(initialValue: command)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()
                .padding(.horizontal)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Purpose section
                    purposeSection

                    // Command section
                    commandSection

                    // Risk info
                    riskSection

                    // Blocked warning
                    if classification.riskLevel == .critical {
                        blockedWarning
                    }

                    // Remember choice
                    if classification.canExecute {
                        rememberSection
                    }
                }
                .padding()
            }

            Divider()

            // Actions
            actionButtons
        }
        .frame(width: 520, height: classification.riskLevel == .critical ? 460 : 410)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // AI Icon
            Image(systemName: "brain")
                .font(.system(size: 24))
                .foregroundStyle(.purple)
                .frame(width: 40, height: 40)
                .background(Color.purple.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(classification.riskLevel == .critical ? "Command Blocked" : "Command Approval Required")
                    .font(.headline)

                Text("AI wants to run a terminal command")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Risk badge
            riskBadge
        }
        .padding()
    }

    private var riskBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: riskIcon)
                .font(.system(size: 12, weight: .semibold))

            Text(classification.riskLevel.displayName)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(riskColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(riskColor.opacity(0.15))
        .clipShape(Capsule())
    }

    private var riskIcon: String {
        switch classification.riskLevel {
        case .safe, .low:
            return "checkmark.shield.fill"
        case .medium:
            return "exclamationmark.shield.fill"
        case .high:
            return "exclamationmark.triangle.fill"
        case .critical:
            return "xmark.shield.fill"
        }
    }

    private var riskColor: Color {
        switch classification.riskLevel {
        case .safe, .low:
            return .green
        case .medium:
            return .yellow
        case .high:
            return .orange
        case .critical:
            return .red
        }
    }

    // MARK: - Purpose Section

    private var purposeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Purpose", systemImage: "lightbulb.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(purpose)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Command Section

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Command", systemImage: "terminal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if classification.canExecute && !isEditing {
                    Button(action: { isEditing = true }) {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }

            if isEditing {
                TextEditor(text: $editedCommand)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 60)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.blue.opacity(0.5), lineWidth: 1)
                    )
            } else {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(classification.riskLevel == .critical ? .red : .primary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Category tag
            HStack {
                Image(systemName: categoryIcon)
                    .font(.caption)
                Text(classification.category.rawValue)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var categoryIcon: String {
        switch classification.category {
        case .fileOperation: return "folder.fill"
        case .packageManagement: return "shippingbox.fill"
        case .gitOperation: return "arrow.triangle.branch"
        case .systemInfo: return "info.circle.fill"
        case .networkOperation: return "network"
        case .processManagement: return "gearshape.2.fill"
        case .buildCommand: return "hammer.fill"
        case .shellOperation: return "terminal.fill"
        case .applicationControl: return "app.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    // MARK: - Risk Section

    private var riskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Impact", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(classification.explanation)
                .font(.callout)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(riskColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Blocked Warning

    private var blockedWarning: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(.red)

                Text("This command is blocked for safety")
                    .font(.headline)
                    .foregroundStyle(.red)
            }

            if let reason = classification.blockedReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let alternative = classification.suggestedAlternative {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alternative:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(alternative)
                        .font(.callout)
                        .foregroundStyle(.blue)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Remember Section

    private var rememberSection: some View {
        Toggle(isOn: $rememberChoice) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("Remember this choice for similar commands")
                    .font(.callout)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Deny button
            Button(action: {
                onDeny()
                dismiss()
            }) {
                Text("Deny")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape)

            if classification.canExecute {
                // Approve button
                Button(action: {
                    let commandToRun = isEditing ? editedCommand : command
                    if rememberChoice {
                        // Save preference
                        TerminalCommandPreferences.shared.addAutoApprove(commandToRun)
                    }
                    onApprove(commandToRun)
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text(isEditing ? "Run Edited Command" : "Approve & Run")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.return)
            }
        }
        .padding()
    }
}

// MARK: - Preview

#Preview {
    CommandApprovalView(
        command: "brew install ffmpeg",
        classification: TerminalCommandClassifier.shared.classify("brew install ffmpeg"),
        purpose: "Install ffmpeg for video processing capabilities",
        onApprove: { _ in },
        onDeny: { }
    )
}
