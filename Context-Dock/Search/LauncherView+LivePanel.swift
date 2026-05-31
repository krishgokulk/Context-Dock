import AppKit
import Foundation
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI

extension LauncherView {
    // MARK: - Live Panel (slides in from right like Claude's artifact panel)

    /// The slide-in panel — only rendered when `livePanelVisible == true`.
    /// Shows context info, an embedded terminal, music player, or a file preview
    /// depending on what the AI or user triggered.
    @ViewBuilder
    var livePanelView: some View {
        VStack(spacing: 0) {
            livePanelHeader
            Divider()
            livePanelContent
        }
        .frame(width: 310)
        .background(.ultraThinMaterial)
        // Auto-switches
        .onChange(of: miniPlayer.playerInfo != nil) { _, has in
            if has { showLivePanel(.nowPlaying) }
        }
        .onChange(of: workerPool.workers.count) { old, new in
            guard new > old else { return }
            let hasPTY = workerPool.workers.values.contains { $0.isPTY && $0.status.isActive }
            if hasPTY { showLivePanel(.terminal) }
        }
        .onDisappear {
            mediaDockEngine.stopAutoRefresh()
        }
    }

    /// Thin header: icon + title + optional subtitle + X dismiss button
    @ViewBuilder
    var livePanelHeader: some View {
        let (icon, title, subtitle, tint) = livePanelHeaderMeta
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    livePanelVisible = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    var livePanelHeaderMeta:
        (icon: String, title: String, subtitle: String, tint: SwiftUI.Color)
    {
        switch livePanelMode {
        case .results(let items):
            let count = items.count
            return (
                "list.bullet", count > 0 ? "\(count) Result\(count == 1 ? "" : "s")" : "Results",
                "", .accentColor
            )
        case .terminal:
            let count = workerPool.workers.values.filter { $0.status.isActive }.count
            return (
                "terminal.fill", "Terminal", count > 0 ? "\(count) process running" : "Shell ready",
                .green
            )
        case .nowPlaying:
            let track = mediaDockEngine.title.isEmpty ? "Now Playing" : mediaDockEngine.title
            return (
                "music.note", track, mediaDockEngine.artist,
                Color(red: 0.2, green: 0.8, blue: 0.4)
            )
        case .filePreview(let url):
            return (
                "doc.fill", url.lastPathComponent, url.deletingLastPathComponent().path,
                .accentColor
            )
        }
    }

    /// Switches mode content based on current `livePanelMode`
    @ViewBuilder
    var livePanelContent: some View {
        switch livePanelMode {
        case .results(let items):
            livePanelResultsView(items: items)
        case .terminal:
            livePanelTerminalView
        case .nowPlaying:
            livePanelNowPlayingView
        case .filePreview(let url):
            livePanelFilePreviewView(url: url)
        }
    }

    /// Helper — show panel with a specific mode + slide-in animation
    func showLivePanel(_ mode: LivePanelMode) {
        livePanelMode = mode
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            livePanelVisible = true
        }
    }

