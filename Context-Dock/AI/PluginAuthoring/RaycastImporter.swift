// Context-Dock/AI/PluginAuthoring/RaycastImporter.swift
// Context-Dock
//
// Phase 2: Raycast Script Command & Store/Local Extension Importer
//
// 1. Deterministic Parser for Raycast Script Commands (`# @raycast.*` / `// @raycast.*`),
//    converting `mode` (`fullOutput`, `compact`, `silent`, `inline`) & `argument1..3`
//    into native `.doraxpack` v3 commands/forms wrapped for zero-Node execution.
// 2. Raycast Store / GitHub / Local Extension `package.json` Converter: reads extension
//    metadata (`title`, `commands`, `preferences`, `src/*.ts`) and synthesizes either a new
//    `.doraxpack` v3 bundle OR a merge `DoraxPackV3Patch` into an existing pack!

import Foundation

struct RaycastScriptArgument: Codable, Equatable {
    var type: String
    var placeholder: String
    var optional: Bool?
}

struct RaycastScriptMetadata: Equatable {
    var schemaVersion: String
    var title: String
    var mode: String
    var packageName: String?
    var icon: String?
    var description: String?
    var refreshTime: String?
    var needsConfirmation: Bool
    var arguments: [RaycastScriptArgument]
}

enum RaycastExtensionSource: Equatable {
    case localScript(URL)
    case localDirectory(URL)
    case raycastStore(author: String, slug: String)
    case githubRepo(owner: String, repo: String, subpath: String?)
    case queryOrSlug(String)
}

struct RaycastImportResult {
    let sourceKind: String
    let summary: String
    let targetPackID: String?
    let synthesis: DoraxPackV3SynthesisResult?
    let patch: DoraxPackV3Patch?

    var diagnostics: [PluginDiagnostic] {
        patch?.diagnostics ?? synthesis?.review.diagnostics ?? []
    }

    var dryRunOutput: DoraxCommandOutput? {
        patch?.dryRunOutput ?? synthesis?.review.dryRunOutput
    }

    var hasBlockingErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

enum RaycastImportError: Error, LocalizedError {
    case emptySource
    case unreadableFile(String)
    case missingScriptMetadata

    var errorDescription: String? {
        switch self {
        case .emptySource:
            return "Enter a Raycast Store URL, GitHub URL, or local script/extension path."
        case .unreadableFile(let path):
            return "Could not read file at \(path)."
        case .missingScriptMetadata:
            return "File does not contain @raycast.schemaVersion or @raycast.title headers."
        }
    }
}

@MainActor
enum RaycastImporter {

    // MARK: - 1. Script Command Header Parser

