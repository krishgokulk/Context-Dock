//
//  PinnedAppsRow.swift
//  ILauncher
//
//  Created by Krishgokul on 20/11/2025.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PinnedAppsRow: View {
    let pinnedApps: [PinnedApp]
    let onLaunch: (PinnedApp) -> Void
    let onUnpin: (PinnedApp) -> Void
    let onReorder: (Int, Int) -> Void // Source index, destination index
    let onPin: (PinnedApp) -> Void // Add new pinned item

    @State private var hoveredAppId: UUID?
    @State private var draggedApp: PinnedApp?
    @State private var dropTargetIndex: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(Array(pinnedApps.enumerated()), id: \.element.id) { index, app in
                    PinnedAppIcon(
                        app: app,
                        isHovered: hoveredAppId == app.id,
                        isDragging: draggedApp?.id == app.id,
                        isDropTarget: dropTargetIndex == index,
                        onLaunch: { onLaunch(app) },
                        onUnpin: { onUnpin(app) }
                    )
                    .onHover { hovering in
                        hoveredAppId = hovering ? app.id : nil
                    }
                    .onDrag {
                        self.draggedApp = app
                        return NSItemProvider(object: app.id.uuidString as NSString)
                    }
                    .onDrop(of: [.fileURL, .text], isTargeted: nil) { providers, location in
                        handleDrop(providers: providers, at: index)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 54)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers, location in
            // Handle drop at the end of the list
            handleDrop(providers: providers, at: pinnedApps.count)
        }
    }

    private func handleDrop(providers: [NSItemProvider], at index: Int) -> Bool {
        // Check if it's a reorder operation (dragging existing pinned app)
        if let draggedApp = draggedApp {
            if let sourceIndex = pinnedApps.firstIndex(where: { $0.id == draggedApp.id }) {
                onReorder(sourceIndex, index)
                self.draggedApp = nil
                return true
            }
        }

        // Otherwise, try to pin a new item from file URL
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (urlData, error) in
                    DispatchQueue.main.async {
                        if let data = urlData as? Data,
                           let path = String(data: data, encoding: .utf8),
                           let url = URL(string: path) {

                            let fileURL = url.standardizedFileURL
                            let fileName = fileURL.deletingPathExtension().lastPathComponent
                            let pathExtension = fileURL.pathExtension

                            // Determine type based on extension
                            let type: PinnedApp.PinnedItemType
                            if pathExtension == "app" {
                                type = .application
                            } else {
                                var isDirectory: ObjCBool = false
                                if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) {
                                    type = isDirectory.boolValue ? .folder : .file
                                } else {
                                    type = .file
                                }
                            }

                            // Get bundle identifier for apps
                            let bundleId: String?
                            if type == .application, let bundle = Bundle(url: fileURL) {
                                bundleId = bundle.bundleIdentifier
                            } else {
                                bundleId = nil
                            }

                            let newPinnedItem = PinnedApp(
                                name: fileName,
                                path: fileURL.path,
                                bundleIdentifier: bundleId,
                                type: type
                            )

                            onPin(newPinnedItem)
                        }
                    }
                }
                return true
            }
        }

        return false
    }
}

struct PinnedAppIcon: View {
    let app: PinnedApp
    let isHovered: Bool
    let isDragging: Bool
    let isDropTarget: Bool
    let onLaunch: () -> Void
    let onUnpin: () -> Void

    private var appIcon: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 48, height: 48)
        return icon
    }

    var body: some View {
        Button(action: onLaunch) {
            ZStack(alignment: .topTrailing) {
                // App icon
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                    .scaleEffect(isHovered ? 1.1 : 1.0)
                    .opacity(isDragging ? 0.5 : 1.0)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.accentColor, lineWidth: isDropTarget ? 3 : 0)
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
                    .animation(.easeInOut(duration: 0.2), value: isDragging)
                    .animation(.easeInOut(duration: 0.2), value: isDropTarget)

                // Unpin button (shown on hover)
                if isHovered && !isDragging {
                    Button(action: onUnpin) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .background(
                                Circle()
                                    .fill(.black.opacity(0.5))
                                    .frame(width: 20, height: 20)
                            )
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .help(app.name)
    }
}

#Preview {
    PinnedAppsRow(
        pinnedApps: [
            PinnedApp(name: "Safari", path: "/Applications/Safari.app"),
            PinnedApp(name: "Mail", path: "/Applications/Mail.app"),
            PinnedApp(name: "Calendar", path: "/Applications/Calendar.app")
        ],
        onLaunch: { _ in },
        onUnpin: { _ in },
        onReorder: { _, _ in },
        onPin: { _ in }
    )
    .frame(width: 600)
    .padding()
    .background(.ultraThinMaterial)
}
