import AppKit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI

struct FolderPreviewView: View {
    let folderPath: String
    @Binding var isPresented: Bool
    @Binding var selectedFilePath: String?  // Expose selected file to parent
    @State private var currentFolderPath: String = ""
    @State private var folderHistory: [String] = []  // Stack of parent folders for back navigation
    @State private var folderItems: [FolderItem] = []
    @State private var isLoading = true
    @State private var folderName: String = ""
    @State private var folderIcon: NSImage?
    @State private var selectedItemIndex: Int? = nil
    @State private var quickLookDataSource: FolderQuickLookDataSource? = nil
    @StateObject private var keyboardHandler = FolderPreviewKeyboardHandler()
    @ObservedObject private var settings = AppSettings.shared

    // Window resize state
    @State private var windowWidth: CGFloat = 0  // Will be loaded from settings or default to screen size
    @State private var windowHeight: CGFloat = 0  // Will be loaded from settings or default to screen size
    @State private var isDraggingResize: Bool = false
    @State private var dragStartWidth: CGFloat = 0
    @State private var dragStartHeight: CGFloat = 0

    // Track selection source to prevent auto-scroll on mouse hover
    @State private var selectionByKeyboard: Bool = false

    // View options (will be loaded from settings in onAppear)
    @State private var viewMode: ViewMode = .list
    @State private var sortBy: SortOption = .name
    @State private var iconSize: IconSize = .medium

    enum ViewMode {
        case list, grid
    }

    enum SortOption {
        case name, date, size, kind
    }

    enum IconSize: CGFloat {
        case small = 24
        case medium = 32
        case large = 48
    }

    struct FolderItem: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let icon: NSImage
        let isDirectory: Bool
        let size: String
        let modifiedDate: String
        let sizeBytes: Int64  // Raw size for sorting
        let modifiedDateRaw: Date?  // Raw date for sorting
        let fileExtension: String  // For "Kind" sorting
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content (header removed)
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading folder contents...")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else if folderItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("This folder is empty")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)