    static func parseScriptMetadata(content: String) -> RaycastScriptMetadata? {
        var values: [String: String] = [:]
        var argsByIndex: [Int: RaycastScriptArgument] = [:]

        for rawLine in content.components(separatedBy: .newlines).prefix(80) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let stripped: String
            if line.hasPrefix("#") {
                stripped = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("//") {
                stripped = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else {
                continue
            }
            guard stripped.hasPrefix("@raycast.") else { continue }
            let rest = String(stripped.dropFirst("@raycast.".count))
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let val = String(parts[1]).trimmingCharacters(in: .whitespaces)

            if key.hasPrefix("argument"), let idx = Int(key.dropFirst("argument".count)) {
                if let data = val.data(using: .utf8),
                   let arg = try? JSONDecoder().decode(RaycastScriptArgument.self, from: data)
                {
                    argsByIndex[idx] = arg
                }
            } else {
                values[key] = val
            }
        }

        guard let title = values["title"], !title.isEmpty else { return nil }
        let sortedArgs = argsByIndex.keys.sorted().compactMap { argsByIndex[$0] }
        return RaycastScriptMetadata(
            schemaVersion: values["schemaVersion"] ?? "1",
            title: title,
            mode: values["mode"] ?? "fullOutput",
            packageName: values["packageName"],
            icon: values["icon"],
            description: values["description"],
            refreshTime: values["refreshTime"],
            needsConfirmation: (values["needsConfirmation"] ?? "").lowercased() == "true",
            arguments: sortedArgs)
    }

    static func parseRefreshSeconds(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        let digits = s.prefix { $0.isNumber }
        guard let num = Int(digits), num > 0 else { return nil }
        let unit = s.dropFirst(digits.count)
        switch unit {
        case "s", "": return max(5, num)
        case "m": return num * 60
        case "h": return num * 3_600
        case "d": return num * 86_400
        default: return nil
        }
    }

    static func parseExtensionSource(_ raw: String) -> RaycastExtensionSource {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir) {
            return isDir.boolValue
                ? .localDirectory(URL(fileURLWithPath: expanded, isDirectory: true))
                : .localScript(URL(fileURLWithPath: expanded))
        }

        if let url = URL(string: trimmed), let host = url.host?.lowercased() {
            let parts = url.pathComponents.filter { $0 != "/" }
            if host.contains("raycast.com"), parts.count >= 2 {
                return .raycastStore(author: parts[0], slug: parts[1])
            }
            if host.contains("github.com"), parts.count >= 2 {
                let owner = parts[0]
                let repo = parts[1].replacingOccurrences(of: ".git", with: "")
                let sub = parts.count > 4 && parts[2] == "tree" ? parts.dropFirst(4).joined(separator: "/") : nil
                return .githubRepo(owner: owner, repo: repo, subpath: sub)
            }
        }
        return .queryOrSlug(trimmed)
    }

    // MARK: - 2. Script Command Import (Create New or Merge Into Existing Pack)

    static func importScriptCommand(
        fileURL: URL,
        mergeIntoPack: DoraxPackV2? = nil,
        stagingRoot: URL? = nil
    ) async throws -> RaycastImportResult {
        guard let rawContent = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw RaycastImportError.unreadableFile(fileURL.path)
        }
        guard let meta = parseScriptMetadata(content: rawContent) else {
            throw RaycastImportError.missingScriptMetadata
        }

        let slug = DoraxPackV3AIArchitect.slugify(meta.title, fallback: "raycast-script")
        let ext = fileURL.pathExtension.lowercased().isEmpty ? "sh" : fileURL.pathExtension.lowercased()
        let rawRel = "commands/\(slug)-raw.\(ext)"
        let wrapperRel = "commands/\(slug)-wrapper.py"

        let mappedMode: DoraxCommandMode = {
            if !meta.arguments.isEmpty { return .form }
            switch meta.mode.lowercased() {
            case "inline": return .notch
            case "compact", "silent": return .instant
            default: return .detail
            }
        }()

        let formFields: [DoraxFormField]? = meta.arguments.isEmpty ? nil : meta.arguments.enumerated().map { idx, arg in
            DoraxFormField(
                id: "arg\(idx + 1)",
                title: arg.placeholder,
                type: arg.type.lowercased() == "password" ? "secret" : "text",
                placeholder: arg.placeholder,
                required: !(arg.optional ?? false))
        }

        let runnerBin: String = {
            switch ext {
            case "py": return "/usr/bin/python3"
            case "applescript": return "/usr/bin/osascript"
            default: return "/bin/zsh"
            }
        }()

        let wrapperScript = makeWrapperScript(
            rawRelPath: rawRel,
            runnerBinary: runnerBin,
            title: meta.title,
            argCount: meta.arguments.count,
            inlineNotch: meta.mode.lowercased() == "inline")

        let baseCmd = DoraxPackCommand(
            id: slug,
            title: meta.title,
            subtitle: meta.description ?? "Imported Raycast Script Command",
            icon: mappedIcon(from: meta.icon),
            mode: mappedMode,
            keywords: [slug, meta.packageName?.lowercased() ?? "raycast", "script"],
            script: wrapperRel,
            refreshSeconds: parseRefreshSeconds(meta.refreshTime),
            timeoutSeconds: 10,
            cacheTTLSeconds: mappedMode == .form ? 0 : 30,
            formFields: formFields,
            safety: meta.needsConfirmation ? "write" : "read")

