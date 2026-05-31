import AppKit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI

// MARK: - Command Approval Window Host
/// Manages the standalone NSWindow used for command approval dialogs.
class CommandApprovalWindowHost: NSObject, NSWindowDelegate {
    static let shared = CommandApprovalWindowHost()
    static var window: NSWindow?

    static func close() {
        window?.close()
        window = nil
    }

    // Called when user clicks the red X button — treat as deny
    func windowWillClose(_ notification: Notification) {
        if TerminalAIBridge.shared.pendingApproval != nil {
            TerminalAIBridge.shared.denyCommand()
        }
        CommandApprovalWindowHost.window = nil
    }
}

final class AdapterApprovalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Adapter Approval Window Host
/// Manages the standalone NSPanel used for adapter action approval dialogs.
class AdapterApprovalWindowHost: NSObject, NSWindowDelegate {
    static let shared = AdapterApprovalWindowHost()
    static var window: NSPanel?

    var onClose: (() -> Void)?
    private var suppressDenyOnClose = false

    static func close() {
        shared.suppressDenyOnClose = true
        shared.onClose = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        let shouldDeny = !suppressDenyOnClose
        suppressDenyOnClose = false
        let onClose = onClose
        self.onClose = nil
        AdapterApprovalWindowHost.window = nil
        if shouldDeny {
            onClose?()
        }
    }
}

// MARK: - Quick Look Support
class QuickLookDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
        super.init()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown {
            if event.keyCode == 53 {  // Escape key
                panel.orderOut(nil)
                return true
            }
        }
        return false
    }
}

// ResultRow moved to ResultRow.swift

// MARK: - Folder Preview View
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
                print("⚠️ Error reading folder contents: \(error)")
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
struct KeyboardHintBadge: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: .tertiaryLabelColor).opacity(0.2))
                .cornerRadius(4)

            Text(action)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Contact Preview Card