                    if !folderHistory.isEmpty {
                        Button("Go Back") {
                            navigateBack()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        if viewMode == .grid {
                            // Grid View
                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 16)
                                ], spacing: 16
                            ) {
                                ForEach(Array(folderItems.enumerated()), id: \.element.id) {
                                    index, item in
                                    VStack(spacing: 8) {
                                        Image(nsImage: item.icon)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(
                                                width: iconSize.rawValue, height: iconSize.rawValue)

                                        Text(item.name)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .padding(8)
                                    .background(
                                        selectedItemIndex == index
                                            ? Color.accentColor.opacity(0.2) : Color.clear
                                    )
                                    .cornerRadius(8)
                                    .id(index)
                                    .onTapGesture(count: 2) {
                                        openItem(item)
                                    }
                                    .onTapGesture(count: 1) {
                                        selectedItemIndex = index
                                        selectionByKeyboard = false
                                        // Update parent's selected file context
                                        selectedFilePath = item.path
                                    }
                                    .contextMenu {
                                        Button {
                                            openItem(item)
                                        } label: {
                                            Label("Open", systemImage: "arrow.up.right.square")
                                        }
                                        if item.isDirectory {
                                            Button {
                                                navigateIntoFolder(item)
                                            } label: {
                                                Label("Enter Folder", systemImage: "folder")
                                            }
                                        }
                                        Button {
                                            quickLookItem(item)
                                        } label: {
                                            Label("Quick Look", systemImage: "eye")
                                        }
                                        Button {
                                            NSWorkspace.shared.selectFile(
                                                item.path, inFileViewerRootedAtPath: "")
                                        } label: {
                                            Label(
                                                "Show in Finder",
                                                systemImage: "folder.badge.questionmark")
                                        }
                                        Divider()
                                        Button {
                                            let pasteboard = NSPasteboard.general
                                            pasteboard.clearContents()
                                            pasteboard.setString(item.path, forType: .string)
                                        } label: {
                                            Label("Copy Path", systemImage: "doc.on.clipboard")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        } else {
                            // List View
                            LazyVStack(spacing: 0) {
                                ForEach(Array(folderItems.enumerated()), id: \.element.id) {
                                    index, item in
                                    FolderItemRow(
                                        item: item, isSelected: selectedItemIndex == index,
                                        iconSize: iconSize.rawValue
                                    )
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        openItem(item)
                                    }
                                    .onTapGesture(count: 1) {
                                        selectedItemIndex = index
                                        selectionByKeyboard = false
                                        // Update parent's selected file context
                                        selectedFilePath = item.path
                                    }
                                    .contextMenu {
                                        Button {
                                            openItem(item)
                                        } label: {
                                            Label("Open", systemImage: "arrow.up.right.square")
                                        }
                                        if item.isDirectory {
                                            Button {
                                                navigateIntoFolder(item)
                                            } label: {
                                                Label("Enter Folder", systemImage: "folder")
                                            }
                                        }
                                        Button {
                                            quickLookItem(item)
                                        } label: {
                                            Label("Quick Look", systemImage: "eye")
                                        }
                                        Button {
                                            NSWorkspace.shared.selectFile(
                                                item.path, inFileViewerRootedAtPath: "")
                                        } label: {
                                            Label(
                                                "Show in Finder",
                                                systemImage: "folder.badge.questionmark")
                                        }
                                        Divider()
                                        Button {
                                            let pasteboard = NSPasteboard.general
                                            pasteboard.clearContents()
                                            pasteboard.setString(item.path, forType: .string)
                                        } label: {
                                            Label("Copy Path", systemImage: "doc.on.clipboard")
                                        }
                                    }

                                    if index < folderItems.count - 1 {
                                        Divider()
                                            .padding(.leading, 60)
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: selectedItemIndex) { _, newIndex in
                        if selectionByKeyboard, let index = newIndex {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                    }
                }
            }

            // Footer - Liquid Glass Effect
            HStack(spacing: 12) {
                // Item count
                Text("\(folderItems.count) \(folderItems.count == 1 ? "item" : "items")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))

                Divider()
                    .frame(height: 16)
                    .overlay(Color.white.opacity(0.1))

                // View mode toggle (Grid/List)
                HStack(spacing: 4) {
                    Button(action: { viewMode = .list }) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(viewMode == .list ? .white : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("List View")

                    Button(action: { viewMode = .grid }) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(viewMode == .grid ? .white : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Grid View")
                }

                Divider()
                    .frame(height: 16)
                    .overlay(Color.white.opacity(0.1))

                // Sort options
                Menu {
                    Button(action: { sortBy = .name }) {
                        Label("Name", systemImage: sortBy == .name ? "checkmark" : "")
                    }
                    Button(action: { sortBy = .date }) {
                        Label("Date Modified", systemImage: sortBy == .date ? "checkmark" : "")
                    }
                    Button(action: { sortBy = .size }) {
                        Label("Size", systemImage: sortBy == .size ? "checkmark" : "")
                    }
                    Button(action: { sortBy = .kind }) {
                        Label("Kind", systemImage: sortBy == .kind ? "checkmark" : "")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                        Text("Sort")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
                .menuStyle(.borderlessButton)
                .help("Sort By")

                Divider()
                    .frame(height: 16)
                    .overlay(Color.white.opacity(0.1))

                // Icon size
                Menu {
                    Button(action: { iconSize = .small }) {
                        Label("Small", systemImage: iconSize == .small ? "checkmark" : "")
                    }
                    Button(action: { iconSize = .medium }) {
                        Label("Medium", systemImage: iconSize == .medium ? "checkmark" : "")
                    }
                    Button(action: { iconSize = .large }) {
                        Label("Large", systemImage: iconSize == .large ? "checkmark" : "")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.system(size: 12, weight: .medium))
                        Text("Icon")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
                .menuStyle(.borderlessButton)
                .help("Icon Size")

                Spacer()

                // Open in Finder button - Glassy style
                Button("Open in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: currentFolderPath))
                    closePreview()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.white.opacity(0.2))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    // Liquid glass base
                    Rectangle()
                        .fill(.thickMaterial)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.03),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Glassmorphism border
                    Rectangle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )

                    // Top highlight (liquid glass shine)
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.15),
                                        Color.clear,
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 1)
                        Spacer()
                    }
                }
            )
            .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: -2)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Handle dropped files
            handleDroppedFiles(providers: providers)
            return true
        }
        .onAppear {
            // Load saved preferences
            viewMode = settings.folderViewMode == "grid" ? .grid : .list
            switch settings.folderSortBy {
            case "date": sortBy = .date
            case "size": sortBy = .size
            case "kind": sortBy = .kind
            default: sortBy = .name
            }
            iconSize = IconSize(rawValue: settings.folderIconSize) ?? .medium

            currentFolderPath = folderPath
            loadFolderContents()
            setupKeyboardHandler()
        }
        .onChange(of: viewMode) { _, newValue in
            settings.folderViewMode = newValue == .grid ? "grid" : "list"
        }
        .onChange(of: sortBy) { _, newValue in
            let sortByString: String
            switch newValue {
            case .name: sortByString = "name"
            case .date: sortByString = "date"
            case .size: sortByString = "size"
            case .kind: sortByString = "kind"
            }
            settings.folderSortBy = sortByString
            // Reload contents with new sort
            loadFolderContents()
        }
        .onChange(of: iconSize) { _, newValue in
            settings.folderIconSize = newValue.rawValue
        }
        .onDisappear {
            keyboardHandler.stopMonitoring()
            // Dismiss Quick Look panel if it's open
            if let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.orderOut(nil)
            }
            quickLookDataSource = nil
        }
        .onChange(of: keyboardHandler.lastAction) { _, action in
            handleKeyboardAction(action)
        }
        .onReceive(NotificationCenter.default.publisher(for: .folderPreviewShouldClose)) { _ in
            // Handle escape key close via notification to break the synchronous call chain
            isPresented = false
        }
    }

    private func setupKeyboardHandler() {
        // Set up the close handler to bypass @Published timing issues
        // We'll use a notification instead of direct binding manipulation
        keyboardHandler.onCloseRequested = {
            // First dismiss Quick Look if open
            if let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.orderOut(nil)
            }

            // Post notification to close - this breaks the synchronous call chain
            NotificationCenter.default.post(name: .folderPreviewShouldClose, object: nil)
        }
        keyboardHandler.startMonitoring()
    }

