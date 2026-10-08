// CornerBoardPreviewPanel.swift
// Context-Dock
//
// The split board's right half (#191): what the highlighted row is, shown — a file's
// preview, an app, a menu command — as an inset card inside the list's own card, laid out
// the way Claude's Progress panel is (owner 2026-10-05): a header, hairlines, titled
// sections, and rows of an icon, a name and a dimmed trailing kind. It follows the arrows;
// it never takes the keys.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct CornerBoardPreviewPanel: View {
    let preview: CornerBoardPreview

    var body: some View {
        // Scrolls when there is more than the card holds (owner 2026-10-05: a file's details
        // were cut off under its preview). The wheel scrolls it; the keys stay with the list.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                switch preview {
                case .file(let url): FilePreview(url: url)
                case .app(let bundleID, let name): AppPreview(bundleID: bundleID, name: name)
                case .command(let title, let path, let appName, let bundleID):
                    CommandPreview(title: title, path: path, appName: appName, bundleID: bundleID)
                case .cliTool(let command, let name):
                    CLIToolPreview(command: command, name: name, subcommand: nil)
                case .cliSubcommand(let command, let subcommand):
                    CLIToolPreview(command: command, name: command, subcommand: subcommand)
                case .systemCommand(let id, let name):
                    SystemCommandPreview(id: id, name: name)
                case .web(let url, let title, let domain, let browserName):
                    WebPagePreview(url: url, title: title, domain: domain, browserName: browserName)
                case .windowLayout(let command, let title, let appName, let bundleID):
                    WindowLayoutPreview(
                        command: command, title: title, appName: appName, bundleID: bundleID)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // A new row is a new card, so it never shows the last row's contents for a frame.
        .id(preview)
        .boardPanelCard()
    }
}

extension View {
    /// The panel's card: inset in the board's glass, a shade lifted, a hairline edge — a
    /// card, not a pane. The result board's preview and the Context Dock's live panel share it.
    func boardPanelCard() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.trailing, 10)
            .accessibilityElement(children: .contain)
    }
}

// MARK: - The card's parts, shared by every kind

/// The card's title line: what this is, and one dimmed line under it.
struct PanelHeader: View {
    let icon: NSImage?
    let title: String
    let subtitle: String
    var status: Color? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if let status {
                        Circle().fill(status).frame(width: 6, height: 6)
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
    }
}

/// The hairline between sections.
struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}

/// A section's name, as Claude titles "Context" or "Outputs".
struct PanelSection: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .padding(.bottom, 6)
    }
}

/// One line of a section: an icon or a label, a name, and a dimmed trailing kind.
struct PanelRow: View {
    var icon: NSImage? = nil
    var symbol: String? = nil
    var label: String? = nil
    let value: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            if let label {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
            }
            Text(value)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(height: 24)
    }
}

/// `~/Documents/Work` rather than `/Users/name/Documents/Work`.
private func boardPanelPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = url.path
    return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
}

/// A file's kind the way Claude labels it: its extension, upper-cased, or "Folder".
private func boardPanelKind(_ url: URL) -> String {
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
        url.pathExtension != "app"
    {
        return "Folder"
    }
    return url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
}

// MARK: - File

private struct FilePreview: View {
    let url: URL
    @State private var thumbnail: NSImage?