    @ViewBuilder
    func livePanelResultsView(items: [LivePanelMode.ResultEntry]) -> some View {
        if items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(.secondary.opacity(0.4))
                Text("Ask the AI to show results")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("e.g. \"list all PDFs here\" or \"find large files\"")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            if !item.path.isEmpty {
                                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if !item.path.isEmpty {
                                    Menu {
                                        Button("Open") {
                                            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                                        }
                                        Button("Reveal in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([
                                                URL(fileURLWithPath: item.path)
                                            ])
                                        }
                                        Button("Copy Path") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(
                                                item.path, forType: .string)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .padding(4)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .frame(width: 20)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.0))
                        Divider().padding(.leading, 42).opacity(0.4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    func livePanelFileCard(ctx: SearchContextApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Icon + name
            HStack(spacing: 12) {
                if let icon = ctx.icon {
                    Image(nsImage: icon)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(ctx.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if let path = ctx.filePath {
                        Text(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 14)

            // File metadata
            if let path = ctx.filePath {
                let url = URL(fileURLWithPath: path)
                let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                let size = attrs[.size] as? Int ?? 0
                let modified = attrs[.modificationDate] as? Date
                let ext = url.pathExtension.uppercased()

                VStack(spacing: 0) {
                    livePanelMetaRow(label: "Kind", value: ext.isEmpty ? "File" : "\(ext) file")
                    Divider().padding(.horizontal, 14).opacity(0.4)
                    livePanelMetaRow(
                        label: "Size",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(size), countStyle: .file))
                    if let mod = modified {
                        Divider().padding(.horizontal, 14).opacity(0.4)
                        livePanelMetaRow(
                            label: "Modified",
                            value: RelativeDateTimeFormatter().localizedString(
                                for: mod, relativeTo: Date()))
                    }
                }
                .padding(.vertical, 6)
            }

            Divider().padding(.horizontal, 14)

            // Actions
            livePanelActionGrid(ctx: ctx)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    func livePanelFolderCard(ctx: SearchContextApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let icon = ctx.icon {
                    Image(nsImage: icon)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.yellow)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(ctx.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let path = ctx.filePath {
                        Text(path)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 14)

            // Contents summary
            if let path = ctx.filePath,
                let contents = try? FileManager.default.contentsOfDirectory(atPath: path)
            {
                let count = contents.count
                let hidden = contents.filter { $0.hasPrefix(".") }.count
                VStack(spacing: 0) {
                    livePanelMetaRow(
                        label: "Items", value: "\(count - hidden) visible, \(hidden) hidden")
                    Divider().padding(.horizontal, 14).opacity(0.4)
                    // Recent items
                    let recent = contents.prefix(6).filter { !$0.hasPrefix(".") }
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, name in
                        HStack(spacing: 8) {
                            Image(systemName: name.contains(".") ? "doc" : "folder")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .frame(width: 14)
                            Text(name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().padding(.horizontal, 14)
            livePanelActionGrid(ctx: ctx).padding(.bottom, 12)
        }
    }

    @ViewBuilder
    func livePanelContactCard(ctx: SearchContextApp) -> some View {
        VStack(spacing: 0) {
            // Avatar
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.4),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 60, height: 60)
                    Text(String(ctx.name.prefix(2)).uppercased())
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Text(ctx.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(ctx.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

            Divider().padding(.horizontal, 14)

            VStack(spacing: 0) {
                if let email = ctx.contactEmail {
                    livePanelMetaRow(label: "Email", value: email)
                    Divider().padding(.horizontal, 14).opacity(0.4)
                }
                if let phone = ctx.contactPhone {
                    livePanelMetaRow(label: "Phone", value: phone)
                    Divider().padding(.horizontal, 14).opacity(0.4)
                }
            }
            .padding(.vertical, 4)

            livePanelActionGrid(ctx: ctx).padding(.bottom, 12)
        }
    }

    @ViewBuilder
    func livePanelAppCard(ctx: SearchContextApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let icon = ctx.icon {
                    Image(nsImage: icon)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 52, height: 52)
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(ctx.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if !ctx.appPath.isEmpty {
                        let bundleID = Bundle(path: ctx.appPath)?.bundleIdentifier ?? ""
                        if !bundleID.isEmpty {
                            Text(bundleID)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        let version =
                            Bundle(path: ctx.appPath)?.infoDictionary?["CFBundleShortVersionString"]
                            as? String ?? ""
                        if !version.isEmpty {
                            Text("Version \(version)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 14)
            livePanelActionGrid(ctx: ctx).padding(.bottom, 12)
        }
    }

    @ViewBuilder
    func livePanelGenericCard(ctx: SearchContextApp) -> some View {
        VStack(spacing: 12) {
            if let icon = ctx.icon {
                Image(nsImage: icon)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
            }
            Text(ctx.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if !ctx.subtitle.isEmpty {
                Text(ctx.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    @ViewBuilder
    func livePanelMetaRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    func livePanelActionGrid(ctx: SearchContextApp) -> some View {
        let actions = contextPanelActions()
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Actions")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                VStack(spacing: 1) {
                    ForEach(actions) { action in
                        Button {
                            action.action()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 16)
                                Text(action.label)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.quaternary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0))
                        if action.id != actions.last?.id {
                            Divider().padding(.horizontal, 14).opacity(0.3)
                        }
                    }
                }
            }
        }
    }

    /// Compact quick-action chips floating above the panel input field
    @ViewBuilder
    var floatingQuickActionsStrip: some View {
        let actions = contextPanelActions()
        if !actions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(actions) { action in
                        Button {
                            action.action()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 10, weight: .medium))
                                Text(action.label)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(
                                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    var livePanelTerminalView: some View {
        VStack(spacing: 0) {
            // Terminal header
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Active workers indicator
                let active = workerPool.workers.values.filter { $0.status.isActive }
                if !active.isEmpty {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                            .opacity(0.8)
                        Text("\(active.count) running")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    panelTerminalHost?.sendCommand("clear")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.4))

            // SwiftTerm embedded view
            if let host = panelTerminalHost {
                TerminalNSViewRepresentable(terminalController: host)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Starting terminal…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    panelTerminalHost = TerminalHostController()
                }
            }
        }
        .background(Color.black.opacity(0.55))
        .onAppear {
            if panelTerminalHost == nil {
                panelTerminalHost = TerminalHostController()
            }
        }
    }

    @ViewBuilder
    var livePanelNowPlayingView: some View {
        VStack(spacing: 0) {
            // Album art placeholder + info
            VStack(spacing: 0) {
                // Large album art area
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.3), Color.purple.opacity(0.2),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "music.note")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // Track info
                VStack(spacing: 4) {
                    Text(mediaDockEngine.title.isEmpty ? "Nothing Playing" : mediaDockEngine.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(mediaDockEngine.artist.isEmpty ? "—" : mediaDockEngine.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !mediaDockEngine.album.isEmpty {
                        Text(mediaDockEngine.album)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Now playing source badge
                if let info = miniPlayer.playerInfo {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("via \(info.toolName)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                }

                Divider().padding(.horizontal, 16).padding(.vertical, 6)

                // Playback controls
                HStack(spacing: 0) {
                    Spacer()
                    Button {
                        mediaDockEngine.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        mediaDockEngine.togglePlayPause()
                    } label: {
                        Image(
                            systemName: mediaDockEngine.isPlaying
                                ? "pause.circle.fill" : "play.circle.fill"
                        )
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        mediaDockEngine.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Button {
                    mediaDockEngine.stop()
                } label: {
                    Label("Stop Playback", systemImage: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .onAppear {
            mediaDockEngine.startAutoRefresh()
        }
        .onDisappear {
            mediaDockEngine.stopAutoRefresh()
        }
    }

    // MARK: - Live Panel: File Preview (inline QL preview for AI-created files)
    @ViewBuilder
    func livePanelFilePreviewView(url: URL) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    InlineQLPreview(
                        url: url,
                        onRightClick: { pos in
                            withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                                qlRightClickPos = pos
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let pos = qlRightClickPos {
                        PillContextMenuPopup(
                            items: qlContextMenuItems(for: url),
                            position: pos,
                            containerSize: geo.size,
                            onDismiss: {
                                withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
                                    qlRightClickPos = nil
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.90)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom action bar
            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered).controlSize(.small)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy path")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    func qlContextMenuItems(for url: URL) -> [PillContextMenuAction] {
        [
            PillContextMenuAction(icon: "arrow.up.right.square", title: "Open") {
                NSWorkspace.shared.open(url)
            },
            PillContextMenuAction(icon: "folder", title: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            PillContextMenuAction(icon: "doc.on.doc", title: "Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            },
            PillContextMenuAction(icon: "square.and.arrow.up", title: "Share…") {
                let picker = NSSharingServicePicker(items: [url])
                if let window = NSApp.keyWindow,
                    let view = window.contentView
                {
                    picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
                }
            },
        ]
    }

    /// Strips raw tool-call syntax that the AI accidentally echoes as plain text.
    static func stripLeakedToolCalls(_ text: String) -> String {
        var result = text
        let patterns = [
            // Function-call style: run_command(...) or spawn_worker(...)
            #"run_command\s*\([\s\S]*?\)"#,
            #"spawn_worker\s*\([\s\S]*?\)"#,
            // Any JSON object with a "name" key — catches invented tool names like {"name":"remind",...}
            #"\{[\s\S]*?"name"\s*:\s*"[^"]*"[\s\S]*?"parameters"[\s\S]*?\}"#,
            #"\{[\s\S]*?"name"\s*:\s*"[^"]*"[\s\S]*?"input"[\s\S]*?\}"#,
            // Also catch preamble lines like "I will call the X tool with..."
            #"(?m)^.*?I will (call|use|invoke).*?(tool|function|script).*\n?"#,
            #"(?m)^.*?(function call|tool call|following call).*\n?"#,
            // Fenced code blocks that are just tool calls
            #"```json[\s\S]*?```"#,
            #"```[\s\S]*?```"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators])
            {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect if a shell command created/wrote an output file.
    /// Returns the URL if found and the file exists.
    func detectCreatedFile(command: String, output: String) -> URL? {
        let expandPath: (String) -> URL? = { raw in
            guard !raw.isEmpty else { return nil }
            let path = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        // -o flag: pandoc -o out.pdf, ffmpeg -o out.mp4, etc.
        if let range = command.range(of: #"-o\s+(\S+)"#, options: .regularExpression) {
            let full = String(command[range])
            let parts = full.components(separatedBy: .whitespaces)
            if parts.count >= 2, let url = expandPath(parts[1]) { return url }
        }

        // Shell redirect: cmd > file.txt
        if let range = command.range(of: #">\s*(\S+)"#, options: .regularExpression) {
            let full = String(command[range])
            let parts = full.components(separatedBy: .whitespaces)
            if parts.count >= 2, let url = expandPath(parts[1]) { return url }
        }

        // Common "saved to PATH" / "written to PATH" phrases in output
        for marker in [
            "saved to ", "created: ", "written to ", "output: ", "→ ", "=> ", "exported to ",
        ] {
            if let idx = output.range(of: marker, options: .caseInsensitive)?.upperBound {
                let after = String(output[idx...])
                let candidate = after.components(separatedBy: .whitespacesAndNewlines).first ?? ""
                if let url = expandPath(candidate) { return url }
            }
        }

        // Any absolute path in the output that is a file (not a directory)
        let pathPattern = #"(/[^\s\"']+\.[a-zA-Z0-9]{1,8})"#
        if let matches = output.range(of: pathPattern, options: .regularExpression) {
            let candidate = String(output[matches])
            if let url = expandPath(candidate),
                !url.hasDirectoryPath
            {
                return url
            }
        }

        return nil
    }

    /// Master dispatcher: routes command output to the right panel parser based on panel type.
    func parseCommandOutputForPanel(command: String, output: String, panelKey: String)
        -> [LivePanelMode.ResultEntry]
    {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let cmd = command.trimmingCharacters(in: .whitespaces).lowercased()

        // ── Reminders (rem CLI) ─────────────────────────────────────────
        if panelKey == "reminders" || cmd.hasPrefix("rem ") {
            return parseRemOutput(output)
        }

        // ── Process list (ps, pgrep, top -l 1 | grep) ──────────────────
        if cmd.hasPrefix("ps ") || cmd.hasPrefix("ps\n") || cmd == "ps"
            || cmd.hasPrefix("pgrep") || cmd.contains("| ps")
        {
            return parseProcessOutput(output)
        }

        // ── Network (netstat, lsof -i, nmap) ───────────────────────────
        if cmd.hasPrefix("netstat") || cmd.hasPrefix("lsof -i") || cmd.hasPrefix("nmap") {
            return parseNetworkOutput(command: command, output: output)
        }

        // ── Brew (brew list, brew outdated, brew search) ────────────────
        if cmd.hasPrefix("brew ") {
            return parseBrewOutput(command: command, output: output)
        }

        // ── Git (git log, git status, git branch, git diff --stat) ─────
        if cmd.hasPrefix("git ") {
            return parseGitOutput(command: command, output: output)
        }

        // ── Generic line list (any output with ≥3 lines that isn't JSON) ─
        // Falls through to file parser first, then generic
        let fileEntries = parseOutputForFileResults(command: command, output: output)
        if !fileEntries.isEmpty { return fileEntries }

        return parseGenericListOutput(command: command, output: output, panelKey: panelKey)
    }

    // ── Reminders parser ───────────────────────────────────────────────

    func parseRemOutput(_ output: String) -> [LivePanelMode.ResultEntry] {
        // rem list output: "[ ] Buy milk   due: tomorrow" or "[x] Call mom"
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("No reminders") && !$0.hasPrefix("---") }
        guard !lines.isEmpty else { return [] }

        return lines.compactMap { line -> LivePanelMode.ResultEntry? in
            let isDone =
                line.hasPrefix("[x]") || line.hasPrefix("[X]") || line.hasPrefix("✓")
                || line.hasPrefix("✅")
            let isPending = line.hasPrefix("[ ]") || line.hasPrefix("○") || line.hasPrefix("•")

            guard isDone || isPending else {
                // Still treat plain lines as reminder entries if they look like tasks
                if line.count < 3 || line.hasPrefix("{") { return nil }
                return LivePanelMode.ResultEntry(
                    name: line, path: "", subtitle: "", icon: "checkmark.circle")
            }

            var text = line
            // Strip leading marker
            for prefix in ["[x] ", "[X] ", "[ ] ", "✓ ", "✅ ", "○ ", "• "] {
                if text.hasPrefix(prefix) {
                    text = String(text.dropFirst(prefix.count))
                    break
                }
            }

            // Extract "due: ..." from end
            var subtitle = ""
            if let dueRange = text.range(of: #"\s+due:\s*.+"#, options: .regularExpression) {
                subtitle = String(text[dueRange]).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "due: ", with: "Due: ")
                text = String(text[..<dueRange.lowerBound])
            }

            let icon = isDone ? "checkmark.circle.fill" : "circle"
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return LivePanelMode.ResultEntry(name: name, path: "", subtitle: subtitle, icon: icon)
        }
    }

    // ── Process parser ─────────────────────────────────────────────────

    func parseProcessOutput(_ output: String) -> [LivePanelMode.ResultEntry] {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return [] }

        var entries: [LivePanelMode.ResultEntry] = []
        // Detect header line (PID USER %CPU %MEM COMMAND etc.)
        let hasHeader =
            lines.first?.uppercased().contains("PID") == true
            || lines.first?.uppercased().contains("COMMAND") == true

        for (i, line) in lines.enumerated() {
            if i == 0 && hasHeader { continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            // Standard ps -ef format: UID PID PPID C STIME TTY TIME CMD
            // ps aux format: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
            let pid: String
            let cmdName: String
            var subtitle = ""

            if let pidInt = Int(parts[1]) {
                // ps aux: USER PID %CPU %MEM ... COMMAND
                pid = "\(pidInt)"
                let cpu = parts.count > 2 ? parts[2] : ""
                let mem = parts.count > 3 ? parts[3] : ""
                cmdName =
                    parts.count > 10
                    ? (parts[10...].joined(separator: " ") as NSString).lastPathComponent : parts[1]
                if !cpu.isEmpty { subtitle = "CPU: \(cpu)%  MEM: \(mem)%" }
            } else if let pidInt = Int(parts[0]) {
                // simple format: PID NAME
                pid = "\(pidInt)"
                cmdName =
                    parts.count > 1
                    ? (parts[1...].joined(separator: " ") as NSString).lastPathComponent : line
            } else {
                // last column is command
                let rawCmd = parts.last ?? line
                cmdName = (rawCmd as NSString).lastPathComponent
                pid = parts.count > 1 ? parts[1] : ""
                subtitle = pid.isEmpty ? "" : "PID \(pid)"
            }

            let name = (cmdName as NSString).lastPathComponent
            guard !name.isEmpty, name != "0", name.count > 1 else { continue }
            if subtitle.isEmpty && !pid.isEmpty { subtitle = "PID \(pid)" }

            entries.append(
                LivePanelMode.ResultEntry(
                    name: name, path: "", subtitle: subtitle,
                    icon: "cpu"))
        }
        return entries
    }

    // ── Network parser ─────────────────────────────────────────────────

    func parseNetworkOutput(command: String, output: String) -> [LivePanelMode.ResultEntry]
    {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Proto") && !$0.hasPrefix("Active") }

        return lines.prefix(30).compactMap { line -> LivePanelMode.ResultEntry? in
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 4 else { return nil }
            // netstat: Proto RecvQ SendQ LocalAddr ForeignAddr State
            let local = parts.count > 3 ? parts[3] : parts[1]
            let state = parts.last ?? ""
            return LivePanelMode.ResultEntry(
                name: local, path: "", subtitle: state,
                icon: "network")
        }
    }

    // ── Brew parser ────────────────────────────────────────────────────

    func parseBrewOutput(command: String, output: String) -> [LivePanelMode.ResultEntry] {
        let cmd = command.lowercased()
        let isOutdated = cmd.contains("outdated")
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.hasPrefix("Warning") }
        guard !lines.isEmpty else { return [] }

        return lines.compactMap { line -> LivePanelMode.ResultEntry? in
            let parts = line.components(separatedBy: .whitespaces)
            let name = parts.first ?? line
            guard !name.isEmpty, name.count > 1 else { return nil }
            let subtitle: String
            if isOutdated && parts.count >= 3 {
                subtitle = "\(parts[1]) → \(parts[2])"  // current → latest
            } else if parts.count > 1 {
                subtitle = parts.dropFirst().joined(separator: " ")
            } else {
                subtitle = ""
            }
            return LivePanelMode.ResultEntry(
                name: name, path: "",
                subtitle: subtitle,
                icon: isOutdated ? "arrow.up.circle" : "shippingbox")
        }
    }

    // ── Git parser ─────────────────────────────────────────────────────

    func parseGitOutput(command: String, output: String) -> [LivePanelMode.ResultEntry] {
        let cmd = command.lowercased()
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        if cmd.contains("git log") {
            // "abc1234 Fix bug in login" or "commit abc1234\n Author: ...\n    message"
            return lines.prefix(20).compactMap { line -> LivePanelMode.ResultEntry? in
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { return nil }
                let hash = String(parts[0].prefix(7))
                let msg = parts.dropFirst().joined(separator: " ")
                return LivePanelMode.ResultEntry(
                    name: msg, path: "", subtitle: hash, icon: "arrow.triangle.branch")
            }
        } else if cmd.contains("git branch") {
            return lines.compactMap { line -> LivePanelMode.ResultEntry? in
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                guard !name.isEmpty else { return nil }
                let isCurrent = line.hasPrefix("*")
                return LivePanelMode.ResultEntry(
                    name: name, path: "",
                    subtitle: isCurrent ? "current" : "",
                    icon: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
            }
        } else if cmd.contains("git diff --stat") || cmd.contains("git status") {
            return lines.compactMap { line -> LivePanelMode.ResultEntry? in
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard let name = parts.first, name.contains(".") || name.contains("/") else {
                    return nil
                }
                let stat = parts.dropFirst().joined(separator: " ")
                return LivePanelMode.ResultEntry(
                    name: name, path: "", subtitle: stat,
                    icon: "doc.badge.ellipsis")
            }
        }
        return parseGenericListOutput(command: command, output: output, panelKey: "git")
    }

    // ── Generic list parser ────────────────────────────────────────────

    func parseGenericListOutput(command: String, output: String, panelKey: String)
        -> [LivePanelMode.ResultEntry]
    {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Don't show generic results for conversational / single-line outputs
        guard lines.count >= 3 else { return [] }
        // Skip JSON blobs
        if output.trimmingCharacters(in: .whitespaces).hasPrefix("{") { return [] }
        if output.trimmingCharacters(in: .whitespaces).hasPrefix("[") { return [] }

        // Pick icon based on panel key
        let icon: String = {
            switch panelKey {
            case "calendar": return "calendar"
            case "notes": return "note.text"
            case "mail": return "envelope"
            case "contacts": return "person.crop.circle"
            case "music": return "music.note"
            default: return "list.bullet"
            }
        }()

        return lines.prefix(50).compactMap { line -> LivePanelMode.ResultEntry? in
            // Skip separator lines and very short lines
            guard line.count > 2,
                !line.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "─" }),
                !line.hasPrefix("---"), !line.hasPrefix("===")
            else { return nil }

            // Split "name: detail" or "name — detail" into name + subtitle
            let separators = ["\t", " — ", " - ", ": "]
            for sep in separators {
                if let range = line.range(of: sep) {
                    let name = String(line[..<range.lowerBound]).trimmingCharacters(
                        in: .whitespaces)
                    let sub = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        return LivePanelMode.ResultEntry(
                            name: name, path: "", subtitle: sub, icon: icon)
                    }
                }
            }
            return LivePanelMode.ResultEntry(name: line, path: "", subtitle: "", icon: icon)
        }
    }

    /// Parses shell command output for file/path lists to display in the live panel.
    func parseOutputForFileResults(command: String, output: String) -> [LivePanelMode
        .ResultEntry]
    {
        let cmd = command.trimmingCharacters(in: .whitespaces).lowercased()

        // du is a size-query command, not a file lister — keep result in chat only
        if cmd.hasPrefix("du ") || cmd == "du" { return [] }
        // stat, wc, grep -c, etc. — single-line summaries, not file lists
        if cmd.hasPrefix("stat ") || cmd.hasPrefix("wc ") { return [] }

        let isListCommand =
            cmd.hasPrefix("find ") || cmd.hasPrefix("ls") || cmd.hasPrefix("locate ")
            || cmd.contains(" find ") || cmd.contains("| find") || cmd.contains("| ls")
            || cmd.contains("-name ") || cmd.contains("-type f")

        let rawLines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Detect `ls -l` / `ls -lt` format: lines like "-rw-r--r-- 1 user staff 123456 Mar 10 file.jpg"
        let isLsLongFormat =
            rawLines.first?.range(of: #"^[-dlrwxst]{10}\s"#, options: .regularExpression) != nil
            || rawLines.first?.lowercased().hasPrefix("total") == true

        // Extract context folder path for resolving relative names
        let contextFolder: String? = {
            // From the command itself: find /path ... → /path
            if cmd.hasPrefix("find /") || cmd.hasPrefix("find ~/") {
                let parts = command.components(separatedBy: " ")
                if parts.count > 1 {
                    let p =
                        parts[1].hasPrefix("~")
                        ? NSHomeDirectory() + parts[1].dropFirst() : parts[1]
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir),
                        isDir.boolValue
                    {
                        return p
                    }
                }
            }
            // From ls command: ls /path or ls -lt /path
            if cmd.hasPrefix("ls") {
                let parts = command.components(separatedBy: " ").filter {
                    !$0.hasPrefix("-") && !$0.isEmpty
                }
                let pathPart = parts.dropFirst().first ?? ""
                let p =
                    pathPart.hasPrefix("~") ? NSHomeDirectory() + pathPart.dropFirst() : pathPart
                if !p.isEmpty {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir),
                        isDir.boolValue
                    {
                        return p
                    }
                }
            }
            return nil
        }()

        // Also activate if output lines are mostly file paths
        let pathLikeLines = rawLines.filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }.count
        let looksLikePaths = rawLines.count > 1 && pathLikeLines >= rawLines.count / 2

        guard isListCommand || looksLikePaths, !rawLines.isEmpty, rawLines.count <= 500 else {
            return []
        }

        let fm = FileManager.default
        var entries: [LivePanelMode.ResultEntry] = []
        var seen = Set<String>()

        func makeEntry(path: String) {
            guard !seen.contains(path) else { return }
            seen.insert(path)
            guard fm.fileExists(atPath: path) else { return }

            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)

            let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            let size = attrs[.size] as? Int ?? 0
            let modified = attrs[.modificationDate] as? Date
            let ext = url.pathExtension.lowercased()

            let icon: String = {
                if isDir.boolValue { return "folder.fill" }
                switch ext {
                case "pdf": return "doc.richtext"
                case "png", "jpg", "jpeg", "gif", "heic",
                    "webp", "tiff", "raw", "arw", "cr2":
                    return "photo"
                case "mp4", "mov", "mkv", "avi", "m4v": return "film"
                case "mp3", "aac", "flac", "wav", "m4a",
                    "ogg", "opus":
                    return "waveform"
                case "zip", "gz", "tar", "7z", "rar", "bz2": return "archivebox"
                case "swift", "py", "js", "ts", "sh", "rb",
                    "go", "rs", "cpp", "c", "java":
                    return "chevron.left.forwardslash.chevron.right"
                case "md", "txt", "rtf": return "doc.text"
                case "json", "yaml", "yml", "toml", "xml": return "curlybraces"
                default: return "doc"
                }
            }()

            // Subtitle: file size + relative time if available
            var subtitle = ""
            if size > 0 {
                subtitle = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            }
            if let mod = modified {
                let rel = RelativeDateTimeFormatter().localizedString(for: mod, relativeTo: Date())
                subtitle = subtitle.isEmpty ? rel : "\(subtitle) · \(rel)"
            }
            if subtitle.isEmpty { subtitle = isDir.boolValue ? "Folder" : ext.uppercased() }

            entries.append(
                LivePanelMode.ResultEntry(
                    name: url.lastPathComponent, path: path,
                    subtitle: subtitle, icon: icon))
        }

        for line in rawLines {
            // Skip ls -l header and permission strings
            if line.lowercased().hasPrefix("total") { continue }
            if line.range(of: #"^[-dlrwxst]{10}\s"#, options: .regularExpression) != nil {
                // ls -l line: last whitespace-separated token is the filename
                if isLsLongFormat, let folder = contextFolder {
                    // Handle ls -l output: extract filename (last column, may contain spaces after arrow)
                    // Format: perms links user group size mon day time/year name
                    // Split on 2+ spaces or use fixed column approach
                    let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 9 {
                        // name starts at index 8, join remaining (handles spaces in names via -> symlink)
                        let namePart =
                            parts[8...].joined(separator: " ").components(separatedBy: " -> ").first
                            ?? parts[8]
                        let fullPath = folder + "/" + namePart
                        makeEntry(path: fullPath)
                    }
                }
                continue
            }

            // du output: "size\tpath"
            var candidate = line
            if let tab = line.range(of: "\t") {
                candidate = String(line[tab.upperBound...])
            }
            // Expand ~
            if candidate.hasPrefix("~") {
                candidate = NSHomeDirectory() + String(candidate.dropFirst())
            }

            if candidate.hasPrefix("/") {
                makeEntry(path: candidate)
            } else if let folder = contextFolder, !candidate.isEmpty,
                !candidate.hasPrefix("-") && !candidate.hasPrefix("#")
            {
                // Relative name — resolve against context folder
                makeEntry(path: folder + "/" + candidate)
            }
        }

        return entries
    }

    // MARK: - Terminal Drawer
    @ViewBuilder
    var terminalDrawer: some View {
        let hasLines = !panelConsoleLines.isEmpty
        // Only show the terminal drawer when there's something to show
        let hasActivity = !remPanelChatMessages.isEmpty || remPanelIsProcessing || hasLines
        let isOpen = showPanelConsole && hasActivity
        Group {
            if hasActivity {
                VStack(spacing: 0) {
                    terminalDrawerHandle(isOpen: isOpen, hasLines: hasLines)
                    if isOpen {
                        terminalDrawerBody
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .background(Color.black.opacity(isOpen ? 0.55 : 0))
                .clipShape(RoundedRectangle(cornerRadius: isOpen ? 10 : 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: isOpen ? 10 : 22, style: .continuous)
                        .strokeBorder(Color.green.opacity(isOpen ? 0.18 : 0), lineWidth: 0.75)
                )
                .padding(.horizontal, isOpen ? 10 : 50)
                .padding(.bottom, isOpen ? 8 : 4)
                .padding(.top, 2)
                .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isOpen)
            }
        }
    }

    @ViewBuilder
    func terminalDrawerHandle(isOpen: Bool, hasLines: Bool) -> some View {
        let ck = activeConsoleKey
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                let opening = !showPanelConsole
                panelShowConsoleMap[ck] = opening
                let term = panelTerminal(for: ck)  // always create
                if opening {
                    // Give the embedded terminal focus so keyboard works
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        term.terminalView.window?.makeFirstResponder(term.terminalView)
                    }
                } else {
                    // Return focus to search field when drawer closes
                    isSearchFieldFocused = true
                }
            }
        } label: {
            ZStack(alignment: .center) {
                Rectangle().fill(Color.black.opacity(isOpen ? 0.65 : 0.32))
                HStack(spacing: 8) {
                    Capsule()
                        .fill(Color.white.opacity(isOpen ? 0.3 : 0.18))
                        .frame(width: 36, height: 4)
                    if remPanelIsProcessing {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                    }
                    Text(
                        remPanelIsProcessing
                            ? (isOpen ? "running…" : "Terminal • running…")
                            : "Terminal"
                    )
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(remPanelIsProcessing ? 0.7 : 0.45))
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.5))
                }
                .padding(.horizontal, 14)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 26)
    }

    @ViewBuilder
    var terminalDrawerBody: some View {
        let ck = activeConsoleKey
        VStack(spacing: 0) {
            // ── Header bar ──────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.7))
                Text("Live Terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.7))
                    .textCase(.uppercase).tracking(0.5)
                if remPanelIsProcessing {
                    ProgressView().scaleEffect(0.45).tint(.green)
                    Text("running").font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.5))
                }
                Spacer()
                // Clear terminal screen button
                Button {
                    panelTerminalControllers[ck]?.sendCommand("clear")
                } label: {
                    Label("Clear", systemImage: "clear").font(.system(size: 9))
                        .foregroundStyle(Color.green.opacity(0.5))
                }.buttonStyle(.plain)
                // Close drawer button
                Button {
                    withAnimation { panelShowConsoleMap[ck] = false }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.5))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.black.opacity(0.55))

            Divider().overlay(Color.green.opacity(0.15))

            // ── Real SwiftTerm PTY ───────────────────────────────────────────
            PanelTerminalView(controller: panelTerminal(for: ck))
                .frame(height: panelConsoleHeight)
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
    }

    // MARK: - Quick Actions Column
    @ViewBuilder
    func panelQuickActionsColumn(_ actions: [PanelAction]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quick Actions")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            if actions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20)).foregroundStyle(.tertiary)
                    Text("Add shortcuts\nin Settings")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(actions) { action in
                            Button {
                                action.action()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: action.icon)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 18)
                                    Text(action.label)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(width: 148)
        .background(.primary.opacity(0.03))
    }

    // MARK: - App Panel Split View (2-column: 80% AI chat / 20% quick actions)
    @ViewBuilder
    var appPanelView: some View {
        let ctx = searchState.contextApp
        let meta = smartQueryMeta
        let key = searchState.activeSmartQueryKey ?? ""
        let isReminders = key == "reminders"
        let isClipboard = key == "clipboard"
        let isCompactScope = key == "clipboard" || key == "notifications"
        let hasChatHistory = !isCompactScope && !remPanelChatMessages.isEmpty
        let isEmbeddedDockWorkspace = showContextInDock && !showMediaLayer

        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            HStack(spacing: 8) {
                if isCompactScope {
                    EmptyView()
                } else if let icon = ctx?.icon {
                    Image(nsImage: icon)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: meta.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(ctx?.name ?? meta.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = ctx?.subtitle, !subtitle.isEmpty, ctx?.resultType != .application
                {
                    Text("·")
                        .font(.caption).foregroundStyle(.tertiary)
                    Text(subtitle)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if hasChatHistory {
                    Button {
                        let k = searchState.activeSmartQueryKey ?? ""
                        remPanelChatMessages = []
                        AppPanelChatStore.shared.clear(for: k)
                    } label: {
                        Label("Clear chat", systemImage: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                let openPath = ctx?.appPath ?? ""
                if isEmbeddedDockWorkspace {
                    Button("Exit Scope") {
                        clearSearchContext()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else {
                    Text("esc to exit")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if !openPath.isEmpty && !isEmbeddedDockWorkspace {
                    Button("Open \(ctx?.name ?? meta.label)") {
                        NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: openPath),
                            configuration: NSWorkspace.OpenConfiguration())
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)

            Divider()

            // ── Tool-removal cleanup banner ──────────────────────────
            if !isCompactScope, let removedTool = removedToolBannerName {
                HStack(spacing: 8) {
                    Image(systemName: "trash.circle")
                        .foregroundStyle(.orange)
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\"\(removedTool)\" was removed from this panel")
                            .font(.system(size: 11, weight: .medium))
                        Text("Clear old chat history related to this tool?")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Chat") {
                        let k = searchState.activeSmartQueryKey ?? ""
                        remPanelChatMessages = []
                        AppPanelChatStore.shared.clear(for: k)
                        removedToolBannerName = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    Button {
                        removedToolBannerName = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            // ── Body: 2 columns + terminal drawer ────────────
            VStack(spacing: 0) {

                // ── Inner: height-constrained chat area ──────────
                VStack(spacing: 0) {
                    HStack(spacing: 0) {

                        // ── Column 1: AI Chat or Safari Tab List ─────────
                        VStack(spacing: 0) {
                            if key == "clipboard" {
                                clipboardScopeView
                            } else if key == "notifications" {
                                notificationScopeView
                            } else if key == "safari" {
                                // ── Safari Tab List header ───────────────────
                                HStack(spacing: 6) {
                                    Image(systemName: "safari")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                    Text("Open Tabs")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .tracking(0.4)
                                    Spacer()
                                    Text("\(appPanelDisplayedItems.count) tabs")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.06))

                                Divider()

                                safariTabListView

                            } else {
                                // ── Normal AI Chat column ────────────────────
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                    Text("AI Assistant")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .tracking(0.4)
                                    Spacer()
                                    if remPanelIsProcessing {
                                        ProgressView().scaleEffect(0.55)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.06))

                                Divider()

                                // Chat messages or empty state
                                if hasChatHistory {
                                    ScrollViewReader { proxy in
                                        ScrollView {
                                            VStack(alignment: .leading, spacing: 8) {
                                                ForEach(remPanelChatMessages) { msg in
                                                    remChatBubble(msg).id(msg.id)
                                                }
                                                if remPanelIsProcessing {
                                                    HStack(spacing: 6) {
                                                        ProgressView().scaleEffect(0.6)
                                                        Text("Thinking…")
                                                            .font(.system(size: 11))
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 4)
                                                    .id("typing")
                                                }
                                            }
                                            .padding(10)
                                        }
                                        .onChange(of: remPanelChatMessages.count) { _, _ in
                                            if let last = remPanelChatMessages.last {
                                                withAnimation {
                                                    proxy.scrollTo(last.id, anchor: .bottom)
                                                }
                                            }
                                        }
                                        .onChange(of: remPanelIsProcessing) { _, _ in
                                            withAnimation {
                                                proxy.scrollTo("typing", anchor: .bottom)
                                            }
                                        }
                                    }
                                } else {
                                    panelWelcomeView(ctx: ctx, meta: meta, key: key)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.02))

                        // ── Live Panel: slides in from right (hidden by default) ──
                        if livePanelVisible {
                            Divider()
                            livePanelView
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .trailing).combined(with: .opacity)
                                    ))
                        }
                    }
                    .animation(
                        .spring(response: 0.28, dampingFraction: 0.85), value: livePanelVisible)

                }  // end inner height-constrained VStack
                .frame(maxHeight: 500)

                // ── Terminal Drawer (outside height constraint — always visible) ──
                if !isCompactScope {
                    terminalDrawer
                }

            }  // end outer VStack
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isSearchFieldFocused = true }
        )
        .transition(.opacity)
        .task(id: key) {
            guard searchState.appPanelAllItems.isEmpty else { return }
            reloadAppPanelData(for: key)
            if isReminders { checkRemInstalled() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBinaryDiscovered)) { note in
            if isReminders, let name = note.userInfo?["toolName"] as? String, name == "rem" {
                remIsInstalled = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .appPanelToolRemoved)) { note in
            if let toolName = note.userInfo?["toolName"] as? String {
                // Show the cleanup banner for the currently open panel
                removedToolBannerName = toolName
            }
        }
    }

    // MARK: - Panel Welcome / Onboarding View

    /// Context-aware welcome card shown when no chat history exists yet.
    @ViewBuilder
    func panelWelcomeView(
        ctx: SearchContextApp?,
        meta: (icon: String, label: String, appPath: String),
        key: String
    ) -> some View {
        let (greeting, subtext) = panelWelcomeText(ctx: ctx, key: key)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // ── Greeting card ──────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        // Context icon
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(width: 36, height: 36)
                            if let icon = ctx?.icon {
                                Image(nsImage: icon)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(width: 22, height: 22)
                            } else {
                                Image(systemName: meta.icon)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(greeting)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(subtext)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Contextual greeting + subtext for the welcome card.
    func panelWelcomeText(ctx: SearchContextApp?, key: String) -> (String, String) {
        if let ctx = ctx {
            switch ctx.resultType {
            case .folder:
                return (
                    "Ready to help with \(ctx.name)",
                    "I can list, search, organize, and convert files here. Results appear on the right automatically."
                )
            case .file, .document:
                let ext =
                    (ctx.filePath ?? "").components(separatedBy: ".").last?.uppercased() ?? "file"
                return (
                    "Working on \(ctx.name)",
                    "I can inspect, convert, extract info, or transform this \(ext) file using installed CLI tools."
                )
            case .contact:
                return (
                    "Contact: \(ctx.name)",
                    "I can send an email, compose a message, look up info, or copy contact details."
                )
            case .application:
                return (
                    "\(ctx.name) Assistant",
                    "Ask me anything about \(ctx.name). I can run commands, check status, and take actions on your behalf."
                )
            case .cliTool:
                let isTUI = TerminalAIBridge.shared.isTUICommand(ctx.name)
                if isTUI {
                    return (
                        "\(ctx.name)",
                        "This is a TUI app. Say \"launch \(ctx.name)\" to open it in the terminal, or ask me what it does."
                    )
                }
                return (
                    "\(ctx.name) Assistant",
                    "I know this tool's commands and flags. Ask me to run it, explain options, or chain operations."
                )
            default:
                return ("AI Assistant", "Ask me anything about \(ctx.name).")
            }
        }
        switch key {
        case "clipboard":
            return (
                "Clipboard",
                "Browse copied text, files, folders, and screenshots. Ask me to summarize, find, or compare clipboard items."
            )
        case "reminders":
            return (
                "Reminders Assistant",
                "I manage your macOS Reminders. Add tasks, set due dates, list and complete reminders — just ask."
            )
        case "calendar":
            return (
                "Calendar Assistant",
                "I can show today's events, add appointments, and help you manage your schedule."
            )
        case "notes":
            return (
                "Notes Assistant",
                "I can search, create, and edit your Notes. Just describe what you need."
            )
        case "mail":
            return (
                "Mail Assistant",
                "I can search emails, check unread count, and help you draft or manage messages."
            )
        case "photos":
            return (
                "Photos Assistant",
                "I can search your photo library, show recent imports, and help organize albums."
            )
        case "messages":
            return (
                "Messages Assistant", "I can show recent conversations and help you draft replies."
            )
        case "amphetamine":
            return (
                "Amphetamine",
                "Keep your Mac awake. Start a timed session, check status, or end a session — just ask."
            )
        case "homebrew":
            return (
                "Homebrew",
                "Install, update, and manage CLI tools and Mac apps. Search packages, check for updates, clean up disk space — just ask."
            )
        default:
            let label =
                settings.customAppEntries.first(where: { $0.key == key })?.label ?? key.capitalized
            return (
                "\(label) Assistant",
                "I'm ready to help with \(label). Ask me anything or run actions directly."
            )
        }
    }

    /// Contextual suggested prompts for each panel type.
    func panelSuggestedPrompts(ctx: SearchContextApp?, key: String) -> [String] {
        if let ctx = ctx {
            switch ctx.resultType {
            case .cliTool:
                let toolCmd = ctx.name
                let pkg = TerminalPackageManager.shared.packages.first(where: {
                    $0.name == ctx.name || $0.command == ctx.name
                })
                let isTUI = TerminalAIBridge.shared.isTUICommand(toolCmd)
                if isTUI {
                    return [
                        "Launch \(toolCmd)",
                        "What does \(toolCmd) do?",
                        "Show \(toolCmd) help",
                        "How do I use \(toolCmd)?",
                    ]
                }
                // Use first few subcommands as prompt starters
                if let subs = pkg?.subcommands, !subs.isEmpty {
                    let subPrompts = subs.prefix(3).map { "Run: \(toolCmd) \($0)" }
                    return Array(subPrompts) + ["What does \(toolCmd) do?"]
                }
                return [
                    "What can \(toolCmd) do?",
                    "Show \(toolCmd) --help",
                    "Run \(toolCmd) with common options",
                    "What version is \(toolCmd)?",
                ]
            case .folder:
                let name = ctx.name
                return [
                    "List all PDFs in \(name)",
                    "Show the largest files here",
                    "Find files modified today",
                    "How much space is \(name) using?",
                ]
            case .file, .document:
                let ext = (ctx.filePath ?? "").components(separatedBy: ".").last?.lowercased() ?? ""
                switch ext {
                case "pdf":
                    return [
                        "Extract text from this PDF", "How many pages does this have?",
                        "Compress this PDF",
                    ]
                case "mp4", "mov", "mkv", "avi":
                    return ["Show video info", "Extract audio as MP3", "Compress to smaller size"]
                case "mp3", "flac", "wav", "m4a":
                    return ["Show audio metadata", "Convert to MP3", "Get duration and bitrate"]
                case "jpg", "jpeg", "png", "heic", "webp":
                    return [
                        "Show image dimensions and size", "Convert to JPEG", "Strip EXIF metadata",
                    ]
                case "zip", "tar", "gz":
                    return ["List contents", "Extract here", "Show total compressed size"]
                case "json":
                    return ["Pretty-print this file", "Show top-level keys", "Validate JSON"]
                case "csv":
                    return ["Show first 10 rows", "Count rows", "Show column names"]
                default:
                    return ["Show file info", "Open in default app", "Copy path to clipboard"]
                }
            case .contact:
                return [
                    "Send \(ctx.name) an email",
                    "Copy \(ctx.name)'s email address",
                    "Show all contact details",
                ]
            case .application:
                let name = ctx.name
                return [
                    "Is \(name) running?",
                    "Show \(name) memory usage",
                    "What version is \(name)?",
                ]
            default:
                return ["Tell me about this", "Show related info", "What can you do here?"]
            }
        }
        switch key {
        case "clipboard":
            return [
                "Summarize my latest clipboard item",
                "Find copied files",
                "Show screenshots",
                "Compare the last two copied texts",
            ]
        case "reminders":
            return [
                "Show today's tasks",
                "Add: buy groceries — due tomorrow",
                "List all overdue reminders",
                "Mark my next task as done",
            ]
        case "calendar":
            return [
                "What's on my calendar today?", "Add meeting tomorrow at 3pm",
                "Show this week's events",
            ]
        case "notes":
            return [
                "Search my notes for 'project'", "Create a new note called 'Ideas'",
                "List recent notes",
            ]
        case "mail":
            return ["How many unread emails?", "Show emails from today", "Search for 'invoice'"]
        case "photos":
            return ["Show photos from this week", "Find screenshots", "How many photos do I have?"]
        case "amphetamine":
            return [
                "Keep awake for 1 hour",
                "Keep awake for 30 minutes",
                "Is a session active?",
                "End the current session",
                "Keep awake until I say stop",
            ]
        case "homebrew":
            return [
                "What packages are outdated?",
                "Update and upgrade everything",
                "Install a package",
                "Clean up old versions and free disk space",
                "List all installed packages",
                "Show running services",
            ]
        default:
            let label =
                settings.customAppEntries.first(where: { $0.key == key })?.label ?? key.capitalized
            return ["What can you do in \(label)?", "Show status", "Run a quick action"]
        }
    }

    // Small chat bubble for the rem assistant column
    @ViewBuilder
    func remChatBubble(_ msg: AIChatMessage) -> some View {
        switch msg.role {
        case .tool:
            // Terminal command chip — shown inline while command runs
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green.opacity(0.8))
                Text(msg.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.9))
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5)
            )
            .frame(maxWidth: .infinity, alignment: .leading)

        case .approval:
            // Inline approval card — like Claude Code's "run this command?" prompt
            let parts = (msg.structuredData ?? "").components(separatedBy: "|||/")
            let purpose = parts.first ?? ""
            let risk = parts.count > 1 ? parts[1] : "Unknown"
            let isHighRisk =
                risk.lowercased().contains("high") || risk.lowercased().contains("critical")
            let isPending = terminalBridge.pendingApproval != nil

            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHighRisk ? Color.orange : Color.accentColor)
                    Text("Run command?")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if isHighRisk {
                        Text(risk)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                // Purpose
                if !purpose.isEmpty {
                    Text(purpose)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // Command
                Text(msg.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Buttons
                HStack(spacing: 8) {
                    Button("Deny") {
                        TerminalAIBridge.shared.denyCommand()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(!isPending)

                    Button {
                        TerminalAIBridge.shared.approveCommand(msg.content)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 9))
                            Text("Approve & Run")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(
                        isHighRisk ? Color.orange : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .disabled(!isPending)
                }
            }
            .padding(10)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHighRisk ? Color.orange.opacity(0.35) : Color.accentColor.opacity(0.25),
                        lineWidth: 0.75)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isPending ? 1 : 0.5)

        case .user:
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 24)
                Text(msg.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .frame(maxWidth: 180, alignment: .trailing)
            }
        case .assistant:
            let brewTools = extractBrewInstalls(from: msg.content)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 0) {
                    Text(msg.content)
                        .font(.system(size: 12))
                        .foregroundStyle(msg.isError ? .red : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            msg.isError
                                ? AnyShapeStyle(Color.red.opacity(0.1))
                                : AnyShapeStyle(Color.primary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .frame(maxWidth: 180, alignment: .leading)
                    Spacer(minLength: 24)
                }
                // Inline install buttons — appear whenever AI says "brew install X"
                if !brewTools.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(brewTools, id: \.self) { tool in
                            BrewInstallButton(toolName: tool) {
                                // Auto-retry the last user query now that the tool is installed
                                if let lastQuery = remPanelChatMessages.last(where: {
                                    $0.role == .user
                                })?.content {
                                    searchState.query = lastQuery
                                    handleRemPanelQuery()
                                }
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }

    /// Extracts all tool names from "brew install <tool>" patterns in a string.
    func extractBrewInstalls(from text: String) -> [String] {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"brew install ([a-zA-Z0-9][a-zA-Z0-9_\-\.]*)"#,
                options: .caseInsensitive)
        else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> String? in
                guard match.numberOfRanges > 1 else { return nil }
                let r = match.range(at: 1)
                return r.location != NSNotFound ? ns.substring(with: r) : nil
            }
    }

    @ViewBuilder
    func remHintRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "return")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text("\"\(text)\"")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    /// Directly triggers the data load for a given app panel key.
}