    private func handleKeyboardAction(_ action: FolderPreviewKeyboardHandler.KeyAction?) {
        guard let action = action else { return }

        // Reset the action immediately to prevent re-triggering
        keyboardHandler.lastAction = nil

        switch action {
        case .navigateUp:
            navigateItems(direction: -1, horizontal: false)
        case .navigateDown:
            navigateItems(direction: 1, horizontal: false)
        case .navigateInto:
            // Right arrow behavior depends on view mode
            if viewMode == .grid {
                // In grid view: Right arrow navigates horizontally (next item to the right)
                navigateItems(direction: 1, horizontal: true)
            } else {
                // In list view: Right arrow enters subfolder
                if let index = selectedItemIndex, index < folderItems.count {
                    let item = folderItems[index]
                    if item.isDirectory {
                        navigateIntoFolder(item)
                    }
                }
            }
        case .navigateBack:
            // Left arrow behavior depends on view mode
            if viewMode == .grid {
                // In grid view: Left arrow navigates horizontally (previous item to the left)
                if let index = selectedItemIndex, index > 0 {
                    // Only navigate left if not at start, otherwise go back to parent
                    navigateItems(direction: -1, horizontal: true)
                } else if !folderHistory.isEmpty {
                    // At start of grid, go back to parent folder
                    navigateBack()
                }
            } else {
                // In list view: Left arrow always goes back to parent folder
                navigateBack()
            }
        case .open:
            // Enter key - behavior depends on view mode
            if let index = selectedItemIndex, index < folderItems.count {
                let item = folderItems[index]
                if viewMode == .grid && item.isDirectory {
                    // In grid view: Enter opens folders (navigates into them)
                    navigateIntoFolder(item)
                } else {
                    // In list view or for files: Enter opens the item
                    openItem(item)
                }
            }
        case .quickLook:
            print(
                "🔍 Quick Look action received (viewMode: \(viewMode), selectedIndex: \(String(describing: selectedItemIndex)))"
            )
            if let index = selectedItemIndex, index < folderItems.count {
                print("🔍 Calling quickLookItem for: \(folderItems[index].name)")
                quickLookItem(folderItems[index])
            } else {
                print(
                    "⚠️ Quick Look failed: no valid selection (selectedItemIndex: \(String(describing: selectedItemIndex)), items count: \(folderItems.count))"
                )
            }
        case .quickLookPrevious:
            // Navigate up and update Quick Look preview
            navigateItems(direction: -1)
            updateQuickLookPreview()
        case .quickLookNext:
            // Navigate down and update Quick Look preview
            navigateItems(direction: 1)
            updateQuickLookPreview()
        case .close:
            // This case is now handled by onCloseRequested closure
            closePreview()
        }
    }