    private var isFolder: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && url.pathExtension != "app"
    }

    var body: some View {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: icon, title: url.lastPathComponent,
                subtitle: boardPanelPath(url.deletingLastPathComponent()))
            if isFolder {
                PanelDivider()
                FolderListing(url: url)
            } else {
                // The file itself, as Quick Look draws it.
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                    Image(nsImage: thumbnail ?? icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(thumbnail == nil ? 28 : 6)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 118)
                PanelDivider()
                PanelSection(title: "Details")
                details
            }
        }
        .onAppear(perform: loadThumbnail)
    }

    private var details: some View {
        let values = try? url.resourceValues(forKeys: [
            .localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey,
        ])
        return VStack(alignment: .leading, spacing: 0) {
            if let kind = values?.localizedTypeDescription {
                PanelRow(label: "Kind", value: kind, trailing: boardPanelKind(url))
            }
            if let size = values?.fileSize {
                PanelRow(
                    label: "Size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            if let date = values?.contentModificationDate {
                PanelRow(
                    label: "Modified", value: date.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func loadThumbnail() {
        guard !isFolder else { return }
        let path = url.path
        ThumbnailGenerator.shared.getThumbnail(
            for: path, size: CGSize(width: 560, height: 240)
        ) { image in
            DispatchQueue.main.async {
                if url.path == path { thumbnail = image }
            }
        }
    }
}

/// A folder's first items, folders first — each a row with its kind, as Claude lists files.
private struct FolderListing: View {
    let url: URL
    private static let limit = 7

    var body: some View {
        let items = Self.items(in: url)
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: items.isEmpty ? "Empty folder" : "\(items.count) items")
            ForEach(items.prefix(Self.limit), id: \.self) { item in
                PanelRow(
                    icon: NSWorkspace.shared.icon(forFile: item.path),
                    value: item.lastPathComponent, trailing: boardPanelKind(item))
            }
            if items.count > Self.limit {
                Text("+\(items.count - Self.limit) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    static func items(in url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
                == .orderedAscending
        }
    }
}

// MARK: - App

private struct AppPreview: View {
    let bundleID: String
    let name: String

    var body: some View {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let bundle = appURL.flatMap { Bundle(url: $0) }
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: appURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
                title: name,
                subtitle: running == nil ? "Not running" : "Running",
                status: running == nil ? Color.secondary.opacity(0.5) : .green)
            PanelDivider()
            PanelSection(title: "Details")
            if let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String
            {
                PanelRow(label: "Version", value: version)
            }
            if let appURL {
                PanelRow(label: "Where", value: boardPanelPath(appURL.deletingLastPathComponent()))
            }
            PanelDivider()
            PanelSection(title: "Actions")
            PanelRow(
                symbol: "return", value: running == nil ? "Open" : "Bring forward", trailing: "↩")
            if running != nil {
                PanelRow(symbol: "arrow.right", value: "Step into its Context Dock", trailing: "→")
            }
        }
    }
}

// MARK: - Command

private struct CommandPreview: View {
    let title: String
    let path: [String]
    let appName: String
    let bundleID: String

    var body: some View {
        let appIcon: NSImage? = {
            guard !bundleID.isEmpty,
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }()
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: appIcon, title: title,
                subtitle: appName.isEmpty ? "Menu command" : "\(appName) menu command")
            PanelDivider()
            // Where it lives: one row per menu level, the way the menu bar leads there.
            PanelSection(title: "Menu")
            ForEach(Array(path.enumerated()), id: \.offset) { index, step in
                PanelRow(
                    symbol: index == path.count - 1 ? "command" : "chevron.right",
                    value: step)
            }
            PanelDivider()
            PanelRow(symbol: "return", value: "Run it", trailing: "↩")
        }
    }
}

// MARK: - Monospaced text (help, scripts)

/// A tool's help or a command's script: monospaced, selectable, wrapped to the card.
struct PanelCode: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.85))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.2)))
    }
}

// MARK: - CLI tool

private struct CLIToolPreview: View {
    let command: String
    let name: String
    /// Set inside the tool's scope, for one of its subcommands.
    let subcommand: String?

