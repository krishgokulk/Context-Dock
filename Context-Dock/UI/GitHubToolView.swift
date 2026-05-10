import SwiftUI

// MARK: - GitHub Tool Analysis View

/// Displays GitHub tool analysis with installation options
struct GitHubToolAnalysisView: View {
    let analysis: GitHubAnalysis
    @ObservedObject private var manager = GitHubToolManager.shared
    @State private var isInstalling = false
    @State private var installResult: GitHubToolManager.InstallResult?
    @State private var selectedMethod: GitHubTool.InstallMethod
    @State private var customCommand: String
    @State private var showCustomCommand = false

    init(analysis: GitHubAnalysis) {
        self.analysis = analysis
        _selectedMethod = State(initialValue: analysis.suggestedInstallMethod)
        _customCommand = State(initialValue: analysis.installCommand)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                headerSection

                Divider()

                // Tool Info
                toolInfoSection

                Divider()

                // Capabilities
                capabilitiesSection

                Divider()

                // Installation
                installationSection

                Divider()

                // Risk Assessment
                riskSection

                // Result
                if let result = installResult {
                    resultSection(result)
                }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon based on language
            languageIcon
                .font(.system(size: 40))
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(analysis.tool.name)
                    .font(.title)
                    .fontWeight(.bold)

                Text(analysis.tool.fullName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Label("\(analysis.tool.stars)", systemImage: "star.fill")
                        .foregroundColor(.yellow)

                    if let lang = analysis.tool.language {
                        Label(lang, systemImage: "chevron.left.forwardslash.chevron.right")
                            .foregroundColor(.blue)
                    }

                    if analysis.tool.isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
                .font(.caption)
            }

            Spacer()

            Button(action: openInBrowser) {
                Image(systemName: "safari")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .help("Open in Browser")
        }
    }

    private var languageIcon: some View {
        Group {
            switch analysis.tool.language?.lowercased() {
            case "rust":
                Image(systemName: "gearshape.2.fill")
                    .foregroundColor(.orange)
            case "go":
                Image(systemName: "hare.fill")
                    .foregroundColor(.cyan)
            case "python":
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundColor(.yellow)
            case "javascript", "typescript":
                Image(systemName: "j.square.fill")
                    .foregroundColor(.yellow)
            case "swift":
                Image(systemName: "swift")
                    .foregroundColor(.orange)
            case "shell", "bash":
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
            default:
                Image(systemName: "shippingbox.fill")
                    .foregroundColor(.gray)
            }
        }
    }