    private func updateQuickLookPreview() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        guard let index = selectedItemIndex, index < folderItems.count else { return }

        let item = folderItems[index]
        let url = URL(fileURLWithPath: item.path)

        // Get the current window for restoring focus later
        let currentWindow = NSApp.windows.first(where: { $0.isVisible && $0 != panel })

        // Update the data source with the new file
        let dataSource = FolderQuickLookDataSource(urls: [url], folderPreviewWindow: currentWindow)
        quickLookDataSource = dataSource
        panel.dataSource = dataSource
        panel.delegate = dataSource

        // Reload to show the new file
        panel.reloadData()

        // Keep our window visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            currentWindow?.orderFront(nil)
        }
    }

    private func navigateIntoFolder(_ item: FolderItem) {
        guard item.isDirectory else { return }

        // Use asyncAfter to prevent constraint update crashes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            // Save current path to history
            self.folderHistory.append(self.currentFolderPath)

            // Update to new path
            self.currentFolderPath = item.path
            self.selectedItemIndex = nil

            // Reload contents
            self.loadFolderContents()
        }
    }

    private func navigateBack() {
        guard let previousPath = folderHistory.popLast() else { return }

        // Use asyncAfter to prevent constraint update crashes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            self.currentFolderPath = previousPath
            self.selectedItemIndex = nil

            // Reload contents
            self.loadFolderContents()
        }
    }

    private func handleDroppedFiles(providers: [NSItemProvider]) {
        print("📥 Files dropped into folder preview")

        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let sourceURL = url, error == nil else {
                    print(
                        "⚠️ Failed to load dropped file: \(error?.localizedDescription ?? "unknown error")"
                    )
                    return
                }

                // Move/copy file to current folder
                let fileName = sourceURL.lastPathComponent
                let destinationURL = URL(fileURLWithPath: self.currentFolderPath)
                    .appendingPathComponent(fileName)

                DispatchQueue.main.async {
                    do {
                        // Check if file already exists
                        if FileManager.default.fileExists(atPath: destinationURL.path) {
                            print("⚠️ File already exists: \(fileName)")
                            // Could show an alert here asking to replace
                            return
                        }

                        // Copy the file
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        print("✅ File copied: \(fileName) → \(self.currentFolderPath)")

                        // Reload folder contents to show the new file
                        self.loadFolderContents()
                    } catch {
                        print("❌ Failed to copy file: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func closePreview() {
        // Stop monitoring keyboard events first to prevent re-entry
        keyboardHandler.stopMonitoring()

        // Dismiss Quick Look panel first if it's open
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            quickLookDataSource = nil
        }

        // Use asyncAfter to ensure we're out of any layout pass
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                self.isPresented = false
            }
        }
    }

    private func quickLookItem(_ item: FolderItem) {
        let url = URL(fileURLWithPath: item.path)

        // Verify the file exists
        guard FileManager.default.fileExists(atPath: item.path) else {
            print("⚠️ File does not exist: \(item.path)")
            return
        }

        print("👁️ Quick Look preview for: \(item.path)")

        // Use asyncAfter to prevent constraint update crashes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            // Get or create the Quick Look panel
            guard let panel = QLPreviewPanel.shared() else {
                print("⚠️ Could not get Quick Look panel")
                return
            }

            // Get the current window for restoring focus later
            let currentWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })

            // Toggle Quick Look panel - if showing same file, close it
            if panel.isVisible {
                if let currentDataSource = self.quickLookDataSource,
                    currentDataSource.urls.first == url
                {
                    panel.orderOut(nil)
                    self.quickLookDataSource = nil
                    // Restore focus to our window
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        currentWindow?.makeKeyAndOrderFront(nil)
                    }
                    return
                }
            }

            // Create a new data source with window reference
            let dataSource = FolderQuickLookDataSource(
                urls: [url], folderPreviewWindow: currentWindow)
            self.quickLookDataSource = dataSource
            panel.dataSource = dataSource
            panel.delegate = dataSource

            // Configure panel to work better with our app
            panel.level = .floating  // Keep it above other windows

            // Reload and show
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)

            // Keep our window visible (don't let it hide behind)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                currentWindow?.orderFront(nil)
            }
        }
    }

    private func loadFolderContents() {
        isLoading = true

        // Capture the path and sort option to avoid race conditions
        let pathToLoad = currentFolderPath
        let currentSortBy = sortBy

        Task.detached(priority: .userInitiated) {
            // Get folder info - do this on background thread
            let url = URL(fileURLWithPath: pathToLoad)
            let name = url.lastPathComponent

            // Load folder contents
            let fileManager = FileManager.default

            // Check if path exists and is accessible (important for iCloud)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: pathToLoad, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                await MainActor.run {
                    // Use asyncAfter to break out of any constraint update cycle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.folderName = name
                        self.folderIcon = nil
                        self.folderItems = []
                        self.isLoading = false
                    }
                }
                return
            }

            // For iCloud folders, we need to handle potential delays
            // Try to get contents with a timeout approach
            let contents: [String]
            do {
                contents = try fileManager.contentsOfDirectory(atPath: pathToLoad)
            } catch {
                Swift.print("⚠️ Error reading folder contents: \(error)")
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.folderName = name
                        self.folderIcon = NSWorkspace.shared.icon(forFile: pathToLoad)
                        self.folderItems = []
                        self.isLoading = false
                    }
                }
                return
            }

            var items: [FolderItem] = []

            for item in contents.sorted(by: {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }) {
                // Skip hidden files
                guard !item.hasPrefix(".") else { continue }

                let itemPath = (pathToLoad as NSString).appendingPathComponent(item)

                var itemIsDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: itemPath, isDirectory: &itemIsDirectory)

                // Skip items that don't exist (might be iCloud placeholders that aren't downloaded)
                guard exists else { continue }

                // Get file attributes for sorting
                let attributes = try? fileManager.attributesOfItem(atPath: itemPath)

                // Get file size - be defensive about iCloud files
                let size: String
                let sizeBytes: Int64
                if itemIsDirectory.boolValue {
                    size = "Folder"
                    sizeBytes = 0
                } else {
                    if let fileSize = attributes?[.size] as? Int64 {
                        size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
                        sizeBytes = fileSize
                    } else {
                        size = "--"
                        sizeBytes = 0
                    }
                }

                // Get modification date - be defensive
                let modDate: String
                let modDateRaw: Date?
                if let date = attributes?[.modificationDate] as? Date {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .abbreviated
                    modDate = formatter.localizedString(for: date, relativeTo: Date())
                    modDateRaw = date
                } else {
                    modDate = "--"
                    modDateRaw = nil
                }

                // Get file extension for "Kind" sorting
                let fileExt = (itemPath as NSString).pathExtension.lowercased()

                // Get icon on main thread to avoid potential threading issues
                let itemIcon = NSWorkspace.shared.icon(forFile: itemPath)
                itemIcon.size = NSSize(width: 32, height: 32)

                items.append(
                    FolderItem(
                        name: item,
                        path: itemPath,
                        icon: itemIcon,
                        isDirectory: itemIsDirectory.boolValue,
                        size: size,
                        modifiedDate: modDate,
                        sizeBytes: sizeBytes,
                        modifiedDateRaw: modDateRaw,
                        fileExtension: fileExt
                    ))
            }

            // Sort: folders first, then by selected option
            let sortedItems = items.sorted { item1, item2 in
                // Always put folders before files
                if item1.isDirectory != item2.isDirectory {
                    return item1.isDirectory && !item2.isDirectory
                }

                // Within same type (folder or file), sort by selected option
                switch currentSortBy {
                case .name:
                    return item1.name.localizedCaseInsensitiveCompare(item2.name)
                        == .orderedAscending

                case .date:
                    // Sort by date (most recent first)
                    guard let date1 = item1.modifiedDateRaw, let date2 = item2.modifiedDateRaw
                    else {
                        return item1.name.localizedCaseInsensitiveCompare(item2.name)
                            == .orderedAscending
                    }
                    return date1 > date2  // Most recent first

                case .size:
                    // Sort by size (largest first)
                    if item1.sizeBytes != item2.sizeBytes {
                        return item1.sizeBytes > item2.sizeBytes
                    }
                    return item1.name.localizedCaseInsensitiveCompare(item2.name)
                        == .orderedAscending

                case .kind:
                    // Sort by file extension/kind
                    if item1.fileExtension != item2.fileExtension {
                        return item1.fileExtension.localizedCaseInsensitiveCompare(
                            item2.fileExtension) == .orderedAscending
                    }
                    return item1.name.localizedCaseInsensitiveCompare(item2.name)
                        == .orderedAscending
                }
            }

            // Get the icon on main thread
            let folderIconResult = NSWorkspace.shared.icon(forFile: pathToLoad)

            await MainActor.run {
                // Use asyncAfter to ensure we're not in the middle of a constraint update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // Verify we're still looking at the same folder (user might have navigated away)
                    guard self.currentFolderPath == pathToLoad else { return }

                    self.folderName = name
                    self.folderIcon = folderIconResult
                    self.folderItems = sortedItems
                    self.isLoading = false
                    if !sortedItems.isEmpty {
                        self.selectedItemIndex = 0
                        // Update parent's selected file context
                        self.selectedFilePath = sortedItems[0].path
                    }
                }
            }
        }
    }

    private func openItem(_ item: FolderItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        closePreview()
    }

    private func navigateItems(direction: Int, horizontal: Bool = false) {
        guard !folderItems.isEmpty else { return }

        // Mark as keyboard navigation to enable auto-scroll
        selectionByKeyboard = true

        if let currentIndex = selectedItemIndex {
            var newIndex: Int

            if viewMode == .grid && horizontal {
                // In grid view with horizontal navigation
                // Estimate columns based on grid width (100-150px per item + spacing)
                // For 700px width: ~4-5 columns
                let estimatedColumns = 5  // Average column count in grid

                if direction > 0 {
                    // Right arrow - move right
                    newIndex = currentIndex + 1
                } else {
                    // Left arrow - move left
                    newIndex = currentIndex - 1
                }
            } else if viewMode == .grid && !horizontal {
                // In grid view with vertical navigation (up/down)
                let estimatedColumns = 5

                if direction > 0 {
                    // Down arrow - move down one row
                    newIndex = currentIndex + estimatedColumns
                } else {
                    // Up arrow - move up one row
                    newIndex = currentIndex - estimatedColumns
                }
            } else {
                // List view - simple linear navigation
                newIndex = currentIndex + direction
            }

            // Clamp to valid range
            if newIndex >= 0 && newIndex < folderItems.count {
                selectedItemIndex = newIndex
                // Update parent's selected file context
                selectedFilePath = folderItems[newIndex].path
            }
        } else {
            let newIndex = direction > 0 ? 0 : folderItems.count - 1
            selectedItemIndex = newIndex
            // Update parent's selected file context
            selectedFilePath = folderItems[newIndex].path
        }
    }
}