        if let targetPack = mergeIntoPack {
            var updatedMeta = targetPack.metadata
            updatedMeta.formatVersion = 2
            updatedMeta.schemaVersion = 3
            var cmds = updatedMeta.commands ?? []
            var uniqueCmd = baseCmd
            if cmds.contains(where: { $0.id == uniqueCmd.id }) {
                uniqueCmd.id = "\(slug)-\(UUID().uuidString.prefix(4).lowercased())"
            }
            cmds.append(uniqueCmd)
            updatedMeta.commands = cmds

            let jsonText = DoraxPackV3AIArchitect.encodeMetadata(updatedMeta)
            let files = [
                DoraxPackV3FileChange(relativePath: rawRel, content: rawContent, isNew: true),
                DoraxPackV3FileChange(relativePath: wrapperRel, content: wrapperScript, isNew: true),
            ]
            let patch = stageAndValidatePatch(
                pack: targetPack,
                summary: "Merged Raycast script \"\(meta.title)\" into \(targetPack.name).",
                packJSONText: jsonText,
                files: files,
                runCmd: meta.arguments.isEmpty ? uniqueCmd : nil,
                stagingRoot: stagingRoot)

            return RaycastImportResult(
                sourceKind: "Raycast Script Command",
                summary: patch.summary,
                targetPackID: targetPack.id,
                synthesis: nil,
                patch: patch)
        } else {
            let pkgTitle = meta.packageName?.isEmpty == false ? meta.packageName! : meta.title
            let packID = DoraxPackV3AIArchitect.slugify(pkgTitle, fallback: "raycast-script")
            let metadata = DoraxPackMetadata(
                formatVersion: 2,
                schemaVersion: 3,
                id: packID,
                name: pkgTitle,
                version: "3.0.0",
                icon: mappedIcon(from: meta.icon),
                description: meta.description ?? "Imported from Raycast Script Command (\(fileURL.lastPathComponent)).",
                keywords: [packID, slug, "raycast"],
                capabilities: [
                    PluginPackCapability(
                        id: "\(packID).\(slug)",
                        name: meta.title,
                        intent: meta.description ?? meta.title,
                        triggers: [meta.title.lowercased()],
                        type: "aiPrompt",
                        script: "Run the imported \(meta.title) command.",
                        safety: meta.needsConfirmation ? "write" : "read")
                ],
                scope: DoraxPackScope(surfaces: mappedMode == .notch ? ["global", "notch"] : ["global"], apps: [], domains: []),
                appearance: DoraxPackAppearance(tint: "#FF6363", glow: .soft),
                permissions: ["context:frontmost"],
                commands: [baseCmd])

            let synthesis = await stageAndValidateNewPack(
                metadata: metadata,
                agentMarkdown: "# \(pkgTitle)\n\nImported from Raycast Script Command `\(fileURL.lastPathComponent)`.\n",
                skillID: "raycast-script",
                skillMarkdown: "---\nname: raycast-script\ndescription: \(meta.description ?? meta.title)\n---\n# \(meta.title)\nRun cleanly via `commands/\(slug)-wrapper.py`.\n",
                extraFiles: [
                    DoraxPackV3FileChange(relativePath: rawRel, content: rawContent, isNew: true),
                    DoraxPackV3FileChange(relativePath: wrapperRel, content: wrapperScript, isNew: true),
                ],
                dryRunCommand: meta.arguments.isEmpty ? baseCmd : nil,
                stagingRoot: stagingRoot)

            return RaycastImportResult(
                sourceKind: "Raycast Script Command",
                summary: "Converted \"\(meta.title)\" into `.doraxpack` v3 \"\(pkgTitle)\".",
                targetPackID: nil,
                synthesis: synthesis,
                patch: nil)
        }
    }

