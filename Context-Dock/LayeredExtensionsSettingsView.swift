//
//  LayeredExtensionsSettingsView.swift
//  ILauncher
//
//  Settings UI for layer-based extension management
//

import SwiftUI
import UniformTypeIdentifiers

struct LayeredExtensionsSettingsView: View {
    @StateObject private var extensionManager = LayeredExtensionManager.shared
    @State private var selectedLayer: ExtensionLayer = .l2_context
    @State private var selectedCategory: String? = nil
    @State private var searchText = ""
    @State private var showingAddExtension = false
    @State private var selectedExtension: ILExtension?
    @State private var isDraggingOver = false
    @State private var showImportDialog = false
    @State private var importedFileURL: URL?
    @State private var showingEditExtension = false
    @State private var extensionToEdit: ILExtension?

    // Terminal section + AI tool editor (now embedded in l2_context layer)
    @State private var showAIToolEditor = false
    @State private var showingTerminal = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            HSplitView {
                // Sidebar - Layer & Category selection
                sidebarView
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

                if showingTerminal {
                    // Terminal Packages pane — full-width
                    TerminalSettingsView()
                        .frame(minWidth: 600)
                } else {
                    // Main content - Extension list (includes AI Tools when l2_context is selected)
                    extensionListView
                        .frame(minWidth: 400)
                        .onDrop(of: [.fileURL], isTargeted: $isDraggingOver) { providers in
                            handleDrop(providers: providers)
                        }
                        .overlay(isDraggingOver ? dragOverlay : nil)
                        .sheet(isPresented: $showAIToolEditor) {
                            L2ExtensionEditorSheet(onSave: {
                                Task { await L2ExtensionManager.shared.loadExtensions() }
                            })
                        }

                    // Detail panel
                    if let ext = selectedExtension {
                        extensionDetailView(ext)
                            .frame(minWidth: 300, idealWidth: 350)
                    } else {
                        emptyDetailView
                            .frame(minWidth: 300, idealWidth: 350)
                    }
                }
            }
        }
        // Add/Edit extension uses NSWindow for reliable full sizing (see openEditorWindow)
        .sheet(isPresented: $showImportDialog) {
            if let url = importedFileURL {
                ImportExtensionDialog(
                    fileURL: url,
                    selectedLayer: selectedLayer,
                    onImport: { layer in
                        Task {
                            await importExtension(from: url, to: layer)
                        }
                    },
                    onCancel: {
                        showImportDialog = false
                        importedFileURL = nil
                    }
                )
            }
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 12) {
            if !showingTerminal {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 12))
                    TextField("Search…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 220)

                Spacer()

                Button(action: { openEditorWindow(existing: nil) }) {
                    Label("New Action", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Sidebar
    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Section title
            HStack {
                Text("Layers")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 6)

            // Layer rows
            VStack(spacing: 2) {
                ForEach(ExtensionLayer.allCases.filter { $0 != .l1_search }, id: \.self) { layer in
                    SidebarLayerRow(
                        layer: layer,
                        count: extensionManager.extensions(for: layer).count,
                        isSelected: selectedLayer == layer && !showingTerminal
                    )
                    .onTapGesture {
                        selectedLayer = layer
                        showingTerminal = false
                        selectedCategory = nil
                    }
                }

                // Terminal row
                SidebarTerminalRow(
                    count: TerminalPackageManager.shared.packages.count,
                    isSelected: showingTerminal
                )
                .onTapGesture { showingTerminal = true }
            }
            .padding(.horizontal, 8)

            // Categories (only when not in terminal mode and categories exist)
            if !showingTerminal && !categoriesForSelectedLayer.isEmpty {
                Divider().padding(.vertical, 10).padding(.horizontal, 14)

                HStack {
                    Text("Categories")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    if selectedCategory != nil {
                        Button("Clear") { selectedCategory = nil }
                            .font(.system(size: 10))
                            .foregroundStyle(.blue)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

                VStack(spacing: 2) {
                    ForEach(categoriesForSelectedLayer, id: \.self) { cat in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(selectedCategory == cat ? Color.accentColor : Color.secondary.opacity(0.4))
                                .frame(width: 6, height: 6)
                            Text(cat.capitalized.replacingOccurrences(of: "-", with: " "))
                                .font(.system(size: 12))
                                .foregroundStyle(selectedCategory == cat ? .primary : .secondary)
                            Spacer()
                            Text("\(extensionManager.extensions(for: selectedLayer, category: cat).count)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(selectedCategory == cat ? Color.accentColor.opacity(0.1) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedCategory = cat }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onChange(of: selectedLayer) { _, _ in
            selectedCategory = nil
        }
    }

    // MARK: - Extension List
    private var extensionListView: some View {
        VStack(spacing: 0) {
            // Slim layer bar
            HStack(spacing: 8) {
                Image(systemName: selectedLayer.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(selectedLayer.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(selectedLayer.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !filteredExtensions.isEmpty {
                    Text("\(filteredExtensions.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()

            let exts = filteredExtensions
            if exts.isEmpty {
                extensionEmptyState
            } else {
                List(selection: Binding(
                    get: { selectedExtension?.id },
                    set: { id in selectedExtension = exts.first { $0.id == id } }
                )) {
                    ForEach(exts) { ext in
                        ExtensionListRow(ext: ext)
                            .tag(ext.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var extensionEmptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.06))
                    .frame(width: 72, height: 72)
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue.opacity(0.5))
            }

            VStack(spacing: 6) {
                Text("No actions yet")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Actions appear here when triggered by keywords, file types, or app context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }

            Button(action: { openEditorWindow(existing: nil) }) {
                Label("Create Action", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Detail View
    private func extensionDetailView(_ ext: ILExtension) -> some View {
        VStack(spacing: 0) {
            // Compact header bar
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.blue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: ext.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(ext.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text("v\(ext.version) · \(ext.author)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: binding(for: ext, keyPath: \.enabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Description
                    Text(ext.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    // Triggers
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TRIGGERS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(Array(ext.triggers.enumerated()), id: \.offset) { _, trigger in
                            TriggerView(trigger: trigger)
                        }
                    }

                    // Layer / Category
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DETAILS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        HStack {
                            Text("Layer").foregroundStyle(.secondary)
                            Spacer()
                            Text(ext.layer.displayName)
                        }
                        .font(.system(size: 12))
                        HStack {
                            Text("Category").foregroundStyle(.secondary)
                            Spacer()
                            Text(ext.category.capitalized)
                        }
                        .font(.system(size: 12))
                        if ext.usageCount > 0 {
                            HStack {
                                Text("Used").foregroundStyle(.secondary)
                                Spacer()
                                Text("\(ext.usageCount) times")
                            }
                            .font(.system(size: 12))
                        }
                    }

                    // Script preview
                    if let script = ext.scriptContent {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SCRIPT")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(script.prefix(300))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // Tags
                    if !ext.tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(ext.tags, id: \.self) { tag in TagChip(tag: tag) }
                        }
                    }
                }
                .padding(14)
            }

            // Action bar
            if !ext.isBuiltIn {
                Divider()
                HStack(spacing: 8) {
                    Button("Edit") { openEditorWindow(existing: ext) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                    Button("Delete") {
                        extensionManager.deleteExtension(ext)
                        selectedExtension = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var emptyDetailView: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Select an action")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Computed Properties
    private var filteredExtensions: [ILExtension] {
        var exts = extensionManager.extensions(for: selectedLayer)

        // Filter by category if selected
        if let category = selectedCategory {
            exts = exts.filter { $0.category == category }
        }

        // Filter by search text
        if !searchText.isEmpty {
            exts = exts.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }

        return exts.sorted { $0.name < $1.name }
    }

    private var categoriesForSelectedLayer: [String] {
        let extensions = extensionManager.extensions(for: selectedLayer)
        let categories = Set(extensions.map { $0.category })
        return Array(categories).sorted()
    }

    // MARK: - Helper Methods
    private func binding<T>(for ext: ILExtension, keyPath: WritableKeyPath<ILExtension, T>) -> Binding<T> {
        Binding(
            get: {
                if let index = extensionManager.allExtensions.firstIndex(where: { $0.id == ext.id }) {
                    return extensionManager.allExtensions[index][keyPath: keyPath]
                }
                return ext[keyPath: keyPath]
            },
            set: { newValue in
                if let index = extensionManager.allExtensions.firstIndex(where: { $0.id == ext.id }) {
                    extensionManager.allExtensions[index][keyPath: keyPath] = newValue
                    extensionManager.updateExtension(extensionManager.allExtensions[index])
                }
            }
        )
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Editor Window
    // Opens the QuickActionEditorView as a real NSWindow so it always appears at full size.
    // SwiftUI .sheet inside a Settings window ignores .frame() size constraints.
    private static var editorWindow: NSWindow?

    private func openEditorWindow(existing: ILExtension?) {
        Self.editorWindow?.close()

        let view = QuickActionEditorView(
            extensionManager: extensionManager,
            existing: existing,
            onSave: { Task { await extensionManager.loadExtensions() } },
            onClose: { Self.editorWindow?.close(); Self.editorWindow = nil }
        )
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = existing == nil ? "New Quick Action" : "Edit Quick Action"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 900, height: 660))
        window.minSize = NSSize(width: 740, height: 560)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.editorWindow = window
    }

    // MARK: - Drag and Drop
    private var dragOverlay: some View {
        ZStack {
            // Semi-transparent background
            Color.blue.opacity(0.1)

            VStack(spacing: 16) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)

                Text("Drop extension here")
                    .font(.title2.bold())

                Text("Supports .sh, .py, .js, .rb, .applescript files")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(40)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .shadow(radius: 20)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, error in
            guard let url = url, error == nil else { return }

            DispatchQueue.main.async {
                self.importedFileURL = url
                self.showImportDialog = true
            }
        }

        return true
    }

    private func importExtension(from sourceURL: URL, to layer: ExtensionLayer) async {
        do {
            // Determine target directory based on layer
            let targetDir: String
            switch layer {
            case .l1_search:
                targetDir = "/Users/gokulakannan/Desktop/ILauncher/StarterExtensions"
            case .l2_context:
                targetDir = "/Users/gokulakannan/Desktop/ILauncher/AIExtensions"
            case .l3_browser:
                targetDir = "/Users/gokulakannan/Desktop/ILauncher/StarterExtensions"
            case .crossLayer:
                targetDir = "/Users/gokulakannan/Desktop/ILauncher/StarterExtensions"
            }

            let fileName = sourceURL.lastPathComponent
            let targetURL = URL(fileURLWithPath: targetDir).appendingPathComponent(fileName)

            // Copy file to target directory
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: sourceURL, to: targetURL)

            // Make executable
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetURL.path)

            // Auto-generate extension metadata
            let metadata = await generateExtensionMetadata(from: targetURL)

            // Register in extensions.json if L1 layer
            if layer == .l1_search {
                try await registerInExtensionsJSON(metadata: metadata, scriptName: fileName)
            }

            // Refresh extension manager
            await extensionManager.loadExtensions()
            await MainActor.run {
                showImportDialog = false
                importedFileURL = nil

                // Show success notification
                let notification = NSUserNotification()
                notification.title = "Extension Imported!"
                notification.informativeText = "\(metadata.name) added to \(layer.displayName)"
                NSUserNotificationCenter.default.deliver(notification)
            }

        } catch {
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func generateExtensionMetadata(from fileURL: URL) async -> ExtensionMetadata {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        var name = fileName.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized

        var description = "Custom extension"
        var keywords: [String] = []
        var patterns: [String] = []
        var icon = "star.fill"

        // Try to read script and extract metadata from comments
        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)

            for line in lines.prefix(20) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Look for metadata in comments
                if trimmed.hasPrefix("# Name:") || trimmed.hasPrefix("// Name:") {
                    name = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                }
                else if trimmed.hasPrefix("# Description:") || trimmed.hasPrefix("// Description:") {
                    description = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                }
                else if trimmed.hasPrefix("# Icon:") || trimmed.hasPrefix("// Icon:") {
                    icon = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                }
                else if trimmed.hasPrefix("# Keywords:") || trimmed.hasPrefix("// Keywords:") {
                    let keywordStr = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    keywords = keywordStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                else if trimmed.hasPrefix("# Pattern:") || trimmed.hasPrefix("// Pattern:") {
                    let pattern = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    patterns.append(pattern)
                }
            }
        }

        // Generate default pattern if none found
        if patterns.isEmpty {
            let keyword = fileName.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            patterns = ["^\(keyword)\\s+.+", "^\(keyword)$"]
        }

        return ExtensionMetadata(
            name: name,
            description: description,
            icon: icon,
            keywords: keywords,
            patterns: patterns
        )
    }

    private func registerInExtensionsJSON(metadata: ExtensionMetadata, scriptName: String) async throws {
        let jsonPath = "/Users/gokulakannan/Desktop/ILauncher/StarterExtensions/extensions.json"
        let jsonURL = URL(fileURLWithPath: jsonPath)

        // Read existing JSON
        let data = try Data(contentsOf: jsonURL)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var extensions = json["extensions"] as! [[String: Any]]

        // Create new extension entry
        let newExtension: [String: Any] = [
            "id": scriptName.replacingOccurrences(of: ".sh", with: "").replacingOccurrences(of: ".py", with: ""),
            "name": metadata.name,
            "description": metadata.description,
            "script": scriptName,
            "icon": metadata.icon,
            "keywords": metadata.keywords,
            "patterns": metadata.patterns,
            "examples": metadata.patterns.map { pattern in
                // Generate example from pattern
                pattern.replacingOccurrences(of: "^", with: "")
                    .replacingOccurrences(of: "\\s+", with: " ")
                    .replacingOccurrences(of: ".+", with: "example")
                    .replacingOccurrences(of: "$", with: "")
            },
            "priority": 20
        ]

        // Check for duplicates
        extensions.removeAll { ext in
            (ext["id"] as? String) == (newExtension["id"] as? String)
        }

        // Add new extension
        extensions.append(newExtension)
        json["extensions"] = extensions

        // Write back
        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try updatedData.write(to: jsonURL)
    }
}

// MARK: - Extension Metadata
struct ExtensionMetadata {
    let name: String
    let description: String
    let icon: String
    let keywords: [String]
    let patterns: [String]
}

// MARK: - Import Extension Dialog
struct ImportExtensionDialog: View {
    let fileURL: URL
    @State var selectedLayer: ExtensionLayer
    let onImport: (ExtensionLayer) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Extension")
                        .font(.title2.bold())

                    Text(fileURL.lastPathComponent)
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            Divider()

            // Layer selection
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose Extension Layer")
                    .font(.headline)

                Text("The extension will be automatically configured and added to the selected layer.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Layer", selection: $selectedLayer) {
                    ForEach(ExtensionLayer.allCases, id: \.self) { layer in
                        HStack {
                            Image(systemName: layer.icon)
                            Text(layer.displayName)
                        }
                        .tag(layer)
                    }
                }
                .pickerStyle(.radioGroup)

                // Layer description
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedLayer.displayName)
                        .font(.subheadline.bold())

                    Text(selectedLayer.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(8)
            }

            Divider()

            // Auto-configuration info
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.purple)
                    Text("Automatic Configuration")
                        .font(.subheadline.bold())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("Extract metadata from script comments", systemImage: "checkmark.circle.fill")
                    Label("Generate default patterns and keywords", systemImage: "checkmark.circle.fill")
                    Label("Make script executable (chmod +x)", systemImage: "checkmark.circle.fill")
                    Label("Register in extensions.json", systemImage: "checkmark.circle.fill")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.purple.opacity(0.05))
            .cornerRadius(8)

            // Tip box
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pro Tip")
                        .font(.caption.bold())

                    Text("Add metadata comments at the top of your script:\n# Name: My Extension\n# Description: Does something cool\n# Icon: star.fill\n# Keywords: keyword1, keyword2\n# Pattern: ^mycommand\\s+.+")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.05))
            .cornerRadius(8)

            // Actions
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import Extension") {
                    onImport(selectedLayer)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}

// MARK: - AI Tools Inline View
struct AIToolsInlineView: View {
    @StateObject private var extManager = L2ExtensionManager.shared
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Example gallery
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Example Tools", systemImage: "star.circle.fill")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.purple)
                        Spacer()
                        Text("tap to install").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(L2ExampleExtension.all) { example in
                                L2ExampleCard(example: example, onInstall: {
                                    Task { await extManager.loadExtensions() }
                                })
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 12)

                Divider().padding(.horizontal)

                // How it works callout
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.blue).font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How AI Tools work")
                            .font(.caption).fontWeight(.semibold)
                        Text("When you chat in the L2 terminal, the AI can call these tools automatically. Say \"compress my files\" and the AI picks the right tool, runs it, and shows you the result.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)

                // Installed tools
                if extManager.extensions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 32)).foregroundStyle(.purple.opacity(0.4))
                        Text("No AI tools installed yet")
                            .font(.subheadline).fontWeight(.semibold)
                        Text("Install an example above or create your own.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(action: { showEditor = true }) {
                            Label("New AI Tool", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }
                    .padding(30).frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Installed (\(extManager.extensions.count))")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        ForEach(extManager.extensions) { ext in
                            L2ExtensionCard(ext: ext)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .task { await extManager.loadExtensions() }
        .sheet(isPresented: $showEditor) {
            L2ExtensionEditorSheet(onSave: { Task { await extManager.loadExtensions() } })
        }
    }
}

// MARK: - New Sidebar Row Views

struct SidebarLayerRow: View {
    let layer: ExtensionLayer
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                    .frame(width: 26, height: 26)
                Image(systemName: layer.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.1), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

struct SidebarTerminalRow: View {
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.green.opacity(0.2) : Color.green.opacity(0.08))
                    .frame(width: 26, height: 26)
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            }
            Text("Terminal Packages")
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.1), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.green.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

struct ExtensionListRow: View {
    let ext: ILExtension

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: ext.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ext.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if ext.isBuiltIn {
                        Text("built-in")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.1), in: Capsule())
                    }
                    if !ext.enabled {
                        Text("off")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(ext.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Trigger badge
            if let badge = triggerBadge {
                Text(badge)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .opacity(ext.enabled ? 1 : 0.5)
    }

    private var iconColor: Color {
        switch ext.layer {
        case .l2_context: return .blue
        case .l3_browser: return .orange
        case .crossLayer:  return .purple
        default:           return .gray
        }
    }

    private var triggerBadge: String? {
        for trigger in ext.triggers {
            switch trigger {
            case .keyword(let kws): return kws.first.map { "\"\($0)\"" }
            case .fileType(let types): return types.prefix(2).joined(separator: ", ")
            case .appContext(let app): return app
            case .selection: return "on select"
            case .always: return "always"
            case .urlPattern: return "url"
            }
        }
        return nil
    }
}

// MARK: - Supporting Views
struct LayerRow: View {
    let layer: ExtensionLayer
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: layer.icon)
                .foregroundStyle(isSelected ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(layer.displayName)
                    .font(.body)

                Text("\(count) extensions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}

struct CategoryRow: View {
    let category: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(category.capitalized.replacingOccurrences(of: "-", with: " "))
                .font(.body)

            Spacer()

            Text("\(count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }
}

struct QuickFilterRow: View {
    let icon: String
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.body)

            Spacer()

            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct ExtensionCard: View {
    let `extension`: ILExtension
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            Image(systemName: `extension`.icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(`extension`.name)
                        .font(.headline)

                    if `extension`.isBuiltIn {
                        Text("Built-in")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }

                    Spacer()

                    Toggle("", isOn: .constant(`extension`.enabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                Text(`extension`.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                // Tags preview
                HStack(spacing: 4) {
                    ForEach(`extension`.tags.prefix(3), id: \.self) { tag in
                        Text(tag.rawValue)
                            .font(.system(size: 9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(4)
                    }

                    if `extension`.tags.count > 3 {
                        Text("+\(`extension`.tags.count - 3)")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            content
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
        .font(.body)
    }
}

struct TagChip: View {
    let tag: ExtensionTag

    var body: some View {
        Text(tag.displayName)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tagColor.opacity(0.2))
            .foregroundColor(tagColor)
            .cornerRadius(12)
    }

    private var tagColor: Color {
        switch tag.category {
        case .context: return .blue
        case .capability: return .green
        case .scope: return .orange
        }
    }
}

struct TriggerView: View {
    let trigger: ExtensionTrigger

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: triggerIcon)
                .foregroundColor(.blue)
                .frame(width: 16)

            Text(triggerDescription)
                .font(.caption)
        }
    }

    private var triggerIcon: String {
        switch trigger {
        case .keyword: return "textformat.abc"
        case .fileType: return "doc"
        case .appContext: return "app"
        case .selection: return "hand.point.up.left"
        case .always: return "checkmark.circle"
        case .urlPattern: return "link"
        }
    }

    private var triggerDescription: String {
        switch trigger {
        case .keyword(let keywords):
            return "Keywords: \(keywords.joined(separator: ", "))"
        case .fileType(let types):
            return "File types: \(types.joined(separator: ", "))"
        case .appContext(let app):
            return "App: \(app)"
        case .selection:
            return "When files selected"
        case .always:
            return "Always available"
        case .urlPattern(let pattern):
            return "URL: \(pattern)"
        }
    }
}

// Simple FlowLayout for tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX, y: bounds.minY + result.frames[index].minY), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var frames: [CGRect] = []
        var size: CGSize = .zero

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

// MARK: - Quick Action Creator (Add + Edit unified)

struct QuickActionEditorView: View {
    @ObservedObject var extensionManager: LayeredExtensionManager
    @Environment(\.dismiss) var dismiss

    // Editing an existing extension, or nil for new
    var existing: ILExtension?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?  // called when window should close (NSWindow mode)

    // Pre-fill defaults when opening from App Shortcuts panel
    var defaultLayer: ExtensionLayer = .l2_context
    var defaultAppContext: String = ""  // app name/bundle-id to pre-set the context trigger

    // ── Form fields ──────────────────────────────────────
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var icon: String = "gear"
    @State private var selectedLayer: ExtensionLayer = .l2_context
    @State private var scriptType: ILExtension.ScriptType = .bash
    @State private var scriptContent: String = ""
    @State private var triggerKeywords: String = ""   // comma-separated
    @State private var contextAppBundleId: String = "" // "" = any app
    @State private var fileTypeFilter: String = ""     // e.g. "pdf,jpg"
    @State private var showIconPicker = false
    @State private var saveError: String?
    @State private var saveSuccess = false

    // Running apps for context app picker
    @State private var runningApps: [(name: String, bundleId: String, icon: NSImage?)] = []

    // ── Script templates per type ─────────────────────────
    private static let templates: [ILExtension.ScriptType: String] = [
        .bash: """
#!/bin/bash
# Quick Action — receives file paths as $1, $2, $3...
# Example: open each selected file
for f in "$@"; do
    echo "Processing: $f"
done
""",
        .python: """
#!/usr/bin/env python3
# Quick Action — receives file paths as sys.argv[1], [2], ...
import sys
for path in sys.argv[1:]:
    print(f"Processing: {path}")
""",
        .applescript: """
-- Quick Action — selected files passed as a newline-separated list in argv
on run argv
    set filePaths to item 1 of argv
    display notification "Running action on: " & filePaths
end run
""",
        .javascript: """
// Quick Action (Browser / Web Actions layer)
// document and window are available
console.log("Running on:", document.title);
""",
        .swift: """
import Foundation
// Quick Action — file paths arrive as CommandLine.arguments[1...]
let paths = CommandLine.arguments.dropFirst()
for path in paths { print("Processing: \\(path)") }
"""
    ]

    var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Edit Quick Action" : "New Quick Action")
                        .font(.title3.bold())
                    Text("Appears as a button on search results")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: pasteFromClipboard) {
                    Label("Paste from AI", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help("Paste a script that Claude or another AI generated")
                Button("Cancel") { if let c = onClose { c() } else { dismiss() } }.buttonStyle(.bordered)
                Button(isEditing ? "Save" : "Add Action") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            Divider()

            if let err = saveError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(.caption)
                    Spacer()
                    Button("Dismiss") { saveError = nil }.font(.caption)
                }
                .padding(.horizontal).padding(.vertical, 6)
                .background(.red.opacity(0.08))
            }

            HStack(spacing: 0) {
                // ── LEFT: guided form ────────────────────────
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {

                        // Icon + Name row
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Button(action: { showIconPicker.toggle() }) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(.blue.opacity(0.12))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: icon)
                                            .font(.system(size: 16))
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("Pick an icon")
                                .popover(isPresented: $showIconPicker) {
                                    IconPickerPopover(selected: $icon)
                                }

                                TextField("e.g. Compress to ZIP", text: $name)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        // Description
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Description").font(.caption).foregroundStyle(.secondary)
                            TextField("What does this action do? (shown to user)", text: $description)
                                .textFieldStyle(.roundedBorder)
                        }

                        Divider()

                        // Where it shows up
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SHOWS IN").font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.tertiary)

                            // Compact icon-only segmented picker to fit the panel width
                            HStack(spacing: 0) {
                                ForEach(ExtensionLayer.allCases, id: \.self) { layer in
                                    Button(action: {
                                        selectedLayer = layer
                                        applyLayerDefaults()
                                    }) {
                                        VStack(spacing: 3) {
                                            Image(systemName: layer.icon)
                                                .font(.system(size: 13))
                                            Text(layer.displayName)
                                                .font(.system(size: 9))
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(selectedLayer == layer ? Color.accentColor.opacity(0.18) : Color.clear)
                                        .foregroundStyle(selectedLayer == layer ? Color.accentColor : Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    if layer != ExtensionLayer.allCases.last {
                                        Divider().frame(height: 32)
                                    }
                                }
                            }
                            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2), lineWidth: 1))

                            Text(selectedLayer.description)
                                .font(.caption2).foregroundStyle(.secondary)

                            // Context app picker (for Context Actions)
                            if selectedLayer == .l2_context {
                                HStack(spacing: 8) {
                                    Image(systemName: "app.connected.to.app.below.fill")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("Only when:").font(.caption).foregroundStyle(.secondary)
                                    Menu {
                                        Button { contextAppBundleId = "" } label: {
                                            Label("Any app", systemImage: "infinity")
                                        }
                                        if !runningApps.isEmpty {
                                            Divider()
                                            ForEach(runningApps, id: \.bundleId) { app in
                                                Button {
                                                    contextAppBundleId = app.bundleId
                                                } label: {
                                                    HStack {
                                                        if let ic = app.icon { Image(nsImage: ic) }
                                                        Text(app.name)
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            if contextAppBundleId.isEmpty {
                                                Text("Any app")
                                            } else {
                                                Text(runningApps.first(where: { $0.bundleId == contextAppBundleId })?.name ?? contextAppBundleId)
                                            }
                                            Image(systemName: "chevron.down").font(.system(size: 8))
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // File type filter (for File Actions)
                            if selectedLayer == .l1_search {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc").font(.caption).foregroundStyle(.secondary)
                                    Text("File types:").font(.caption).foregroundStyle(.secondary)
                                    TextField("pdf, jpg, png  (leave blank = all files)", text: $fileTypeFilter)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                }
                            }
                        }

                        Divider()

                        // Trigger keywords
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TRIGGER KEYWORDS").font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.tertiary)
                            TextField("compress, zip, archive  (comma separated)", text: $triggerKeywords)
                                .textFieldStyle(.roundedBorder)
                            Text("The user types one of these in search to invoke this action")
                                .font(.caption2).foregroundStyle(.secondary)
                        }

                        Divider()

                        // Script type
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SCRIPT TYPE").font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.tertiary)
                            Picker("", selection: $scriptType) {
                                Text("Bash").tag(ILExtension.ScriptType.bash)
                                Text("Python").tag(ILExtension.ScriptType.python)
                                Text("AppleScript").tag(ILExtension.ScriptType.applescript)
                                Text("JavaScript").tag(ILExtension.ScriptType.javascript)
                                Text("Swift").tag(ILExtension.ScriptType.swift)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: scriptType) { _, new in
                                if scriptContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    scriptContent = Self.templates[new] ?? ""
                                }
                            }
                        }

                    }
                    .padding(16)
                }
                .frame(width: 340)
                .background(.background)

                Divider()

                // ── RIGHT: script editor ────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label(scriptFilename, systemImage: "terminal")
                            .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                        Spacer()
                        Text(scriptType.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.12), in: Capsule())
                            .foregroundStyle(.green)
                        Button(action: { scriptContent = Self.templates[scriptType] ?? "" }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("Reset to template")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.secondary.opacity(0.05))

                    Divider()

                    TextEditor(text: $scriptContent)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                }
                .frame(maxWidth: .infinity)
                .background(.background)
            }

            Divider()

            // ── Footer hint ──────────────────────────────────
            HStack(spacing: 20) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").foregroundStyle(.purple).font(.caption)
                    Text("Ask Claude: \"Write a bash Quick Action for ILauncher that [task]. Input files arrive as $1 $2 $3\"")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Selected files → $1 $2 $3 (bash) / sys.argv[1...] (python)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.secondary.opacity(0.04))
        }
        .frame(width: 900, height: 660)
        .onAppear {
            loadRunningApps()
            if let ext = existing {
                name = ext.name
                description = ext.description
                icon = ext.icon
                selectedLayer = ext.layer
                scriptType = ext.scriptType
                scriptContent = ext.scriptContent ?? Self.templates[ext.scriptType] ?? ""
                triggerKeywords = ext.triggers.compactMap { t -> String? in
                    if case .keyword(let kws) = t { return kws.joined(separator: ", ") }
                    return nil
                }.joined(separator: ", ")
                if case .appContext(let app) = ext.triggers.first(where: { if case .appContext = $0 { return true }; return false }) {
                    contextAppBundleId = app
                }
                if case .fileType(let types) = ext.triggers.first(where: { if case .fileType = $0 { return true }; return false }) {
                    fileTypeFilter = types.joined(separator: ", ")
                }
            } else {
                selectedLayer = defaultLayer
                contextAppBundleId = defaultAppContext
                scriptContent = Self.templates[.bash] ?? ""
            }
        }
    }

    // MARK: - Helpers

    private var scriptFilename: String {
        let ext: String
        switch scriptType {
        case .bash:        ext = "sh"
        case .python:      ext = "py"
        case .applescript: ext = "applescript"
        case .javascript:  ext = "js"
        case .swift:       ext = "swift"
        }
        let safeName = name.isEmpty ? "action" : name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return "\(safeName).\(ext)"
    }

    private func applyLayerDefaults() {
        // Pre-fill script template hint based on layer
        if scriptContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scriptContent = Self.templates[scriptType] ?? ""
        }
    }

    private func loadRunningApps() {
        // Start with currently running apps
        var seen = Set<String>()
        var apps: [(name: String, bundleId: String, icon: NSImage?)] = []

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let n = app.localizedName, let b = app.bundleIdentifier,
                  b != Bundle.main.bundleIdentifier, !seen.contains(b) else { continue }
            seen.insert(b)
            let ic = app.icon.map { i -> NSImage in
                let c = i.copy() as! NSImage; c.size = NSSize(width: 16, height: 16); return c
            }
            apps.append((name: n, bundleId: b, icon: ic))
        }

        // Also scan /Applications and ~/Applications for installed-but-not-running apps
        let scanDirs = [URL(fileURLWithPath: "/Applications"),
                        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Applications"))]
        let fm = FileManager.default
        for dir in scanDirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let bid = bundle.bundleIdentifier,
                      bid != Bundle.main.bundleIdentifier,
                      !seen.contains(bid) else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                seen.insert(bid)
                let ic = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
                ic?.size = NSSize(width: 16, height: 16)
                apps.append((name: name, bundleId: bid, icon: ic))
            }
        }

        runningApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#!/") || trimmed.hasPrefix("#!") {
            scriptContent = trimmed
        } else {
            scriptContent = trimmed
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        // Build triggers
        var triggers: [ExtensionTrigger] = []
        let kws = triggerKeywords.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !kws.isEmpty { triggers.append(.keyword(kws)) }
        if !contextAppBundleId.isEmpty { triggers.append(.appContext(contextAppBundleId)) }
        let fileTypes = fileTypeFilter.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !fileTypes.isEmpty { triggers.append(.fileType(fileTypes)) }
        if triggers.isEmpty { triggers.append(.always) }

        let ext = ILExtension(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            description: description,
            icon: icon,
            layer: selectedLayer,
            tags: existing?.tags ?? [],
            category: "custom",
            triggers: triggers,
            intents: existing?.intents ?? [],
            enabled: existing?.enabled ?? true,
            scriptPath: scriptFilename,
            scriptContent: scriptContent,
            scriptType: scriptType,
            requiresPermissions: [],
            requiresInternet: false,
            canChain: false,
            author: "me",
            version: existing?.version ?? "1.0",
            isBuiltIn: false,
            lastUsed: existing?.lastUsed,
            usageCount: existing?.usageCount ?? 0
        )

        if isEditing {
            extensionManager.updateExtension(ext)
        } else {
            extensionManager.addExtension(ext)
        }
        saveSuccess = true
        onSave?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let c = self.onClose { c() } else { self.dismiss() }
        }
    }
}

// MARK: - Icon Picker Popover

struct IconPickerPopover: View {
    @Binding var selected: String
    @State private var query = ""
    @Environment(\.dismiss) var dismiss

    private let icons: [String] = [
        "gear", "hammer", "wrench", "terminal", "doc.text", "folder", "archivebox",
        "photo", "photo.on.rectangle.angled", "camera", "video", "music.note",
        "globe", "link", "safari", "arrow.down.circle", "arrow.up.circle",
        "trash", "pencil", "scissors", "doc.on.clipboard", "doc.badge.plus",
        "magnifyingglass", "sparkles", "wand.and.stars", "bolt", "bolt.fill",
        "star", "heart", "tag", "bookmark", "flag", "bell",
        "lock", "key", "shield", "eye", "eye.slash",
        "arrow.triangle.2.circlepath", "arrow.clockwise", "arrow.counterclockwise",
        "play.circle", "pause.circle", "stop.circle", "forward.circle", "backward.circle",
        "chart.bar", "chart.pie", "list.bullet", "checklist", "calendar",
        "person", "person.2", "envelope", "phone", "message",
        "cpu", "memorychip", "network", "wifi", "antenna.radiowaves.left.and.right",
        "note.text", "doc.richtext", "textformat", "textformat.alt", "abc",
        "info.circle", "exclamationmark.triangle", "checkmark.circle", "xmark.circle",
        "square.and.arrow.up", "square.and.arrow.down", "icloud.and.arrow.up",
        "app.connected.to.app.below.fill", "puzzlepiece.extension", "gearshape.2",
        "paintbrush", "paintpalette", "eyedropper", "ruler", "crop",
        "brain", "lightbulb", "flame", "drop", "leaf", "snowflake"
    ]

    private var filtered: [String] {
        query.isEmpty ? icons : icons.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search icons...", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 7), spacing: 6) {
                    ForEach(filtered, id: \.self) { name in
                        Button(action: { selected = name; dismiss() }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selected == name ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.08))
                                    .frame(width: 34, height: 34)
                                Image(systemName: name)
                                    .font(.system(size: 15))
                                    .foregroundStyle(selected == name ? .blue : .primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .frame(height: 200)
        }
        .frame(width: 280)
    }
}

// Backward-compat aliases so existing callsites still compile
typealias AddExtensionView = QuickActionEditorView
struct EditExtensionView: View {
    let ext: ILExtension
    let extensionManager: LayeredExtensionManager
    var body: some View {
        QuickActionEditorView(extensionManager: extensionManager, existing: ext)
    }
}

#Preview {
    LayeredExtensionsSettingsView()
        .frame(width: 1200, height: 800)
}