// MARK: - Folder Quick Look Data Source
class FolderQuickLookDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let urls: [URL]
    weak var folderPreviewWindow: NSWindow?

    init(urls: [URL], folderPreviewWindow: NSWindow? = nil) {
        self.urls = urls
        self.folderPreviewWindow = folderPreviewWindow
        super.init()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0 && index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown {
            switch event.keyCode {
            case 53:  // Escape key - close Quick Look only
                panel.orderOut(nil)
                // Restore focus to the main window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let window = self.folderPreviewWindow
                        ?? NSApp.windows.first(where: { $0.isVisible && $0 != panel })
                    {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                return true
            case 49:  // Space - also close Quick Look (toggle behavior)
                panel.orderOut(nil)
                // Restore focus to the main window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let window = self.folderPreviewWindow
                        ?? NSApp.windows.first(where: { $0.isVisible && $0 != panel })
                    {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                return true
            default:
                break
            }
        }
        return false
    }

    // Keep the folder preview window visible when Quick Look opens
    func previewPanelDidBecomeKey(_ panel: QLPreviewPanel!) {
        // Don't let Quick Look hide our window
    }
}

// MARK: - Folder Preview Keyboard Handler
class FolderPreviewKeyboardHandler: ObservableObject {
    enum KeyAction {
        case navigateUp
        case navigateDown
        case navigateInto  // Right arrow - enter subfolder
        case navigateBack  // Left arrow - go to parent folder
        case open
        case close
        case quickLook
        case quickLookNext  // Navigate to next item while Quick Look is open
        case quickLookPrevious  // Navigate to previous item while Quick Look is open
    }

    @Published var lastAction: KeyAction? = nil
    @Published var isQuickLookActive: Bool = false
    private var monitor: Any? = nil
    private var isClosing: Bool = false  // Prevent multiple close attempts

    // Closure to call directly for close action (avoids @Published timing issues)
    var onCloseRequested: (() -> Void)?

    func startMonitoring() {
        // Remove any existing monitor first
        stopMonitoring()
        isClosing = false

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, !self.isClosing else { return event }

            let quickLookVisible = QLPreviewPanel.shared()?.isVisible ?? false

            // When Quick Look is visible, handle navigation differently
            if quickLookVisible {
                switch event.keyCode {
                case 126:  // Up arrow - navigate to previous item and update Quick Look
                    DispatchQueue.main.async {
                        self.lastAction = .quickLookPrevious
                    }
                    return nil
                case 125:  // Down arrow - navigate to next item and update Quick Look
                    DispatchQueue.main.async {
                        self.lastAction = .quickLookNext
                    }
                    return nil
                case 49:  // Space - close Quick Look
                    QLPreviewPanel.shared()?.orderOut(nil)
                    // Restore focus to main window
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if let window = NSApp.windows.first(where: {
                            $0.isVisible && $0 != QLPreviewPanel.shared()
                        }) {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                    return nil
                case 53:  // Escape - close Quick Look only
                    QLPreviewPanel.shared()?.orderOut(nil)
                    // Restore focus to main window
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if let window = NSApp.windows.first(where: {
                            $0.isVisible && $0 != QLPreviewPanel.shared()
                        }) {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                    return nil
                case 36:  // Return - open the file and close everything
                    DispatchQueue.main.async {
                        self.lastAction = .open
                    }
                    return nil
                default:
                    return event
                }
            }

            // Normal handling when Quick Look is not visible
            switch event.keyCode {
            case 126:  // Up arrow
                DispatchQueue.main.async {
                    self.lastAction = .navigateUp
                }
                return nil
            case 125:  // Down arrow
                DispatchQueue.main.async {
                    self.lastAction = .navigateDown
                }
                return nil
            case 124:  // Right arrow - navigate into subfolder
                DispatchQueue.main.async {
                    self.lastAction = .navigateInto
                }
                return nil
            case 123:  // Left arrow - go back to parent
                DispatchQueue.main.async {
                    self.lastAction = .navigateBack
                }
                return nil
            case 36:  // Return
                DispatchQueue.main.async {
                    self.lastAction = .open
                }
                return nil
            case 49:  // Space - Quick Look the selected item
                print("⌨️ Space key detected in folder preview")
                DispatchQueue.main.async {
                    print("⌨️ Setting lastAction to .quickLook")
                    self.lastAction = .quickLook
                }
                return nil
            case 53:  // Escape - Close the preview
                // Mark as closing to prevent re-entry
                self.isClosing = true
                // Stop monitoring immediately
                self.stopMonitoring()
                // Call the close handler directly with a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.onCloseRequested?()
                }
                return nil
            default:
                return event
            }
        }
    }

    func stopMonitoring() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        stopMonitoring()
    }
}

// MARK: - Keyboard Hint Badge