    // MARK: - 3. Raycast Store / GitHub / Local Extension Importer

    private struct RaycastPackageJSON: Decodable {
        struct Command: Decodable {
            var name: String
            var title: String?
            var description: String?
            var mode: String?
        }
        struct Preference: Decodable {
            var name: String
            var title: String?
            var type: String?
            var required: Bool?
            var placeholder: String?
            var description: String?
        }
        var name: String?
        var title: String?
        var description: String?
        var commands: [Command]?
        var preferences: [Preference]?
    }

    static func importExtension(
        from rawSource: String,
        mergeIntoPack: DoraxPackV2? = nil,
        stagingRoot: URL? = nil,
        useLiveAI: Bool = !AppDelegate.isHostingTests
    ) async throws -> RaycastImportResult {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RaycastImportError.emptySource }

        let parsed = parseExtensionSource(trimmed)
        if case .localScript(let fileURL) = parsed {
            return try await importScriptCommand(fileURL: fileURL, mergeIntoPack: mergeIntoPack, stagingRoot: stagingRoot)
        }

        var extSlug = "raycast-extension"
        var pkg: RaycastPackageJSON? = nil

        switch parsed {
        case .localDirectory(let dirURL):
            extSlug = dirURL.lastPathComponent
            let pkgURL = dirURL.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: pkgURL) {
                pkg = try? JSONDecoder().decode(RaycastPackageJSON.self, from: data)
            }
        case .raycastStore(_, let slug):
            extSlug = slug
            if useLiveAI,
               let remoteURL = URL(string: "https://raw.githubusercontent.com/raycast/extensions/main/extensions/\(slug)/package.json")
            {
                pkg = await fetchPackageJSON(from: remoteURL)
            }
        case .githubRepo(let owner, let repo, let subpath):
            extSlug = subpath?.components(separatedBy: "/").last ?? repo
            if useLiveAI {
                let path = subpath.map { "\($0)/package.json" } ?? "package.json"
                if let remoteURL = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/\(path)") {
                    pkg = await fetchPackageJSON(from: remoteURL)
                }
            }
        case .queryOrSlug(let s):
            extSlug = DoraxPackV3AIArchitect.slugify(s, fallback: "raycast-extension")
        case .localScript:
            break
        }

        let extTitle = pkg?.title ?? extSlug.replacingOccurrences(of: "-", with: " ").capitalized
        let extDesc = pkg?.description ?? "Converted Raycast extension \"\(extTitle)\" to native .doraxpack v3."

        let convertedCommands: [DoraxPackCommand]
        var extraFiles: [DoraxPackV3FileChange] = []

        if let rawCmds = pkg?.commands, !rawCmds.isEmpty {
            convertedCommands = rawCmds.prefix(8).map { rc in
                let cmdSlug = DoraxPackV3AIArchitect.slugify(rc.name, fallback: "cmd")
                let scriptRel = "commands/\(cmdSlug).py"
                let title = rc.title ?? rc.name.capitalized
                let sub = rc.description ?? extDesc
                let scriptBody = """
                #!/usr/bin/env python3
                import json, sys
                _ = sys.stdin.read()
                print(json.dumps({
                    "detail": {
                        "markdown": "### \(title.replacingOccurrences(of: "\"", with: ""))\\n\\n\(sub.replacingOccurrences(of: "\"", with: ""))\\n\\nConverted from Raycast extension **\(extTitle.replacingOccurrences(of: "\"", with: ""))**. Customize `\(scriptRel)` or click **Upgrade with AI** to bind live APIs/CLIs.",
                        "metadata": [{"label": "Source", "value": "Raycast Import"}]
                    }
                }))
                """
                extraFiles.append(DoraxPackV3FileChange(relativePath: scriptRel, content: scriptBody, isNew: true))
                return DoraxPackCommand(
                    id: cmdSlug,
                    title: title,
                    subtitle: sub,
                    icon: "sparkles",
                    mode: rc.mode == "no-view" ? .instant : .detail,
                    keywords: [extSlug, cmdSlug, "raycast"],
                    script: scriptRel,
                    safety: "read")
            }
        } else {
            // URL / slug import fallback when no package.json was fetched
            let cmdSlug = "\(DoraxPackV3AIArchitect.slugify(extSlug, fallback: "raycast"))-action"
            let scriptRel = "commands/\(cmdSlug).py"
            let scriptBody = """
            #!/usr/bin/env python3
            import json, sys
            _ = sys.stdin.read()
            print(json.dumps({
                "detail": {
                    "markdown": "### \(extTitle.replacingOccurrences(of: "\"", with: ""))\\n\\nConverted from `\(trimmed.replacingOccurrences(of: "\"", with: ""))`. Use **Upgrade Pack with AI** (`⌘E`) to wire specific CLI or API logic.",
                    "metadata": [{"label": "Raycast Import", "value": "\(extTitle.replacingOccurrences(of: "\"", with: ""))"}]
                }
            }))
            """
            extraFiles.append(DoraxPackV3FileChange(relativePath: scriptRel, content: scriptBody, isNew: true))
            convertedCommands = [
                DoraxPackCommand(
                    id: cmdSlug,
                    title: extTitle,
                    subtitle: extDesc,
                    icon: "puzzlepiece.extension.fill",
                    mode: .detail,
                    keywords: [extSlug, "raycast"],
                    script: scriptRel,
                    safety: "read")
            ]
        }

        let convertedPrefs: [DoraxPackPreference]? = pkg?.preferences?.compactMap { rp in
            let pType: DoraxPreferenceType = {
                switch (rp.type ?? "textfield").lowercased() {
                case "password": return .secret
                case "checkbox": return .boolean
                case "dropdown": return .select
                default: return .string
                }
            }()
            return DoraxPackPreference(
                id: rp.name,
                title: rp.title ?? rp.name,
                type: pType,
                required: rp.required ?? false,
                placeholder: rp.placeholder ?? rp.description)
        }

        if let targetPack = mergeIntoPack {
            var meta = targetPack.metadata
            meta.formatVersion = 2
            meta.schemaVersion = 3
            var cmds = meta.commands ?? []
            var existingIDs = Set(cmds.map(\.id))
            for var c in convertedCommands {
                if existingIDs.contains(c.id) { c.id = "\(c.id)-\(extSlug)" }
                existingIDs.insert(c.id)
                cmds.append(c)
            }
            meta.commands = cmds
            if let convertedPrefs, !convertedPrefs.isEmpty {
                var prefs = meta.preferences ?? []
                let existingPrefIDs = Set(prefs.map(\.id))
                for p in convertedPrefs where !existingPrefIDs.contains(p.id) {
                    prefs.append(p)
                }
                meta.preferences = prefs
            }

            let jsonText = DoraxPackV3AIArchitect.encodeMetadata(meta)
            let patch = stageAndValidatePatch(
                pack: targetPack,
                summary: "Merged \(convertedCommands.count) Raycast command(s) from \"\(extTitle)\" into \(targetPack.name).",
                packJSONText: jsonText,
                files: extraFiles,
                runCmd: convertedCommands.first,
                stagingRoot: stagingRoot)

            return RaycastImportResult(
                sourceKind: "Raycast Extension",
                summary: patch.summary,
                targetPackID: targetPack.id,
                synthesis: nil,
                patch: patch)
        } else {
            let packID = DoraxPackV3AIArchitect.slugify(pkg?.name ?? extSlug, fallback: "raycast-pack")
            let metadata = DoraxPackMetadata(
                formatVersion: 2,
                schemaVersion: 3,
                id: packID,
                name: extTitle,
                version: "3.0.0",
                icon: "puzzlepiece.extension.fill",
                description: extDesc,
                keywords: [packID, "raycast"] + convertedCommands.map(\.id),
                capabilities: [
                    PluginPackCapability(
                        id: "\(packID).main",
                        name: extTitle,
                        intent: extDesc,
                        triggers: [extTitle.lowercased()],
                        type: "aiPrompt",
                        script: "Run commands from \(extTitle).",
                        safety: "read")
                ],
                scope: DoraxPackScope(surfaces: ["global"], apps: [], domains: []),
                appearance: DoraxPackAppearance(tint: "#FF6363", glow: .soft),
                permissions: ["context:frontmost"],
                preferences: convertedPrefs,
                commands: convertedCommands)

            let synthesis = await stageAndValidateNewPack(
                metadata: metadata,
                agentMarkdown: "# \(extTitle)\n\n\(extDesc)\n\nConverted from Raycast without Node daemon overhead.\n",
                skillID: "raycast-extension",
                skillMarkdown: "---\nname: raycast-extension\ndescription: \(extDesc)\n---\n# \(extTitle)\nConverted `.doraxpack` v3 bundle.\n",
                extraFiles: extraFiles,
                dryRunCommand: convertedCommands.first,
                stagingRoot: stagingRoot)

            return RaycastImportResult(
                sourceKind: "Raycast Extension",
                summary: "Converted \"\(extTitle)\" (\(convertedCommands.count) commands) to `.doraxpack` v3.",
                targetPackID: nil,
                synthesis: synthesis,
                patch: nil)
        }
    }

    // MARK: - Helpers

    private static func fetchPackageJSON(from url: URL) async -> RaycastPackageJSON? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.setValue("Context-Dock-RaycastImporter/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(RaycastPackageJSON.self, from: data)
    }

    private static func makeWrapperScript(
        rawRelPath: String,
        runnerBinary: String,
        title: String,
        argCount: Int,
        inlineNotch: Bool
    ) -> String {
        """
        #!/usr/bin/env python3
        import json, os, subprocess, sys

        try:
            ctx = json.loads(sys.stdin.read().strip() or "{}")
        except Exception:
            ctx = {}

        form = ctx.get("formValues") or {}
        args = [form.get(f"arg{i}", os.environ.get(f"DORAX_FORM_ARG{i}", "")) for i in range(1, \(argCount) + 1)]
        script_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "\(rawRelPath)")
        proc = subprocess.run(["\(runnerBinary)", script_path] + args, capture_output=True, text=True, timeout=8)
        out = (proc.stdout or proc.stderr or "").strip()

        payload = {
            "detail": {
                "markdown": out or "(Completed with no output)",
                "metadata": [{"label": "Source", "value": "Raycast Script"}, {"label": "Exit", "value": str(proc.returncode)}]
            }
        }
        if \(inlineNotch ? "True" : "False"):
            payload["notch"] = {
                "wing_text": (out.splitlines()[0] if out else "\(title.replacingOccurrences(of: "\"", with: ""))")[:16],
                "wing_icon": "bolt.fill",
                "wing_color": "#FF6363",
                "title": "\(title.replacingOccurrences(of: "\"", with: ""))",
                "subtitle": out[:80]
            }
        print(json.dumps(payload))
        """
    }

    private static func mappedIcon(from raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "terminal.fill"
        }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // If emoji or non-ASCII, default to SF Symbol
        if s.unicodeScalars.contains(where: { $0.value > 127 }) {
            return "terminal.fill"
        }
        return s
    }

    private static func stageAndValidateNewPack(
        metadata: DoraxPackMetadata,
        agentMarkdown: String,
        skillID: String,
        skillMarkdown: String,
        extraFiles: [DoraxPackV3FileChange],
        dryRunCommand: DoraxPackCommand?,
        stagingRoot: URL?
    ) async -> DoraxPackV3SynthesisResult {
        let baseDir = stagingRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("doraxpack-raycast-staging", isDirectory: true)
        let folder = baseDir.appendingPathComponent("\(metadata.id).doraxpack", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let packJSONText = DoraxPackV3AIArchitect.encodeMetadata(metadata)
        try? Data(packJSONText.utf8).write(to: folder.appendingPathComponent("pack.json"), options: .atomic)
        try? Data(agentMarkdown.utf8).write(to: folder.appendingPathComponent("AGENT.md"), options: .atomic)

        let skillDir = folder.appendingPathComponent("skills/\(skillID)", isDirectory: true)
        try? fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try? Data(skillMarkdown.utf8).write(to: skillDir.appendingPathComponent("SKILL.md"), options: .atomic)

        for file in extraFiles {
            guard let safe = DoraxPackV3EditorService.validateRelativePath(file.relativePath) else { continue }
            let dest = folder.appendingPathComponent(safe)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(file.content.utf8).write(to: dest, options: .atomic)
            if ["py", "sh", "zsh"].contains(dest.pathExtension.lowercased()) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
        }

        let loaded = (try? DoraxPackV2Loader.load(from: folder))
            ?? DoraxPackV2(metadata: metadata, agentInstructions: agentMarkdown, modes: [], skills: [], scripts: [], pageScripts: [], folderURL: folder)
        let diagnostics = DoraxPackV3Validator.validate(loaded)
        var dryOutput: DoraxCommandOutput? = nil
        var dryError: String? = nil
        if let cmd = dryRunCommand {
            let res = await DoraxPackV3Runtime.shared.runCommand(cmd, in: loaded, forceRefresh: true)
            switch res {
            case .success(let out): dryOutput = out
            case .failure(let err): dryError = err.message
            }
        }

        let review = DoraxPackV3ReviewSummary(
            packID: loaded.id,
            packName: loaded.name,
            targetLabel: "Raycast Import",
            domains: loaded.metadata.effectiveScope.domains,
            contextFieldsRead: loaded.metadata.permissions ?? [],
            networkHosts: [],
            hookSummaries: [],
            diagnostics: diagnostics,
            dryRunOutput: dryOutput,
            dryRunError: dryError,
            stagedFolderURL: folder)

        return DoraxPackV3SynthesisResult(pack: loaded, review: review, packJSONText: packJSONText)
    }

    private static func stageAndValidatePatch(
        pack: DoraxPackV2,
        summary: String,
        packJSONText: String,
        files: [DoraxPackV3FileChange],
        runCmd: DoraxPackCommand?,
        stagingRoot: URL?
    ) -> DoraxPackV3Patch {
        let base = stagingRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("doraxpack-raycast-merge-staging", isDirectory: true)
        let folder = base.appendingPathComponent("\(pack.id)-\(UUID().uuidString.prefix(6)).doraxpack", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        if fm.fileExists(atPath: pack.folderURL.path) {
            try? fm.copyItem(at: pack.folderURL, to: folder)
        } else {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try? Data(packJSONText.utf8).write(to: folder.appendingPathComponent("pack.json"), options: .atomic)
        for file in files {
            guard let safe = DoraxPackV3EditorService.validateRelativePath(file.relativePath) else { continue }
            let dest = folder.appendingPathComponent(safe)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(file.content.utf8).write(to: dest, options: .atomic)
            if ["py", "sh", "zsh"].contains(dest.pathExtension.lowercased()) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
        }
        let loaded = (try? DoraxPackV2Loader.load(from: folder))
            ?? DoraxPackV2(metadata: pack.metadata, agentInstructions: pack.agentInstructions, modes: pack.modes, skills: pack.skills, scripts: pack.scripts, pageScripts: pack.pageScripts, folderURL: folder)
        let diagnostics = DoraxPackV3Validator.validate(loaded)
        _ = runCmd
        return DoraxPackV3Patch(
            packID: loaded.id,
            packName: loaded.name,
            summary: summary,
            updatedPackJSON: packJSONText,
            files: files,
            addedPermissions: [],
            addedHooks: [],
            diagnostics: diagnostics,
            dryRunOutput: nil,
            dryRunError: nil,
            stagedFolderURL: folder)
    }
}
