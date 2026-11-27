// Context-Dock/UI/ExtensionStudioPackFlows.swift
// Context-Dock
//
// Modular subviews for ExtensionStudioBoardCard's `.appPlugin` Phase 1 (`Upgrade Existing`)
// and Phase 2 (`Import Raycast`) flows, keeping `ExtensionStudioBoardCard.swift` compact.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UpgradePackStudioLeftView: View {
    @ObservedObject var studio: ExtensionStudioModel
    @ObservedObject var v3Registry: DoraxPackV3Registry
    @Binding var upgradePatch: DoraxPackV3Patch?
    @Binding var isProposingUpgrade: Bool

    var body: some View {
        let packs = v3Registry.packs
        let activePack = v3Registry.pack(id: studio.selectedUpgradePackID) ?? packs.first
        let packID = activePack?.id ?? ""
        let isOverride = !packID.isEmpty && DoraxPackV3EditorService.shared.isUserOverride(packID: packID)
        let backups = packID.isEmpty ? [] : DoraxPackV3EditorService.shared.listBackups(for: packID)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Pack")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $studio.selectedUpgradePackID) {
                    ForEach(packs, id: \.id) { p in
                        Text("\(p.name) (v\(p.metadata.version))").tag(p.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Spacer(minLength: 4)
                Text(isOverride ? "User Override" : "Built-in · CoW")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isOverride ? .green : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }

            Text("Describe what to add, modify, or upgrade with AI")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            TextEditor(text: $studio.upgradeInstruction)
                .font(.system(size: 11.5))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 110)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))

            HStack(spacing: 6) {
                Button {
                    guard let targetPack = activePack else { return }
                    Task {
                        isProposingUpgrade = true
                        let patch = await DoraxPackV3AIArchitect.proposeUpgrade(
                            pack: targetPack,
                            instruction: studio.upgradeInstruction)
                        upgradePatch = patch
                        isProposingUpgrade = false
                    }
                } label: {
                    Label(isProposingUpgrade ? "Architecting…" : "Propose Upgrade with AI", systemImage: "wand.and.stars")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isProposingUpgrade || activePack == nil)

                if !backups.isEmpty {
                    Button("Rollback (\(backups.count))") {
                        if let restored = try? DoraxPackV3EditorService.shared.rollback(packID: packID) {
                            studio.statusMessage = "Rolled back \(restored.name) cleanly"
                            upgradePatch = nil
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if isOverride && DoraxPackV3EditorService.shared.hasShippedDefault(packID: packID) {
                    Button("Reset") {
                        if let restored = try? DoraxPackV3EditorService.shared.resetToDefault(packID: packID) {
                            studio.statusMessage = "Reset \(restored.name) to shipped default"
                            upgradePatch = nil
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

struct ImportRaycastStudioLeftView: View {
    @ObservedObject var studio: ExtensionStudioModel
    @ObservedObject var v3Registry: DoraxPackV3Registry
    @Binding var raycastImportResult: RaycastImportResult?
    @Binding var isImportingRaycast: Bool

    @State private var suggestedMergeID: String? = nil
    @State private var userChoseDestination: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raycast Store URL, GitHub URL, Script (.sh/.py), or Folder")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                TextField("https://www.raycast.com/... or /path/to/ext", text: $studio.raycastSourceText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7))
                    .onChange(of: studio.raycastSourceText) { _, newVal in
                        let suggested = RaycastImporter.suggestedMergePackID(for: newVal, existingPacks: v3Registry.packs)
                        suggestedMergeID = suggested
                        if !userChoseDestination {
                            studio.raycastMergeTargetPackID = suggested ?? ""
                        }
                    }

                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.shellScript, .pythonScript, .sourceCode, .folder]
                    if panel.runModal() == .OK, let url = panel.url {
                        studio.raycastSourceText = url.path
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Text("Destination")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { studio.raycastMergeTargetPackID },
                    set: { newVal in
                        userChoseDestination = true
                        studio.raycastMergeTargetPackID = newVal
                    }
                )) {
                    Text("Create New Pack (.doraxpack v3)").tag("")
                    ForEach(v3Registry.packs, id: \.id) { p in
                        Text("Merge into \(p.name)").tag(p.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            if studio.raycastMergeTargetPackID.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Scope")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $studio.raycastScopeMode) {
                            ForEach(RaycastImportScopeMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    if studio.raycastScopeMode == .globalAndApp || studio.raycastScopeMode == .frontmostAppOnly {
                        let runningApps = NSWorkspace.shared.runningApplications
                            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
                        HStack(spacing: 6) {
                            Text("Target App")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("com.apple.Safari (optional auto-detect)", text: $studio.raycastTargetBundleID)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .padding(.horizontal, 7)
                                .frame(height: 24)
                                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                            if !runningApps.isEmpty {
                                Menu("Pick") {
                                    ForEach(runningApps, id: \.processIdentifier) { app in
                                        if let bid = app.bundleIdentifier {
                                            Button(app.localizedName ?? bid) {
                                                studio.raycastTargetBundleID = bid
                                            }
                                        }
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                    } else if studio.raycastScopeMode == .webDomain {
                        HStack(spacing: 6) {
                            Text("Domain")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("github.com", text: $studio.raycastTargetDomain)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .padding(.horizontal, 7)
                                .frame(height: 24)
                                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            if let matchID = suggestedMergeID, let matchPack = v3Registry.pack(id: matchID) {
                Text("Matched installed pack \(matchPack.name) — merge keeps its existing commands & scope, or choose Create New + Scope above.")
                    .font(.system(size: 10))
                    .foregroundStyle(.cyan)
            } else {
                Text("Zero-Node import with Raycast arguments, dropdowns, @pack AI tools & required preferences using your selected AI provider.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    isImportingRaycast = true
                    let mergeTarget = studio.raycastMergeTargetPackID.isEmpty
                        ? nil
                        : v3Registry.pack(id: studio.raycastMergeTargetPackID)
                    do {
                        let imported = try await RaycastImporter.importExtension(
                            from: studio.raycastSourceText,
                            mergeIntoPack: mergeTarget,
                            existingPackIDs: Set(v3Registry.packs.map(\.id)),
                            scopeMode: mergeTarget == nil ? studio.raycastScopeMode : nil,
                            targetAppBundleID: studio.raycastTargetBundleID.isEmpty ? nil : studio.raycastTargetBundleID,
                            targetDomain: studio.raycastTargetDomain.isEmpty ? nil : studio.raycastTargetDomain)
                        raycastImportResult = imported
                        studio.statusMessage = nil
                    } catch {
                        studio.statusMessage = "Import failed: \(error.localizedDescription)"
                    }
                    isImportingRaycast = false
                }
            } label: {
                Label(isImportingRaycast ? "Converting & Synthesizing…" : "Import & Convert", systemImage: "square.and.arrow.down")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isImportingRaycast || studio.raycastSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct UpgradePatchReviewCardView: View {
    let patch: DoraxPackV3Patch
    @ObservedObject var studio: ExtensionStudioModel
    @ObservedObject var v3Registry: DoraxPackV3Registry
    @Binding var upgradePatch: DoraxPackV3Patch?

    var body: some View {
        let errs = patch.diagnostics.filter { $0.severity == .error }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Upgrade Review · \(patch.packName)", systemImage: "wand.and.stars")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Image(systemName: errs.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(errs.isEmpty ? .green : .orange)
            }

            Text(patch.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if !patch.files.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Files (\(patch.files.count + 1))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("• pack.json (updated)")
                        .font(.system(size: 10.5, design: .monospaced))
                    ForEach(patch.files) { f in
                        Text("• \(f.relativePath) (\(f.isNew ? "new" : "modified"))")
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
            }

            if !patch.addedPermissions.isEmpty || !patch.addedHooks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !patch.addedPermissions.isEmpty {
                        Text("New Permissions: \(patch.addedPermissions.joined(separator: ", "))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }
                    if !patch.addedHooks.isEmpty {
                        Text("New Hooks: \(patch.addedHooks.joined(separator: ", "))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let dry = patch.dryRunOutput {
                Text("Dry-Run: \(dry.items.first?.title ?? String(dry.detail?.markdown.prefix(90) ?? "OK"))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.green)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button("Apply Upgrade (.doraxpack v3)") {
                    guard let base = v3Registry.pack(id: patch.packID) else { return }
                    do {
                        let updated = try DoraxPackV3EditorService.shared.applyPatch(patch, to: base)
                        studio.statusMessage = "✓ Upgraded \(updated.name) to v\(updated.metadata.version) (backup saved)"
                        upgradePatch = nil
                    } catch {
                        studio.statusMessage = "Upgrade failed: \(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(patch.hasBlockingErrors)

                Button("Dismiss") { upgradePatch = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct RaycastImportReviewCardView: View {
    let imported: RaycastImportResult
    @ObservedObject var studio: ExtensionStudioModel
    @ObservedObject var v3Registry: DoraxPackV3Registry
    @Binding var raycastImportResult: RaycastImportResult?
    var onInstalledTryCommand: ((String, String) -> Void)? = nil

    var body: some View {
        let previewCommands: [DoraxPackCommand] = imported.synthesis?.pack.metadata.commands
            ?? imported.patch.flatMap { p in
                (try? JSONDecoder().decode(DoraxPackMetadata.self, from: Data(p.updatedPackJSON.utf8)))?.commands
            } ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(imported.sourceKind, systemImage: "square.and.arrow.down")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(imported.synthesizedWithAI ? "AI Live Code" : "Template")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(imported.synthesizedWithAI ? .green : .orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: Capsule())
                let errs = imported.diagnostics.filter { $0.severity == .error }
                Image(systemName: errs.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(errs.isEmpty ? .green : .orange)
            }
            Text(imported.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if !imported.scopeSummary.isEmpty {
                    Text("Scope: \(imported.scopeSummary)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.cyan)
                } else if let bundleID = imported.matchedAppBundleID {
                    Text("Scope: Global (`⌥⌥`/`⌘⌘`) + Frontmost (`\(bundleID)`)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.cyan)
                }
                if imported.importedToolCount > 0 {
                    Text("AI Tools (@pack): \(imported.importedToolCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.purple)
                }
            }

            if !previewCommands.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(previewCommands.prefix(5)), id: \.id) { c in
                        Text("• \(c.title)")
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
            }

            HStack(spacing: 8) {
                if let patch = imported.patch {
                    Button("Merge into \(patch.packName)") {
                        guard let base = v3Registry.pack(id: patch.packID) else { return }
                        do {
                            let merged = try DoraxPackV3EditorService.shared.applyPatch(patch, to: base)
                            studio.statusMessage = "✓ Merged into \(merged.name) — search command in ⌥⌥/⌘⌘"
                            studio.raycastMergeTargetPackID = ""
                            studio.raycastSourceText = ""
                            raycastImportResult = nil
                            if let firstCmd = previewCommands.first?.id {
                                onInstalledTryCommand?(merged.id, firstCmd)
                            }
                        } catch {
                            studio.statusMessage = "Merge failed: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(imported.hasBlockingErrors)
                } else if let syn = imported.synthesis {
                    Button("Install & Open") {
                        do {
                            let installed = try DoraxPackV3Builder.approveAndInstall(syn)
                            studio.statusMessage = "✓ Installed \(installed.name) (.doraxpack v3)"
                            studio.raycastMergeTargetPackID = ""
                            studio.raycastSourceText = ""
                            raycastImportResult = nil
                            if let firstCmd = installed.metadata.commands?.first?.id {
                                onInstalledTryCommand?(installed.id, firstCmd)
                            }
                        } catch {
                            studio.statusMessage = "Install failed: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(imported.hasBlockingErrors)
                }
                Button("Dismiss") { raycastImportResult = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