    var body: some View {
        let package = TerminalPackageManager.shared.packages.first { $0.command == command }
        let help = package?.helpText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil),
                title: subcommand.map { "\(command) \($0)" } ?? (package?.name ?? name),
                subtitle: subcommand == nil
                    ? (package?.installedPath ?? "cli://\(command)")
                    : (package?.name ?? name))
            if let subcommand {
                // The tool's own words about this subcommand: its lines in the help.
                let lines = CornerBoardLayout.helpLines(mentioning: subcommand, in: help)
                PanelDivider()
                PanelSection(title: "From \(command) --help")
                if lines.isEmpty {
                    Text("The help does not describe \(subcommand) on its own line.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    PanelCode(text: lines.joined(separator: "\n"))
                }
                PanelDivider()
                PanelRow(symbol: "return", value: "Run \(command) \(subcommand)", trailing: "↩")
            } else {
                PanelDivider()
                PanelSection(title: "Details")
                if let description = package?.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                }
                if let usage = package?.usagePattern, !usage.isEmpty {
                    PanelRow(label: "Usage", value: usage)
                }
                if let path = package?.installedPath {
                    PanelRow(label: "Where", value: path)
                }
                if let subcommands = package?.subcommands, !subcommands.isEmpty {
                    PanelDivider()
                    PanelSection(title: "Subcommands")
                    ForEach(subcommands.prefix(12), id: \.self) { sub in
                        PanelRow(symbol: "chevron.right", value: sub)
                    }
                    if subcommands.count > 12 {
                        Text("+\(subcommands.count - 12) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                PanelDivider()
                PanelRow(symbol: "arrow.right", value: "Step into \(name)", trailing: "→")
            }
            if !help.isEmpty {
                PanelDivider()
                PanelSection(title: "Help")
                PanelCode(text: help)
            }
        }
    }
}

// MARK: - Global Command

private struct SystemCommandPreview: View {
    let id: String
    let name: String

    var body: some View {
        let command = SystemCommandsRegistry.shared.commands.first { $0.id.uuidString == id }
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: NSImage(
                    systemSymbolName: command?.icon ?? "command", accessibilityDescription: nil)
                    ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil),
                title: command?.name ?? name,
                subtitle: "Global Command")
            if let command {
                if !command.description.isEmpty {
                    PanelDivider()
                    Text(command.description)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                PanelDivider()
                PanelSection(title: "Details")
                PanelRow(label: "Runs", value: command.scriptType)
                if !command.keywords.isEmpty {
                    PanelRow(label: "Keywords", value: command.keywords.joined(separator: ", "))
                }
                PanelRow(label: "Undo", value: command.undoScript.isEmpty ? "None" : command.undoTitle.isEmpty ? "Yes" : command.undoTitle)
                if !command.script.isEmpty {
                    PanelDivider()
                    PanelSection(title: "Script")
                    PanelCode(text: command.script)
                }
            }
            PanelDivider()
            PanelRow(symbol: "arrow.right", value: "Step into it", trailing: "→")
        }
    }
}

// MARK: - Web page

private struct WebPagePreview: View {
    let url: URL
    let title: String
    let domain: String
    let browserName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: NSImage(systemSymbolName: "globe", accessibilityDescription: nil),
                title: title, subtitle: domain.isEmpty ? (url.host ?? url.absoluteString) : domain)
            // The page itself, scaled down, loaded only once the row has been held a moment.
            WebPageThumbnail(url: url)
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08)))
                // A preview, not a browser: the wheel scrolls the card, a click does nothing.
                .allowsHitTesting(false)
            PanelDivider()
            PanelSection(title: "Details")
            PanelRow(label: "Address", value: url.absoluteString)
            if !browserName.isEmpty {
                PanelRow(label: "From", value: browserName)
            }
            PanelDivider()
            PanelRow(symbol: "return", value: "Open in \(browserName.isEmpty ? "the browser" : browserName)", trailing: "↩")
        }
    }
}

/// A web view that loads its page only after the highlight has rested on it, so arrowing
/// down a list of history does not fetch every page passed over.
private struct WebPageThumbnail: NSViewRepresentable {
    let url: URL
    static let restDelay: TimeInterval = 0.35

    final class Coordinator {
        var pending: DispatchWorkItem?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.pageZoom = 0.5
        schedule(view, context: context)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard view.url != url else { return }
        schedule(view, context: context)
    }

    private func schedule(_ view: WKWebView, context: Context) {
        context.coordinator.pending?.cancel()
        let item = DispatchWorkItem { [weak view] in view?.load(URLRequest(url: url)) }
        context.coordinator.pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restDelay, execute: item)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            coordinator.pending?.cancel()
            view.stopLoading()
        }
    }
}

