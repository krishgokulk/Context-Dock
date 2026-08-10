// ProjectBuildCapabilities.swift
// Context-Dock
//
// Building and launching the project the user is currently working in.
//
// This is the step the loop kept breaking on. "Fix this and test it" needs a build, and a
// build is the one capability that cannot be discovered from a menu or an MCP server — it
// lives in the shape of the repository.
//
// The detection order below has one rule doing most of the work: **the project's own script
// wins.** A repo that ships `scripts/dev-run.sh` ships it because the raw toolchain
// invocation is wrong for that repo — different DerivedData, a codegen step first, a
// specific configuration. Context-Dock is itself an example: running `xcodebuild` directly
// writes to Xcode's hashed DerivedData while the script builds into `.build/`, and
// launching the wrong one has shipped a stale app here before. A build capability that
// reached for `xcodebuild` because it saw an `.xcodeproj` would reproduce that bug on
// every project that has a reason for its script.
//
// So: script first, then a Makefile target, then the toolchain default. Only when nothing
// is found does this decline — it never guesses a command and runs it.

import Foundation

@MainActor
enum ProjectBuildCapabilities {

    static func register(in registry: CapabilityRegistry) {
        registry.register(
            AICapability(
                id: "project.build",
                title: "Build the Current Project",
                appBundleID: nil,
                inputSchema: .init(fields: [
                    .init(
                        name: "path",
                        description: "Project directory; defaults to the frontmost editor's project",
                        required: false
                    )
                ]),
                // Runs a build command from the user's own repository. Inspectable before it
                // runs, but it is arbitrary code from disk, so it is never unattended.
                riskLevel: .high
            ) { request in
                guard let root = projectRoot(from: request) else {
                    return .init(
                        success: false,
                        output: "I couldn't tell which project to build. Open it in your editor, or say which folder.")
                }
                guard let recipe = buildCommand(at: root) else {
                    return .init(
                        success: false,
                        output: "I couldn't find a way to build \((root as NSString).lastPathComponent). No build script, Makefile target, or recognised project file is there.")
                }
                let result = await TerminalCommandExecutor.shared.run(
                    "cd \(shellQuote(root)) && \(recipe.command)",
                    purpose: "Build \((root as NSString).lastPathComponent) using \(recipe.source)"
                )
                guard result.success else {
                    // The failure text is the payload, not a footnote: it is what gets handed
                    // back to whichever agent is fixing the code.
                    let detail = tail(result.output)
                    WorkbenchEvidence.shared.recordBuildFailure(
                        projectRoot: root, source: recipe.source, output: detail)
                    return .init(
                        success: false,
                        output: "Build failed (\(recipe.source)).\n\n\(detail)")
                }
                WorkbenchEvidence.shared.recordBuildSuccess(projectRoot: root)
                return .init(
                    success: true, output: "Build succeeded (\(recipe.source)).")
            }
        )
    }

    // MARK: - How this project builds

    struct BuildRecipe {
        let command: String
        /// How it was found, in the user's terms — shown in the approval prompt so they can
        /// see *why* this command and not another.
        let source: String
    }

    /// The first way of building that this repository actually offers.
    ///
    /// Order is deliberate and is the whole point of this type. A project's own script
    /// encodes decisions the toolchain default does not know about, so it is checked before
    /// anything is inferred from a project file.
    static func buildCommand(at root: String) -> BuildRecipe? {
        let fm = FileManager.default
        func exists(_ relative: String) -> Bool {
            fm.fileExists(atPath: (root as NSString).appendingPathComponent(relative))
        }
        func isExecutable(_ relative: String) -> Bool {
            fm.isExecutableFile(atPath: (root as NSString).appendingPathComponent(relative))
        }

        // 1. The repository's own entry point. Named in the order a human would try them.
        for script in [
            "scripts/dev-run.sh", "scripts/build-debug.sh", "scripts/build.sh",
            "build.sh", "bin/build",
        ] where isExecutable(script) {
            return BuildRecipe(command: "./\(script)", source: "the project's \(script)")
        }

        // 2. A Makefile that actually declares a build target. `make` with no target runs
        //    whatever happens to be first, which is not a build on plenty of repositories.
        if exists("Makefile"),
            let makefile = try? String(
                contentsOfFile: (root as NSString).appendingPathComponent("Makefile"),
                encoding: .utf8),
            makefile.split(separator: "\n").contains(where: { $0.hasPrefix("build:") })
        {
            return BuildRecipe(command: "make build", source: "the Makefile's build target")
        }

        // 3. Toolchain defaults, only once nothing above spoke for the project.
        if let workspace = firstEntry(in: root, suffix: ".xcworkspace") {
            return BuildRecipe(
                command: "xcodebuild -workspace \(shellQuote(workspace)) -scheme "
                    + shellQuote((workspace as NSString).deletingPathExtension) + " build",
                source: "xcodebuild")
        }
        if let project = firstEntry(in: root, suffix: ".xcodeproj") {
            return BuildRecipe(
                command: "xcodebuild -project \(shellQuote(project)) -scheme "
                    + shellQuote((project as NSString).deletingPathExtension) + " build",
                source: "xcodebuild")
        }
        if exists("Package.swift") {
            return BuildRecipe(command: "swift build", source: "Swift Package Manager")
        }
        if exists("Cargo.toml") {
            return BuildRecipe(command: "cargo build", source: "Cargo")
        }
        if exists("package.json"),
            let manifest = try? String(
                contentsOfFile: (root as NSString).appendingPathComponent("package.json"),
                encoding: .utf8),
            manifest.contains("\"build\"")
        {
            return BuildRecipe(command: "npm run build", source: "the package.json build script")
        }
        return nil
    }

    // MARK: - Helpers

    private static func firstEntry(in root: String, suffix: String) -> String? {
        (try? FileManager.default.contentsOfDirectory(atPath: root))?
            .filter { $0.hasSuffix(suffix) }
            .sorted()
            .first
    }

    private static func projectRoot(from request: AICapabilityExecutionRequest) -> String? {
        if let path = request.input["path"], !path.isEmpty { return path }
        if case .filesSelected(let urls) = request.context, let first = urls.first {
            let base =
                first.hasDirectoryPath ? first.path : first.deletingLastPathComponent().path
            return ProjectContextResolver.repositoryRoot(containing: base) ?? base
        }
        return ProjectContextResolver.shared.frontmostProjectRoot()
    }

    /// Build logs are long and the useful part is at the end. Keeping the tail rather than
    /// the head is what makes this output usable as input to a coding agent.
    private static func tail(_ output: String, lines: Int = 60) -> String {
        let all = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines else { return output }
        return "…\n" + all.suffix(lines).joined(separator: "\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