    private var toolInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)

            Text(analysis.tool.description)
                .foregroundColor(.secondary)

            if !analysis.tool.topics.isEmpty {
                GitHubToolFlowLayout(spacing: 6) {
                    ForEach(analysis.tool.topics.prefix(10), id: \.self) { topic in
                        Text(topic)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
            }

            if let release = analysis.tool.latestRelease {
                HStack {
                    Image(systemName: "tag.fill")
                        .foregroundColor(.green)
                    Text("Latest: \(release.tagName)")
                        .font(.caption)
                    if let date = release.publishedAt {
                        Text("(\(date.formatted(date: .abbreviated, time: .omitted)))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capabilities")
                .font(.headline)

            if analysis.tool.capabilities.isEmpty {
                Text("No specific capabilities detected")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                GitHubToolFlowLayout(spacing: 6) {
                    ForEach(analysis.tool.capabilities, id: \.self) { capability in
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text(capability)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
        }
    }

    private var installationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installation")
                .font(.headline)

            // Method selector
            HStack {
                Text("Method:")
                    .foregroundColor(.secondary)

                Picker("", selection: $selectedMethod) {
                    ForEach(analysis.tool.installMethods, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedMethod) { _, newMethod in
                    customCommand = manager.generateInstallCommand(tool: analysis.tool, method: newMethod)
                }
            }

            // Command preview
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Command:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { showCustomCommand.toggle() }) {
                        Text(showCustomCommand ? "Use Default" : "Customize")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }

                if showCustomCommand {
                    TextField("Command", text: $customCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text(customCommand)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                }
            }

            // Install button
            HStack {
                if analysis.tool.isInstalled {
                    Label("Already Installed", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Button(action: installTool) {
                        if isInstalling {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                            Text("Installing...")
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Install \(analysis.tool.name)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                }

                Spacer()

                Button(action: copyCommand) {
                    Label("Copy Command", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var riskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Risk Assessment")
                    .font(.headline)

                Spacer()

                riskBadge
            }

            ForEach(analysis.riskAssessment.reasons, id: \.self) { reason in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text(reason)
                        .font(.caption)
                }
            }

            if !analysis.riskAssessment.recommendations.isEmpty {
                Text("Recommendations:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.top, 4)

                ForEach(analysis.riskAssessment.recommendations, id: \.self) { rec in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text(rec)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var riskBadge: some View {
        let color: Color = {
            switch analysis.riskAssessment.level {
            case .low: return .green
            case .medium: return .yellow
            case .high: return .orange
            case .unknown: return .gray
            }
        }()

        return Text(analysis.riskAssessment.level.rawValue)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(8)
    }

    private func resultSection(_ result: GitHubToolManager.InstallResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            if result.success {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Successfully installed \(result.tool.name)!")
                        .fontWeight(.medium)
                }

                if let path = result.tool.installedPath {
                    Text("Installed at: \(path)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("The tool is now available for L2 to use in tasks.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("Installation failed")
                        .fontWeight(.medium)
                }

                if let error = result.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if !result.output.isEmpty {
                    Text("Output:")
                        .font(.caption)
                        .fontWeight(.medium)

                    ScrollView {
                        Text(result.output)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .frame(maxHeight: 100)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                }
            }
        }
    }

    // MARK: - Actions

    private func installTool() {
        isInstalling = true
        installResult = nil

        Task {
            let result = await manager.installTool(
                analysis.tool,
                method: selectedMethod,
                customCommand: showCustomCommand ? customCommand : nil
            )
            await MainActor.run {
                installResult = result
                isInstalling = false
            }
        }
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(customCommand, forType: .string)
    }

    private func openInBrowser() {
        NSWorkspace.shared.open(analysis.tool.repositoryURL)
    }
}

// MARK: - Compact GitHub Tool Card

/// Compact card view for showing GitHub tool in L2 responses
struct GitHubToolCard: View {
    let tool: GitHubTool
    let onInstall: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(tool.name)
                        .font(.headline)
                    Text(tool.fullName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                    Text("\(tool.stars)")
                }
                .font(.caption)
            }

            Text(tool.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack {
                if tool.isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Button(action: onInstall) {
                        Label("Install", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Spacer()

                Button(action: onOpen) {
                    Image(systemName: "safari")
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Flow Layout Helper

private struct GitHubToolFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in width: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > width, x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: width, height: y + lineHeight)
        }
    }
}

// MARK: - GitHub URL Detector View

/// Inline view that appears when a GitHub URL is detected in input
struct GitHubURLDetectedBanner: View {
    let url: URL
    let onAnalyze: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("GitHub repository detected")
                    .font(.caption)
                    .fontWeight(.medium)
                Text(url.absoluteString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Analyze & Install", action: onAnalyze)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(isHovering ? 0.15 : 0.1))
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Preview

#Preview("GitHub Tool Analysis") {
    let sampleTool = GitHubTool(
        id: UUID(),
        name: "scmd",
        fullName: "sunboylabs/scmd",
        description: "A fast and simple command-line tool for searching and executing commands",
        repositoryURL: URL(string: "https://github.com/sunboylabs/scmd")!,
        homepage: nil,
        language: "Rust",
        topics: ["cli", "search", "productivity", "rust"],
        stars: 256,
        latestRelease: GitHubRelease(
            tagName: "v1.2.0",
            name: "Version 1.2.0",
            publishedAt: Date(),
            assets: [],
            body: "Bug fixes and improvements"
        ),
        installMethods: [.homebrew, .cargo],
        capabilities: ["search", "execute", "filter"],
        detectedAt: Date(),
        isInstalled: false,
        installedVersion: nil,
        installedPath: nil
    )

    let analysis = GitHubAnalysis(
        tool: sampleTool,
        readme: nil,
        suggestedInstallMethod: .homebrew,
        installCommand: "brew install scmd",
        riskAssessment: GitHubAnalysis.RiskAssessment(
            level: .low,
            reasons: ["Popular repository with 256 stars", "Installing via Homebrew (trusted)"],
            recommendations: []
        )
    )

    return GitHubToolAnalysisView(analysis: analysis)
        .frame(width: 550, height: 600)
}