struct ContactPreviewCard: View {
    let contact: SearchResult
    @Binding var isPresented: Bool
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        isPresented = false
                    }
                }

            // Contact card
            VStack(spacing: 0) {
                // Header with close button
                HStack {
                    Text(contact.title)
                        .font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Button(action: {
                        withAnimation {
                            isPresented = false
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // Contact details
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Profile section
                        VStack(spacing: 12) {
                            if let icon = contact.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 80)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.gray.opacity(0.2), lineWidth: 2))
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color.purple.opacity(0.6),
                                                    Color.blue.opacity(0.6),
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 80, height: 80)

                                    Text(getInitials())
                                        .font(.system(size: 32, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                            }

                            Text(contact.title)
                                .font(.system(size: 20, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                        Divider()

                        // All Emails
                        if let contactData = contact.contactData, !contactData.allEmails.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Email")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(contactData.allEmails, id: \.self) { email in
                                    ContactDetailRow(
                                        icon: "envelope.fill",
                                        label: "",
                                        value: email,
                                        action: {
                                            if let url = URL(string: "mailto:\(email)") {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                    )
                                }
                            }
                        }

                        // All Phones
                        if let contactData = contact.contactData, !contactData.allPhones.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Phone")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(contactData.allPhones, id: \.self) { phone in
                                    ContactDetailRow(
                                        icon: "phone.fill",
                                        label: "",
                                        value: phone,
                                        action: {
                                            if let url = URL(string: "tel:\(phone)") {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                    )
                                }
                            }
                        }

                        Divider()

                        // Action buttons
                        HStack(spacing: 12) {
                            if let contactData = contact.contactData {
                                if !contactData.primaryEmail.isEmpty {
                                    Button(action: {
                                        if let url = URL(
                                            string: "mailto:\(contactData.primaryEmail)")
                                        {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }) {
                                        Label("Email", systemImage: "envelope.fill")
                                    }
                                    .buttonStyle(.bordered)

                                    Button(action: {
                                        if let url = URL(
                                            string: "imessage:\(contactData.primaryEmail)")
                                        {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }) {
                                        Label("Message", systemImage: "message.fill")
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if !contactData.primaryPhone.isEmpty {
                                    Button(action: {
                                        if let url = URL(string: "tel:\(contactData.primaryPhone)")
                                        {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }) {
                                        Label("Call", systemImage: "phone.fill")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }

                            Spacer()

                            Button(action: {
                                contact.action()  // Opens in Contacts.app
                            }) {
                                Label("Open", systemImage: "person.crop.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 8)
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(width: 450, height: 500)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 15)
            .opacity(settings.folderPreviewOpacity)
        }
        .onKeyPress(.escape) {
            withAnimation {
                isPresented = false
            }
            return .handled
        }
    }

    private func getInitials() -> String {
        let components = contact.title.components(separatedBy: " ")
        if components.count >= 2 {
            let first = components[0].prefix(1)
            let last = components[components.count - 1].prefix(1)
            return "\(first)\(last)".uppercased()
        } else if let first = components.first?.prefix(1) {
            return first.uppercased()
        }
        return "?"
    }
}

struct ContactDetailRow: View {
    let icon: String
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.lowercase)

            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Text(value)
                    .font(.system(size: 14))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .contentShape(Rectangle())
            .onTapGesture {
                action()
            }
        }
    }
}

// MARK: - Contact Quick Action Button
// ContactQuickActionButton moved to ResultRow.swift

// MARK: - Resize Handle Component
struct ResizeHandle: View {
    @Binding var isDragging: Bool
    @State private var isHovering: Bool = false

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(isHovering || isDragging ? 0.2 : 0.1), radius: 4)

            // Resize icon (diagonal arrows)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering || isDragging ? .primary : .secondary)
                .rotationEffect(.degrees(90))
        }
        .padding(12)
        .opacity(isDragging ? 1.0 : (isHovering ? 0.9 : 0.6))
        .scaleEffect(isDragging ? 1.15 : (isHovering ? 1.05 : 1.0))
        .animation(.easeInOut(duration: 0.15), value: isDragging)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else if !isDragging {
                NSCursor.pop()
            }
        }
        .help("Drag to resize • 75% of screen by default")
    }
}

// MARK: - Folder Item Row
struct FolderItemRow: View {
    let item: FolderPreviewView.FolderItem
    let isSelected: Bool
    var iconSize: CGFloat = 32

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: iconSize, height: iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(item.size)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Text(item.modifiedDate)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

// MARK: - AI Chat Models
/// Spotlight-style context: set when user presses Tab/→ on any search result
struct SearchContextApp {
    let name: String
    let icon: NSImage?
    let key: String?  // customAppEntries key (apps with assigned tools)
    let appPath: String  // .app path (empty for non-apps)
    let resultType: SearchResult.ResultType  // type of item (app, file, folder, contact, etc.)
    let filePath: String?  // full path for files/folders
    let subtitle: String  // subtitle from result row (path, email, etc.)
    let contactEmail: String?  // for contacts
    let contactPhone: String?  // for contacts

    /// Human-readable description for the AI system prompt
    var aiContextDescription: String {
        switch resultType {
        case .application: return "the app \(name) (\(appPath))"
        case .file, .document: return "the file \(name) at \(filePath ?? subtitle)"
        case .folder: return "the folder \(name) at \(filePath ?? subtitle)"
        case .contact: return "the contact \(name)\(contactEmail.map { " (\($0))" } ?? "")"
        case .calendarEvent: return "the calendar event \(name)"
        case .reminder: return "the reminder \(name)"
        case .note: return "the note \(name)"
        case .mail: return "the email \(name)"
        case .shortcut: return "the shortcut \(name)"
        case .cliTool: return "the CLI tool '\(name)' installed at \(filePath ?? appPath)"
        default: return "\(name)"
        }
    }
}

struct AIChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    let content: String
    let timestamp: Date
    var isError: Bool
    var structuredData: String?  // JSON data from extensions
    var hasInstallButton: Bool  // Show "Add to Extensions" button

    enum ChatRole {
        case user
        case assistant
        case tool  // terminal command chip (shown while running)
        case approval  // inline approve/deny card (replaces popup window)
    }

    init(
        role: ChatRole, content: String, isError: Bool = false, structuredData: String? = nil,
        hasInstallButton: Bool = false
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isError = isError
        self.structuredData = structuredData
        self.hasInstallButton = hasInstallButton
    }

    /// Streaming update — preserves the original UUID so the message can be updated in-place.
    init(
        id: UUID, role: ChatRole, content: String, isError: Bool = false,
        structuredData: String? = nil, hasInstallButton: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isError = isError
        self.structuredData = structuredData
        self.hasInstallButton = hasInstallButton
    }

    static func == (lhs: AIChatMessage, rhs: AIChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Extension Proposal

struct ExtensionProposalData: Codable {
    var type: String
    var name: String
    var description: String
    var scriptType: String  // "applescript" | "bash" | "jxa"
    var script: String
    var layer: String
    var triggers: [TriggerSpec]
    var icon: String?

    struct TriggerSpec: Codable {
        var type: String
        var value: String
    }

    static let markerStart = "<<EXTENSION_PROPOSAL>>"
    static let markerEnd = "<<END_PROPOSAL>>"

    static func parse(from text: String) -> ExtensionProposalData? {
        guard let s = text.range(of: markerStart),
            let e = text.range(of: markerEnd),
            s.upperBound < e.lowerBound
        else { return nil }
        var json = String(text[s.upperBound..<e.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        }
        if json.hasSuffix("```") {
            json = String(json.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExtensionProposalData.self, from: data)
    }

    /// Remove the proposal block from the AI response text for display.
    static func cleanResponse(_ text: String) -> String {
        guard let s = text.range(of: markerStart),
            let e = text.range(of: markerEnd),
            e.upperBound <= text.endIndex
        else { return text }
        var result = text
        result.removeSubrange(s.lowerBound...e.upperBound)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func asJSON() -> String? {
        guard let d = try? JSONEncoder().encode(self) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

enum AIError: LocalizedError {
    case noAPIKey
    case noEndpoint
    case noModel
    case requestFailed
    case invalidResponse
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured. Please add your API key in Settings."
        case .noEndpoint:
            return "No endpoint configured. Please configure the endpoint in Settings."
        case .noModel: return "No model selected. Please select a model in Settings."
        case .requestFailed: return "Request failed. Please check your connection and try again."
        case .invalidResponse: return "Invalid response from AI provider."
        case .rateLimited:
            return
                "Gemini free tier quota exceeded. Wait 1–2 minutes and try again, or switch to a different AI provider in Settings."
        }
    }
}

// MARK: - AI Chat Message View
struct AIChatMessageView: View {
    let message: AIChatMessage
    var isStreaming: Bool = false
    var onInstallExtension: (() -> Void)? = nil
    var onInstallProposal: ((String) -> Void)? = nil
    var onRunOnceProposal: ((String) -> Void)? = nil
    @ObservedObject private var settings = AppSettings.shared

    private var providerColor: SwiftUI.Color {
        switch settings.selectedAIProvider {
        case .onDevice: return .purple
        case .googleGemini: return .blue
        case .openAI: return .green
        case .anthropic: return .orange
        case .ollama: return .cyan
        case .shortcuts: return .indigo
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 52) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
                // Detect extension proposal in structuredData
                if let sd = message.structuredData, message.role == .assistant,
                    let data = sd.data(using: .utf8),
                    let proposal = try? JSONDecoder().decode(
                        ExtensionProposalData.self, from: data),
                    proposal.type == "extension_proposal"
                {
                    ExtensionProposalCard(
                        message: message,
                        proposal: proposal,
                        onRunOnce: onRunOnceProposal.map { cb in { cb(sd) } },
                        onAdd: onInstallProposal.map { cb in { cb(sd) } }
                    )
                } else if let structuredData = message.structuredData, message.role == .assistant {
                    VStack(alignment: .leading, spacing: 8) {
                        if !message.content.isEmpty {
                            MarkdownMessageView(content: message.content, isError: message.isError)
                        }
                        AIResultViewer(jsonString: structuredData)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background { pillBubble(bright: false) }
                } else {
                    HStack(alignment: .bottom, spacing: 4) {
                        MarkdownMessageView(
                            content: message.content.isEmpty && isStreaming ? "" : message.content,
                            isError: message.isError
                        )
                        if isStreaming {
                            Rectangle()
                                .fill(providerColor)
                                .frame(width: 2, height: 14)
                                .animation(
                                    .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                                    value: isStreaming)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        if message.role == .user {
                            Color.accentColor
                        } else {
                            Color.primary.opacity(message.isError ? 0.04 : 0.08)
                        }
                    }
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if message.hasInstallButton, message.structuredData == nil,
                    let onInstall = onInstallExtension
                {
                    Button(action: onInstall) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add to Extensions").fontWeight(.medium)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            Capsule().fill(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .leading, endPoint: .trailing))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if message.role == .assistant { Spacer(minLength: 52) }
        }
    }

    @ViewBuilder private func pillBubble(bright: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(bright ? 0.28 : 0.12),
                            .white.opacity(bright ? 0.06 : 0.02),
                        ],
                        startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(bright ? 0.65 : 0.32), .white.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: bright ? 1.5 : 0.75)
            if bright {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                    .blur(radius: 3)
            }
        }
    }
}

// MARK: - Extension Proposal Card

struct ExtensionProposalCard: View {
    let message: AIChatMessage
    let proposal: ExtensionProposalData
    var onRunOnce: (() -> Void)? = nil
    var onAdd: (() -> Void)? = nil

    @State private var expanded = false

    private var scriptPreview: String {
        let lines = proposal.script.components(separatedBy: "\n")
        let preview = lines.prefix(12).joined(separator: "\n")
        return lines.count > 12 ? preview + "\n…" : preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Text response (above the card)
            if !message.content.isEmpty {
                MarkdownMessageView(content: message.content, isError: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.bottom, 8)
            }

            // Proposal card
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: proposal.icon ?? "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(proposal.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(proposal.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // Script type badge
                    Text(proposal.scriptType.lowercased() == "applescript" ? "AppleScript" : "bash")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    // Expand/collapse chevron
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            expanded.toggle()
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                // Script preview (expandable)
                if expanded {
                    Divider().opacity(0.2)
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(scriptPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 180)
                    .background(Color.black.opacity(0.25))
                }

                Divider().opacity(0.2)

                // Action buttons
                HStack(spacing: 8) {
                    if let run = onRunOnce {
                        Button(action: run) {
                            HStack(spacing: 5) {
                                Image(systemName: "play.fill")
                                Text("Run Once")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if let add = onAdd {
                        Button(action: add) {
                            HStack(spacing: 5) {
                                Image(systemName: "plus.circle.fill")
                                Text("Save as Extension")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading, endPoint: .trailing))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.blue.opacity(0.5), .purple.opacity(0.3)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.75)
            )
        }
    }
}

// MARK: - Tool Selection Inline View
struct ToolSelectionInlineView: View {
    let pending: L2AITaskExecutor.PendingToolChoice
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a tool")
                .font(.headline)
            Text(pending.stepDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(pending.tools, id: \.self) { tool in
                Button {
                    onSelect(tool)
                } label: {
                    HStack {
                        Text(tool)
                            .font(.body)
                        Spacer()
                        if !L2AITaskExecutor.TerminalTool.isInstalled(tool) {
                            Text("Install")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.08))
                )
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - AI Loading View
struct AILoadingView: View {
    @State private var animationOffset: CGFloat = 0
    @ObservedObject private var settings = AppSettings.shared

    private var providerColor: SwiftUI.Color {
        switch settings.selectedAIProvider {
        case .onDevice: return .purple
        case .googleGemini: return .blue
        case .openAI: return .green
        case .anthropic: return .orange
        case .ollama: return .cyan
        case .shortcuts: return .indigo
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // AI Avatar - uses provider icon
            Image(systemName: settings.selectedAIProvider.iconName)
                .font(.system(size: 16))
                .foregroundStyle(providerColor)
                .frame(width: 28, height: 28)
                .background(providerColor.opacity(0.1))
                .clipShape(Circle())

            // Loading indicator
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(providerColor.opacity(0.6))
                        .frame(width: 8, height: 8)
                        .offset(y: animationOffset)
                        .animation(
                            Animation.easeInOut(duration: 0.5)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                            value: animationOffset
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
            .onAppear {
                animationOffset = -5
            }

            Spacer(minLength: 40)
        }
    }
}

/// MARK: - Adapter Action Approval Popup

struct AdapterApprovalPopupView: View {
    let request: AdapterActionRequest
    @State private var isHoveringAllow = false
    @State private var isHoveringDeny = false

    private var typeLabel: String {
        switch request.action.type {
        case .menubar: return "Menu Bar: \(request.action.menuPath?.joined(separator: " › ") ?? "")"
        case .applescript: return "AppleScript"
        case .jxa: return "JXA Script"
        case .shell: return "Shell Command"
        case .cliTool: return "CLI Tool: \(request.action.cliToolCommand ?? "")"
        case .urlScheme: return "Open URL: \(request.action.urlScheme ?? "")"
        case .openItem:
            return "Open File / App: \(request.action.scriptFile ?? request.action.script ?? "")"
        case .scriptFile:
            return "Script File: \(request.action.scriptFile ?? request.action.script ?? "")"
        case .shortcut: return "Shortcut: \(request.action.shortcutName ?? "")"
        case .aiPrompt: return "AI Prompt"
        case .pageJS: return "Page JavaScript"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(
                    systemName: request.action.isDestructive
                        ? "exclamationmark.triangle.fill" : "app.connected.to.app.below.fill"
                )
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(request.action.isDestructive ? .red : .accentColor)
                .frame(width: 36, height: 36)
                .background(
                    (request.action.isDestructive ? Color.red : Color.accentColor).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("ILauncher wants to:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(request.action.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 8) {
                approvalDetailRow(icon: "app.badge.fill", text: "App: \(request.adapter.appName)")
                approvalDetailRow(icon: "gearshape", text: typeLabel)
                if !request.action.description.isEmpty {
                    Text(request.action.description)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.88))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.45)

            HStack(spacing: 10) {
                Button {
                    request.onDeny()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            isHoveringDeny
                                ? Color.primary.opacity(0.13) : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringDeny = $0 }

                Button {
                    request.onApprove()
                } label: {
                    Text("Allow")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            request.action.isDestructive
                                ? (isHoveringAllow
                                    ? Color.red.opacity(0.88) : Color.red.opacity(0.78))
                                : (isHoveringAllow
                                    ? Color.accentColor.opacity(0.92)
                                    : Color.accentColor.opacity(0.8)),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringAllow = $0 }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .frame(width: 460)
        .background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    request.action.isDestructive
                        ? Color.red.opacity(0.38) : Color.white.opacity(0.14),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 12)
        .padding(12)
    }

    private func approvalDetailRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - L2 Extension Chip Button
struct L2ExtensionChipButton: View {
    let extensionResult: ExtensionDiscoveryResult
    let currentContext: UserContext
    let onExecute: (ILExtension, UserContext) async -> Void

    @State private var isHovered = false
    @State private var isExecuting = false

    private var chipColor: SwiftUI.Color {
        switch extensionResult.relevanceScore {
        case 0.5...:
            return .blue
        case 0.3..<0.5:
            return .green
        default:
            return .gray
        }
    }

    var body: some View {
        Button(action: {
            Task {
                isExecuting = true
                await onExecute(extensionResult.ilExtension, currentContext)
                isExecuting = false
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: extensionResult.ilExtension.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(chipColor)

                Text(extensionResult.ilExtension.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isHovered ? chipColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(chipColor.opacity(isHovered ? 0.8 : 0.3), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - AI Extension Chip Button
struct AIExtensionChipButton: View {
    let suggestion: SuggestedExtension
    let context: UserContext
    @Binding var chatMessages: [AIChatMessage]

    @State private var isHovered = false
    @State private var isExecuting = false

    private var chipColor: SwiftUI.Color {
        switch suggestion.relevanceScore {
        case 90...:
            return .green
        case 70..<90:
            return .blue
        default:
            return .orange
        }
    }

    var body: some View {
        Button(action: {
            executeExtension()
        }) {
            HStack(spacing: 6) {
                // Icon
                Image(systemName: suggestion.scriptExtension.type.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(chipColor)

                // Title
                Text(suggestion.scriptExtension.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Loading indicator
                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }

                // Star for high relevance
                if suggestion.relevanceScore >= 90 {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isHovered ? chipColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(chipColor.opacity(isHovered ? 0.8 : 0.3), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(suggestion.reason)
    }

    private func executeExtension() {
        isExecuting = true

        // Add user action message to chat
        let actionMessage = AIChatMessage(
            role: .user,
            content: "Run \(suggestion.scriptExtension.displayName)"
        )
        chatMessages.append(actionMessage)

        Task {
            do {
                let input = getInputFromContext()
                print("🔧 [Extension] Executing: \(suggestion.scriptExtension.displayName)")
                print("🔧 [Extension] Input: \(input.prefix(100))...")

                let result = try await suggestion.scriptExtension.execute(with: input)

                print("✅ [Extension] Result: \(result.prefix(200))...")

                await MainActor.run {
                    isExecuting = false

                    // Add result to chat
                    let resultMessage = AIChatMessage(
                        role: .assistant,
                        content: result.isEmpty ? "✅ Completed successfully" : result,
                        isError: false
                    )
                    chatMessages.append(resultMessage)
                }
            } catch {
                print("❌ [Extension] Error: \(error.localizedDescription)")

                await MainActor.run {
                    isExecuting = false

                    // Add error to chat
                    let errorMessage = AIChatMessage(
                        role: .assistant,
                        content: "❌ Error: \(error.localizedDescription)",
                        isError: true
                    )
                    chatMessages.append(errorMessage)
                }
            }
        }
    }

    private func getInputFromContext() -> String {
        switch context {
        case .filesSelected(let urls):
            return urls.map { $0.path }.joined(separator: "\n")
        case .textSelected(let text):
            return text
        case .url(let urlString):
            return urlString
        case .appFocused(let name, _):
            return name
        case .contactSelected(let contact):
            return contact
        case .none:
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
    }
}

// MARK: - Markdown Message View
struct MarkdownMessageView: View {
    let content: String
    let isError: Bool

    @State private var parsedBlocks: [MessageBlock] = []

    struct MessageBlock: Identifiable {
        let id = UUID()
        enum Kind {
            case text(String)
            case codeBlock(code: String, language: String?)
        }
        let kind: Kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parsedBlocks) { block in
                switch block.kind {
                case .text(let text):
                    if #available(macOS 12.0, *) {
                        Text(attributedMarkdown(text))
                            .font(.system(size: 13))
                            .foregroundStyle(isError ? .red : .primary)
                            .textSelection(.enabled)
                            .environment(
                                \.openURL,
                                OpenURLAction { url in
                                    NSWorkspace.shared.open(url)
                                    return .handled
                                })
                    } else {
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(isError ? .red : .primary)
                            .textSelection(.enabled)
                    }

                case .codeBlock(let code, let language):
                    CodeBlockView(code: code, language: language)
                }
            }
        }
        .onAppear {
            parsedBlocks = parseContent(content)
        }
        .onChange(of: content) { _, newContent in
            parsedBlocks = parseContent(newContent)
        }
    }

    private func parseContent(_ src: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []

        let pattern = "```([a-zA-Z]*)\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [MessageBlock(kind: .text(src))]
        }

        let range = NSRange(src.startIndex..., in: src)
        var lastIndex = src.startIndex

        regex.enumerateMatches(in: src, range: range) { match, _, _ in
            guard let match = match,
                let matchRange = Range(match.range, in: src)
            else { return }

            let pre = String(src[lastIndex..<matchRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pre.isEmpty { blocks.append(MessageBlock(kind: .text(pre))) }

            if match.numberOfRanges >= 3,
                let langRange = Range(match.range(at: 1), in: src),
                let codeRange = Range(match.range(at: 2), in: src)
            {
                let language = String(src[langRange])
                let code = String(src[codeRange])
                blocks.append(
                    MessageBlock(
                        kind: .codeBlock(
                            code: code, language: language.isEmpty ? nil : language)))
            }

            lastIndex = matchRange.upperBound
        }

        let tail = String(src[lastIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { blocks.append(MessageBlock(kind: .text(tail))) }

        return blocks.isEmpty ? [MessageBlock(kind: .text(src))] : blocks
    }

    @available(macOS 12.0, *)
    private func attributedMarkdown(_ text: String) -> AttributedString {
        do {
            var attributed = try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )

            return attributed
        } catch {
            return AttributedString(text)
        }
    }
}

// MARK: - Code Block View
struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var copied = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language, save, and copy buttons
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Save to Extensions button
                Button(action: saveToExtensions) {
                    HStack(spacing: 4) {
                        Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .font(.system(size: 11))
                        Text(saved ? "Saved" : "Save")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(saved ? .green : .blue)
                }
                .buttonStyle(.plain)
                .help("Save to Extensions folder")

                // Copy button
                Button(action: copyCode) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.05))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color.black.opacity(0.02))
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }

    private func saveToExtensions() {
        Task {
            do {
                // Extract extension metadata from code
                let extensionName = extractExtensionName(from: code)
                let layer = extractExtensionLayer(from: code)
                let activeAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
                await MainActor.run {
                    let scriptType = determineExtensionScriptType(from: code, language: language)
                    let category = inferExtensionCategory(layer: layer, appName: activeAppName)
                    let triggers = buildExtensionTriggers(layer: layer, appName: activeAppName)
                    let ext = ILExtension(
                        name: extensionName,
                        description: "Saved from AI",
                        icon: "sparkles",
                        layer: layer.contains("l1")
                            ? .l1_search : (layer.contains("l3") ? .l3_browser : .l2_context),
                        tags: [.automation],
                        category: category,
                        triggers: triggers,
                        scriptPath: "",
                        scriptContent: code,
                        scriptType: scriptType,
                        isBuiltIn: false
                    )

                    LayeredExtensionManager.shared.addExtension(ext)
                    saved = true

                    // Reset after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saved = false
                    }
                }

                print("✅ Saved extension to Documents/ILauncher/Extensions")

            } catch {
                print("❌ Failed to save extension: \(error.localizedDescription)")
            }
        }
    }

    private func extractExtensionName(from code: String) -> String {
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Extension:") {
                return line.replacingOccurrences(of: "# Extension:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "extension_\(Int(Date().timeIntervalSince1970))"
    }

    private func extractExtensionLayer(from code: String) -> String {
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("# Layer:") {
                return line.replacingOccurrences(of: "# Layer:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "l2_context"
    }

    private func determineExtensionScriptType(from code: String, language: String? = nil)
        -> ILExtension.ScriptType
    {
        if code.hasPrefix("#!/bin/bash") || code.hasPrefix("#!/usr/bin/env bash")
            || code.hasPrefix("#!/bin/sh") || language == "bash" || language == "sh"
        {
            return .bash
        }
        if code.hasPrefix("#!/usr/bin/env python") || code.hasPrefix("#!/usr/bin/python")
            || language == "python"
        {
            return .python
        }
        if code.hasPrefix("#!/usr/bin/osascript") || language == "applescript" {
            return .applescript
        }
        return .bash
    }

    private func inferExtensionCategory(layer: String, appName: String) -> String {
        let normalized = appName.lowercased()
        if layer.contains("l2") {
            if normalized.contains("safari") || normalized.contains("chrome")
                || normalized.contains("arc")
            {
                return "browser"
            }
            if normalized.contains("finder") {
                return "finder"
            }
            if normalized.contains("mail") {
                return "mail"
            }
            if normalized.contains("notes") || normalized.contains("textedit") {
                return "text-editor"
            }
            if normalized.contains("xcode") || normalized.contains("vscode") {
                return "code-editor"
            }
        }
        if layer.contains("l3") {
            return "page-enhancers"
        }
        return "custom"
    }

    private func buildExtensionTriggers(layer: String, appName: String) -> [ExtensionTrigger] {
        if layer.contains("l2"), !appName.isEmpty {
            return [.appContext(appName)]
        }
        return [.always]
    }
}

// MARK: - Notification Dock View

struct NotificationDockView: View {
    @ObservedObject private var manager = ILauncherNotificationManager.shared
    @ObservedObject private var appSettings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selectedTab: Int  // 0 = Alerts, 1 = Settings
    let profileImage: NSImage?
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            // Tab bar
            HStack(spacing: 0) {
                tabButton(title: "Alerts", icon: "bell.fill", tag: 0)
                tabButton(title: "Settings", icon: "gearshape.fill", tag: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.08))
                    .frame(height: 0.5)
            }

            if selectedTab == 1 {
                notificationSettings
            } else if visibleNotifications.isEmpty {
                emptyState
                    .padding(.horizontal, 18)
                    .padding(.vertical, 22)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleNotifications) { notification in
                            notificationCard(notification)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 320)
            }
        }
        .glassContainer(cornerRadius: 20)
    }

    @ViewBuilder
    private func tabButton(title: String, icon: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tag }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(selectedTab == tag ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedTab == tag ? Color.primary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var notificationSettings: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                settingsSection("In-App Notifications") {
                    settingsToggle(
                        icon: "bell.fill", iconColor: .blue,
                        title: "Action Completed",
                        subtitle: "Show when a dock action finishes",
                        binding: $appSettings.notifyOnActionCompleted
                    )
                    Divider().padding(.leading, 44)
                    settingsToggle(
                        icon: "exclamationmark.triangle.fill", iconColor: .orange,
                        title: "Action Failed",
                        subtitle: "Show when an action encounters an error",
                        binding: $appSettings.notifyOnActionFailed
                    )
                    Divider().padding(.leading, 44)
                    settingsToggle(
                        icon: "sparkles", iconColor: .purple,
                        title: "AI Response",
                        subtitle: "Show when AI finishes a long task",
                        binding: $appSettings.notifyOnAIResponse
                    )
                }

                settingsSection("System Banners") {
                    settingsToggle(
                        icon: "app.badge.fill", iconColor: .red,
                        title: "System Banners",
                        subtitle: "Also send macOS banners for alerts",
                        binding: $appSettings.notifySystemBanners
                    )
                }

                // Open full settings button
                Button {
                    onClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onOpenSettings() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                        Text("Open Full Settings")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
        }
        .frame(maxHeight: 320)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                content()
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func settingsToggle(
        icon: String, iconColor: SwiftUI.Color,
        title: String, subtitle: String,
        binding: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(iconColor.opacity(0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var visibleNotifications: [ILauncherNotification] {
        Array(manager.notifications.prefix(10))
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Notifications")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.primary)
                        if !visibleNotifications.isEmpty {
                            Text("(\(visibleNotifications.count))")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(headerSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button {
                    onClose()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onOpenSettings() }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(width: 34, height: 34)
                        .background(toolbarButtonBackground)
                }
                .buttonStyle(.plain)
                .help("Notification Settings")

                Group {
                    if let profileImage {
                        Image(nsImage: profileImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(
                            Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28), lineWidth: 1)
                )
            }

            if !visibleNotifications.isEmpty {
                HStack(spacing: 8) {
                    if manager.unreadCount > 0 {
                        headerActionButton(
                            title: "Mark All Read",
                            systemImage: "checkmark.circle"
                        ) {
                            manager.markAllRead()
                        }
                    }

                    headerActionButton(
                        title: "Clear",
                        systemImage: "trash"
                    ) {
                        manager.clearAll()
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.12))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(cardFill)
                    .frame(width: 58, height: 58)
                Image(systemName: "bell.slash")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("No notifications")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)

            Text("New alerts and completed actions will appear here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            headerActionButton(
                title: "Open Settings",
                systemImage: "gearshape"
            ) {
                onClose()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onOpenSettings() }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func notificationCard(_ notification: ILauncherNotification) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            accentColor(notification.accentColor).opacity(
                                colorScheme == .dark ? 0.18 : 0.12)
                        )
                        .frame(width: 44, height: 44)
                    Image(systemName: notification.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accentColor(notification.accentColor))
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(notification.title)
                            .font(
                                .system(size: 17, weight: notification.isRead ? .medium : .semibold)
                            )
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Spacer(minLength: 8)

                        Text(notification.date, style: .relative)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }

                    Text(notification.body)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }

            HStack(spacing: 8) {
                if notification.action != nil {
                    cardActionButton(
                        title: "Open",
                        prominence: .primary
                    ) {
                        manager.tap(notification.id)
                        onClose()
                    }
                } else if !notification.isRead {
                    cardActionButton(
                        title: "Mark Read",
                        prominence: .secondary
                    ) {
                        manager.markRead(notification.id)
                    }
                }

                cardActionButton(
                    title: "Remove",
                    prominence: .secondary
                ) {
                    manager.remove(notification.id)
                }

                Spacer(minLength: 0)

                if !notification.isRead {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(accentColor(notification.accentColor))
                            .frame(width: 6, height: 6)
                        Text("New")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(cardStroke, lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu {
            if !notification.isRead {
                Button {
                    manager.markRead(notification.id)
                } label: {
                    Label("Mark as Read", systemImage: "checkmark.circle")
                }
            }
            if notification.action != nil {
                Button {
                    manager.tap(notification.id)
                    onClose()
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
            }
            Button(role: .destructive) {
                manager.remove(notification.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func headerActionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(toolbarButtonBackground)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cardActionButton(
        title: String,
        prominence: NotificationActionProminence,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominence == .primary ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            prominence == .primary ? Color.accentColor.opacity(0.92) : toolbarFill
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    prominence == .primary
                                        ? Color.accentColor.opacity(0.20)
                                        : cardStroke,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var headerSubtitle: String {
        if visibleNotifications.isEmpty {
            return "Nothing waiting right now"
        }
        if manager.unreadCount > 0 {
            return "\(manager.unreadCount) unread update\(manager.unreadCount == 1 ? "" : "s")"
        }
        return "All caught up"
    }

    // Matches dock GlassBackground dark: rgba(0.10, 0.10, 0.12, 0.52) / light: rgba(0.97, 0.97, 0.99, 0.65)
    private var cardFill: SwiftUI.Color {
        colorScheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.04)
    }

    private var cardStroke: SwiftUI.Color {
        colorScheme == .dark
            ? Color.white.opacity(0.18)  // matches dock border ring alpha
            : Color.black.opacity(0.09)
    }

    private var toolbarFill: SwiftUI.Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.50)
    }

    private var toolbarButtonBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(toolbarFill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(cardStroke, lineWidth: 1)
            )
    }

    private func accentColor(_ name: String) -> SwiftUI.Color {
        switch name {
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        case "purple": return .purple
        case "teal": return .teal
        default: return .blue
        }
    }
}

private enum NotificationActionProminence {
    case primary
    case secondary
}

// MARK: - Old Notification Panel (popover, superseded by NotificationDockView)

struct NotificationPanelView: View {
    @ObservedObject private var manager = ILauncherNotificationManager.shared

    private func color(for name: String) -> SwiftUI.Color {
        switch name {
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        case "purple": return .purple
        case "teal": return .teal
        default: return .blue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Notifications")
                    .font(.headline)
                if manager.unreadCount > 0 {
                    Text("\(manager.unreadCount)")
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                if !manager.notifications.isEmpty {
                    Button("Mark all read") { manager.markAllRead() }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    Button(action: { manager.clearAll() }) {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if manager.notifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No notifications")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.notifications) { n in
                            Button(action: { manager.tap(n.id) }) {
                                HStack(spacing: 10) {
                                    Image(systemName: n.icon)
                                        .font(.system(size: 16))
                                        .foregroundStyle(color(for: n.accentColor))
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(n.title)
                                            .font(.subheadline)
                                            .fontWeight(n.isRead ? .regular : .semibold)
                                            .lineLimit(1)
                                        Text(n.body)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        Text(n.date, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }

                                    Spacer()

                                    if !n.isRead {
                                        Circle()
                                            .fill(color(for: n.accentColor))
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(n.isRead ? Color.clear : Color.white.opacity(0.04))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    manager.markRead(n.id)
                                } label: {
                                    Label("Mark as Read", systemImage: "checkmark.circle")
                                }
                                Button(role: .destructive) {
                                    manager.remove(n.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pinned App Drop Delegate for Reordering
struct PinnedAppDropDelegate: DropDelegate {
    let item: PinnedApp
    @Binding var pinnedApps: [PinnedApp]
    let settings: AppSettings

    func performDrop(info: DropInfo) -> Bool {
        return true
    }

    func dropEntered(info: DropInfo) {
        // Get the dragged item ID
        guard let itemProvider = info.itemProviders(for: [.text]).first else { return }

        itemProvider.loadItem(forTypeIdentifier: "public.text", options: nil) { (data, error) in
            guard let data = data as? Data,
                let draggedIdString = String(data: data, encoding: .utf8),
                let draggedId = UUID(uuidString: draggedIdString)
            else { return }

            DispatchQueue.main.async {
                // Find the indices
                guard let fromIndex = self.pinnedApps.firstIndex(where: { $0.id == draggedId }),
                    let toIndex = self.pinnedApps.firstIndex(where: { $0.id == self.item.id }),
                    fromIndex != toIndex
                else { return }

                // Perform the reorder with animation
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    let movedItem = self.pinnedApps.remove(at: fromIndex)
                    self.pinnedApps.insert(movedItem, at: toIndex)
                }

                print(
                    "📌 Reordered pinned items: moved '\(self.pinnedApps[toIndex].name)' from index \(fromIndex) to \(toIndex)"
                )
            }
        }
    }
}

// MARK: - Two Finger Swipe Gesture Helper
struct TwoFingerSwipeGestureView: NSViewRepresentable {
    let onSwipeUp: () -> Void
    let onSwipeDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = SwipeDetectorView()
        view.onSwipeUp = onSwipeUp
        view.onSwipeDown = onSwipeDown
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? SwipeDetectorView {
            view.onSwipeUp = onSwipeUp
            view.onSwipeDown = onSwipeDown
        }
    }

    class SwipeDetectorView: NSView {
        var onSwipeUp: (() -> Void)?
        var onSwipeDown: (() -> Void)?

        private var accumulatedDeltaY: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // Make this view able to receive scroll events but NOT block clicks
            self.wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { false }

        // Don't block mouse clicks - pass them through
        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }

        override func scrollWheel(with event: NSEvent) {
            let deltaX = abs(event.scrollingDeltaX)
            let deltaY = abs(event.scrollingDeltaY)

            // ALWAYS pass through horizontal scroll immediately (for pinned apps scrolling)
            // Only intercept vertical swipes for switching modes
            if deltaX > deltaY {
                super.scrollWheel(with: event)
                return
            }

            // Only handle vertical swipes
            // Reset accumulator on new gesture
            if event.phase == .began {
                accumulatedDeltaY = 0
            }

            // Accumulate delta during gesture
            if event.phase == .changed || event.phase == .began {
                accumulatedDeltaY += event.scrollingDeltaY
            }

            // Check accumulated delta when gesture ends
            if event.phase == .ended {
                if abs(accumulatedDeltaY) > 30 {
                    if accumulatedDeltaY > 0 {
                        onSwipeDown?()
                    } else {
                        onSwipeUp?()
                    }
                    return
                }
            }

            // Pass through if not handled
            super.scrollWheel(with: event)
        }
    }
}

// Preview commented out due to init parameter changes
// #Preview {
//     LauncherView(onClose: {})
//         .frame(width: 600)
//         .padding()
// }

// MARK: - Right-click interceptor (NSViewRepresentable)

/// Transparent overlay that captures both left-click and right-click, calling separate closures.
/// Left-click fires on mouseUp (matching native button feel). Right-click fires on rightMouseDown.
/// Using a single NSView for both prevents the overlay from silently eating left-clicks.
struct RightClickInterceptor: NSViewRepresentable {
    var onLeftClick: (() -> Void)? = nil
    var onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> RCIHostView {
        let v = RCIHostView()
        v.onLeftClick = onLeftClick
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ v: RCIHostView, context: Context) {
        v.onLeftClick = onLeftClick
        v.onRightClick = onRightClick
    }

    class RCIHostView: NSView {
        var onLeftClick: (() -> Void)?
        var onRightClick: ((CGPoint) -> Void)?

        override func mouseUp(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            if bounds.contains(pt) { onLeftClick?() }
        }

        override func rightMouseDown(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            onRightClick?(CGPoint(x: pt.x, y: bounds.height - pt.y))
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - D Logo Button

/// Notification/profile button. Supports three logo styles (D logo, Apple, system photo).
/// Right-click shows a pill-style logo switcher. Hover shows a 3D tilt + neon glow for the D logo.
struct DLogoButton<PopoverContent: View>: View {
    let action: () -> Void
    let isPresented: Binding<Bool>
    let hasUnread: Bool
    let profileImage: NSImage?
    @ViewBuilder let popoverContent: () -> PopoverContent

    @ObservedObject private var settings = AppSettings.shared
    @State private var isHovering = false
    @State private var transparentLogo: NSImage? = nil
    @State private var showLogoMenu = false

    private var isDLogo: Bool { settings.dockLogoStyle == "d_logo" }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            logoContent
                .frame(width: 36, height: 36)
                .opacity(hasUnread ? 1.0 : 0.82)
                .overlay {
                    // Single NSView handles left click (opens notification panel)
                    // and right click (opens logo switcher) — avoids the overlay blocking issue.
                    RightClickInterceptor(
                        onLeftClick: action,
                        onRightClick: { _ in
                            withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                                showLogoMenu.toggle()
                            }
                        }
                    )
                }

            if showLogoMenu {
                logoSwitcherPillMenu
                    .offset(x: 8, y: 44)
                    .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .topTrailing)))
                    .zIndex(100)
            }
        }
        .scaleEffect(isHovering && isDLogo ? 1.13 : 1.0)
        .rotation3DEffect(
            .degrees(isHovering && isDLogo ? 18 : 0),
            axis: (x: 0.6, y: 1.0, z: 0.0),
            perspective: 0.45
        )
        .shadow(
            color: isDLogo
                ? Color(red: 0.50, green: 0.15, blue: 1.0).opacity(isHovering ? 0.85 : 0.40)
                : .clear,
            radius: isHovering ? 14 : 7
        )
        .animation(.spring(response: 0.26, dampingFraction: 0.60), value: isHovering)
        .onHover { isHovering = $0 }
        .popover(isPresented: isPresented, arrowEdge: .top) { popoverContent() }
        .onAppear {
            Task.detached(priority: .userInitiated) {
                let img = DLogoButton.makeTransparentLogo()
                await MainActor.run { transparentLogo = img }
            }
        }
    }

    @ViewBuilder
    private var logoSwitcherPillMenu: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 300, height: 300)
                .offset(x: -150, y: -44)
                .onTapGesture {
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                        showLogoMenu = false
                    }
                }

            VStack(spacing: 4) {
                logoPillButton(
                    icon: settings.dockLogoStyle == "d_logo" ? "checkmark.circle.fill" : "circle",
                    title: "D Logo",
                    selected: settings.dockLogoStyle == "d_logo"
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        settings.dockLogoStyle = "d_logo"
                    }
                }
                logoPillButton(
                    icon: settings.dockLogoStyle == "apple" ? "checkmark.circle.fill" : "circle",
                    title: "Apple Logo",
                    selected: settings.dockLogoStyle == "apple"
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        settings.dockLogoStyle = "apple"
                    }
                }
                if profileImage != nil {
                    logoPillButton(
                        icon: settings.dockLogoStyle == "system_photo"
                            ? "checkmark.circle.fill" : "circle",
                        title: "System Photo",
                        selected: settings.dockLogoStyle == "system_photo"
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            settings.dockLogoStyle = "system_photo"
                        }
                    }
                }

                Divider()
                    .padding(.horizontal, 10)
                    .opacity(0.4)

                logoPillButton(icon: "gear", title: "Change System Photo…", selected: false) {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preferences.users-groups")!
                    )
                }
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 5)
            .frame(width: 200)
        }
    }

    @ViewBuilder
    private func logoPillButton(
        icon: String, title: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                showLogoMenu = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.75))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.06))
                Capsule()
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.12),
                        lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var logoContent: some View {
        switch settings.dockLogoStyle {
        case "apple":
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom))
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.65), .white.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                Capsule().strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5).blur(radius: 3)
                Image(systemName: "applelogo")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.90))
            }
        case "system_photo":
            if let photo = profileImage {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            } else {
                // Fallback to D logo if no system photo
                dLogoView
            }
        default:  // "d_logo"
            dLogoView
        }
    }

    @ViewBuilder
    private var dLogoView: some View {
        if let img = transparentLogo {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image("DLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .blendMode(.screen)
        }
    }

    /// Core Image pipeline: max(R,G,B) → alpha channel, so pure black becomes transparent.
    private static func makeTransparentLogo() -> NSImage? {
        guard let raw = NSImage(named: "DLogo"),
            let cgSrc = raw.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let ciSrc = CIImage(cgImage: cgSrc)
        guard let maxFilter = CIFilter(name: "CIMaximumComponent") else { return nil }
        maxFilter.setValue(ciSrc, forKey: kCIInputImageKey)
        guard let alphaMask = maxFilter.outputImage else { return nil }
        guard let maskBlend = CIFilter(name: "CIBlendWithMask") else { return nil }
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: ciSrc.extent)
        maskBlend.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        maskBlend.setValue(ciSrc, forKey: kCIInputImageKey)
        maskBlend.setValue(alphaMask, forKey: kCIInputMaskImageKey)
        guard let outputCI = maskBlend.outputImage else { return nil }
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        guard let outCG = ctx.createCGImage(outputCI, from: outputCI.extent) else { return nil }
        return NSImage(cgImage: outCG, size: raw.size)
    }
}

// MARK: - Glass Background

/// NSVisualEffectView wrapped in SwiftUI — provides true wallpaper-blur glass effect.
/// Rounded corners are applied at the AppKit layer so they clip the blur itself.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    /// Explicit dark flag passed from SwiftUI environment — enables reactive system-appearance updates.
    /// When nil, falls back to settings + NSApp.effectiveAppearance (non-reactive in system mode).
    var isDark: Bool? = nil
    @ObservedObject private var settings = AppSettings.shared

    func makeNSView(context: Context) -> NSVisualEffectView {
        let ve = NSVisualEffectView()
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        configure(ve)
        return ve
    }

    func updateNSView(_ ve: NSVisualEffectView, context: Context) {
        ve.blendingMode = .behindWindow
        configure(ve)
    }

    private func configure(_ ve: NSVisualEffectView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        ve.alphaValue = settings.launcherWindowOpacity
        ve.layer?.cornerRadius = cornerRadius
        ve.layer?.masksToBounds = true
        guard let rootLayer = ve.layer else { return }

        let dark = resolvedIsDark

        // ── Material: thin frosted glass (hudWindow) in dark, popover in light ──
        // hudWindow matches SwiftUI .ultraThinMaterial in dark mode — translucent, not heavy.
        ve.material = dark ? .hudWindow : .popover
        switch settings.appearanceMode {
        case "light": ve.appearance = NSAppearance(named: .aqua)
        case "dark": ve.appearance = NSAppearance(named: .darkAqua)
        default: ve.appearance = nil
        }

        // ── Base fill: subtle, lets the blur show through (like ultraThinMaterial) ──
        let base = existingLayer(named: "baseFill", in: rootLayer) {
            let layer = CALayer()
            layer.name = "baseFill"
            rootLayer.insertSublayer(layer, at: 0)
            return layer
        }
        base.cornerRadius = cornerRadius
        base.frame = ve.bounds
        base.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        base.backgroundColor =
            dark
            ? CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.52)  // thin dark tint
            : CGColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 0.65)  // light warm fill

        // ── Gradient overlay: top-bright → bottom-faded, matches input field style ──
        let grad = existingGradientLayer(named: "gradientOverlay", in: rootLayer) {
            let layer = CAGradientLayer()
            layer.name = "gradientOverlay"
            rootLayer.addSublayer(layer)
            return layer
        }
        grad.isHidden = ve.bounds.height <= 0
        grad.cornerRadius = cornerRadius
        grad.frame = ve.bounds
        grad.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        grad.colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: dark ? 0.10 : 0.42),
            CGColor(red: 1, green: 1, blue: 1, alpha: dark ? 0.01 : 0.04),
        ]
        grad.startPoint = CGPoint(x: 0.5, y: 0)  // top
        grad.endPoint = CGPoint(x: 0.5, y: 1)  // bottom

        // ── Border ring ──
        let border = existingLayer(named: "borderRing", in: rootLayer) {
            let layer = CALayer()
            layer.name = "borderRing"
            rootLayer.addSublayer(layer)
            return layer
        }
        border.cornerRadius = cornerRadius
        border.frame = ve.bounds
        border.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        border.borderColor =
            dark
            ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.20)
            : CGColor(red: 0, green: 0, blue: 0, alpha: 0.08)
        border.borderWidth = 1.0
    }

    private func existingLayer(named name: String, in rootLayer: CALayer, create: () -> CALayer)
        -> CALayer
    {
        if let layer = rootLayer.sublayers?.first(where: { $0.name == name }) {
            return layer
        }
        return create()
    }

    private func existingGradientLayer(
        named name: String,
        in rootLayer: CALayer,
        create: () -> CAGradientLayer
    ) -> CAGradientLayer {
        if let layer = rootLayer.sublayers?.first(where: { $0.name == name }) as? CAGradientLayer {
            return layer
        }
        rootLayer.sublayers?.filter { $0.name == name }.forEach { $0.removeFromSuperlayer() }
        return create()
    }

    private var resolvedIsDark: Bool {
        if let isDark { return isDark }
        if settings.appearanceMode == "light" { return false }
        if settings.appearanceMode == "dark" { return true }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// Thin wrapper that reads @Environment(\.colorScheme) and passes isDark to GlassBackground,
/// making it reactive to system appearance changes without requiring a manual isDark parameter.
private struct AdaptiveGlassBackground: View {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        GlassBackground(cornerRadius: cornerRadius, isDark: colorScheme == .dark)
    }
}

struct FocusRingSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    // Run exactly once — re-running every render reassigns isBordered/drawsBackground
    // on the live NSTextField which causes it to resign first responder on macOS.
    func updateNSView(_ view: NSView, context: Context) {
        guard !context.coordinator.didSuppress else { return }
        context.coordinator.didSuppress = true
        DispatchQueue.main.async {
            var root = view.superview
            for _ in 0..<6 {
                guard let current = root else { break }
                suppressFocusRings(in: current)
                root = current.superview
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var didSuppress = false
    }

    private func suppressFocusRings(in view: NSView) {
        if view.focusRingType != .none { view.focusRingType = .none }
        if let textField = view as? NSTextField {
            if textField.focusRingType != .none { textField.focusRingType = .none }
            if textField.isBordered { textField.isBordered = false }
            if textField.drawsBackground { textField.drawsBackground = false }
        }
        view.subviews.forEach { suppressFocusRings(in: $0) }
    }
}

extension View {
    /// Wraps a view in the full glass-pill container: NSVisualEffectView blur + gradient + border stroke.
    func glassContainer(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(AdaptiveGlassBackground(cornerRadius: cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - View helpers

extension View {
    /// Applies a transform only when an optional value is non-nil.
    @ViewBuilder
    func ifLet<T, V: View>(_ value: T?, transform: (Self, T) -> V) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - App launch usage tracker (for ghost-text completion ranking)

final class AppLaunchTracker {
    static let shared = AppLaunchTracker()
    private let key = "appLaunchCounts"

    private var counts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    func record(bundleId: String) {
        var c = counts
        c[bundleId, default: 0] += 1
        counts = c
    }

    func count(for bundleId: String) -> Int {
        counts[bundleId] ?? 0
    }
}

// MARK: - App icon dominant color extraction

extension NSImage {
    /// Returns the dominant (average) color of the image by sampling to 1×1.
    var dominantSwiftUIColor: SwiftUI.Color {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return SwiftUI.Color.accentColor
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel = [UInt8](repeating: 0, count: 4)
        guard
            let ctx = CGContext(
                data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return SwiftUI.Color.accentColor }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = CGFloat(pixel[0]) / 255
        let g = CGFloat(pixel[1]) / 255
        let b = CGFloat(pixel[2]) / 255
        let nsColor =
            NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
            .usingColorSpace(.deviceRGB) ?? NSColor(red: r, green: g, blue: b, alpha: 1)
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        var alp: CGFloat = 0
        nsColor.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alp)
        // Keep the sampled app color subtle; opacity is applied by the caller.
        let softened = NSColor(
            hue: hue,
            saturation: min(sat * 0.75, 0.55),
            brightness: min(max(bri, 0.35), 0.85),
            alpha: 1
        )
        return SwiftUI.Color(softened)
    }
}

// MARK: - NSSharingServicePicker dismiss coordinator

/// Lightweight Obj-C object that acts as NSSharingServicePickerDelegate.
/// Calls `onDismiss` after the user picks a service or cancels the picker.
final class SharePickerCoordinator: NSObject, NSSharingServicePickerDelegate {
    static var key = 0  // used as objc_setAssociatedObject key
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    func sharingServicePicker(
        _ picker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        DispatchQueue.main.async { self.onDismiss() }
    }
}