// MARK: - Window layout

/// A native window layout: the screen at the card's width, with the app's window — and, for a
/// two-app arrangement, the other app's — drawn where the layout will put them. The regions
/// are the Dock's own (`WindowManagementService.Command.layoutRegions`), the same ones its
/// row icon draws.
private struct WindowLayoutPreview: View {
    let command: String
    let title: String
    let appName: String
    let bundleID: String

    private var layout: WindowManagementService.Command? {
        WindowManagementService.Command(rawValue: command)
    }

    private var appIcon: NSImage? {
        guard !bundleID.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// The windows themselves, where Screen Recording allows; the icons otherwise.
    @ObservedObject private var snapshots = AppWindowSnapshotService.shared
    /// The other apps open on this desktop, front to back, one per remaining tile (owner
    /// 2026-10-08: "show the apps' snapshots in the layout, smartly, by the apps opened").
    @State private var others: [String] = []

    /// Which app a tile shows: this one first, then the desktop's others in order.
    private func tileApp(_ index: Int) -> String? {
        if index == 0 { return bundleID.isEmpty ? nil : bundleID }
        let other = index - 1
        return other < others.count ? others[other] : nil
    }

    private static func icon(for bundleID: String) -> NSImage? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Reads the desktop's apps and asks for their pictures, once per row shown.
    private func loadTiles() {
        let tiles = layout?.layoutRegions.count ?? 0
        others = DesktopApps.frontToBack(excluding: bundleID, limit: max(tiles - 1, 0))
        for id in [bundleID] + others where !id.isEmpty {
            snapshots.refresh(bundleID: id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(
                icon: appIcon, title: title,
                subtitle: appName.isEmpty ? "Window layout" : "\(appName) window layout")
            screen
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(maxWidth: .infinity)
            PanelDivider()
            PanelRow(symbol: "return", value: "Arrange it", trailing: "↩")
        }
        .onAppear(perform: loadTiles)
        .onChange(of: command) { _, _ in loadTiles() }
        .onChange(of: bundleID) { _, _ in loadTiles() }
    }

    /// The screen, with each region a window tile.
    private var screen: some View {
        let regions = layout?.layoutRegions ?? []
        return GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                // The menu bar, so it reads as a screen at a glance.
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: size.width, height: 6)
                    .clipShape(
                        UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
                ForEach(Array(regions.enumerated()), id: \.offset) { index, region in
                    let inset: CGFloat = 4
                    let top: CGFloat = 8
                    let rect = CGRect(
                        x: inset + region.minX * (size.width - inset * 2),
                        y: top + region.minY * (size.height - top - inset),
                        width: region.width * (size.width - inset * 2),
                        height: region.height * (size.height - top - inset)
                    ).insetBy(dx: 2, dy: 2)
                    tile(index: index, rect: rect)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// One region: the app's window where there is a picture, its icon on the accent fill
    /// otherwise, and an empty accent tile when the desktop has no app for it.
    @ViewBuilder
    private func tile(index: Int, rect: CGRect) -> some View {
        let app = tileApp(index)
        let picture = app.flatMap { snapshots.snapshot(for: $0) }
        let icon = app.flatMap { Self.icon(for: $0) }
        let side = min(rect.width, rect.height)
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.accentColor.opacity(index == 0 ? 0.85 : 0.45))
            .overlay {
                if let picture {
                    Image(nsImage: picture)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: rect.width, height: rect.height)
                        .clipped()
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side * 0.45, height: side * 0.45)
                }
            }
            // Whose window it is, in the corner, once the picture stands in for the icon.
            .overlay(alignment: .bottomLeading) {
                if picture != nil, let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: min(18, side * 0.3), height: min(18, side * 0.3))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(index == 0 ? 0.9 : 0.5),
                        lineWidth: picture == nil ? 0 : 1.5))
            .animation(.easeOut(duration: 0.2), value: picture != nil)
    }
}
