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
                Picker("", selection: $studio.raycastMergeTargetPackID) {
                    Text("Create New Pack (.doraxpack v3)").tag("")
                    ForEach(v3Registry.packs, id: \.id) { p in
                        Text("Merge into \(p.name)").tag(p.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            Text("Script commands (`@raycast.*`) convert deterministically without Node. Store/local extensions map into native `.doraxpack` v3 commands that you can upgrade anytime with AI.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Button {
                Task {
                    isImportingRaycast = true
                    let mergeTarget = studio.raycastMergeTargetPackID.isEmpty
                        ? nil
                        : v3Registry.pack(id: studio.raycastMergeTargetPackID)
                    do {
                        let imported = try await RaycastImporter.importExtension(
                            from: studio.raycastSourceText,
                            mergeIntoPack: mergeTarget)
                        raycastImportResult = imported
                        studio.statusMessage = nil
                    } catch {
                        studio.statusMessage = "Import failed: \(error.localizedDescription)"
                    }
                    isImportingRaycast = false
                }
            } label: {
                Label(isImportingRaycast ? "Converting…" : "Import & Convert", systemImage: "square.and.arrow.down")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(imported.sourceKind, systemImage: "square.and.arrow.down")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                let errs = imported.diagnostics.filter { $0.severity == .error }
                Image(systemName: errs.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(errs.isEmpty ? .green : .orange)
            }
            Text(imported.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let patch = imported.patch {
                    Button("Merge into \(patch.packName)") {
                        guard let base = v3Registry.pack(id: patch.packID) else { return }
                        do {
                            let merged = try DoraxPackV3EditorService.shared.applyPatch(patch, to: base)
                            studio.statusMessage = "✓ Merged Raycast command into \(merged.name)"
                            raycastImportResult = nil
                        } catch {
                            studio.statusMessage = "Merge failed: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(imported.hasBlockingErrors)
                } else if let syn = imported.synthesis {
                    Button("Install Imported Pack") {
                        do {
                            let installed = try DoraxPackV3Builder.approveAndInstall(syn)
                            studio.statusMessage = "✓ Installed \(installed.name) (.doraxpack v3)"
                            raycastImportResult = nil
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
