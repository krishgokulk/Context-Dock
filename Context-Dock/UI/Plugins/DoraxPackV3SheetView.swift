// Context-Dock/UI/Plugins/DoraxPackV3SheetView.swift
// Unified 680 × 440 Result Sheet renderer for `.doraxpack` v3 commands (`list`, `grid`, `detail`, `form`, `instant`, `notch`, `cli`, `ai`).

import AppKit
import SwiftUI

struct DoraxPackV3SheetView: View {
    let bound: DoraxBoundCommand
    @ObservedObject var prompt: AppChatPromptModel

    @ObservedObject private var runtime = DoraxPackV3Runtime.shared
    @ObservedObject private var registry = DoraxPackV3Registry.shared
    @ObservedObject private var aura = DockAuraEngine.shared
    @ObservedObject private var headerBar = ExtensionHeaderBarState.shared
    @Environment(\.sharesOneCard) private var sharesOneCard

    @State private var selectedFilter: String = "All"
    @State private var selectedItemID: String? = nil
    @State private var showActionsPopover: Bool = false
    @State private var actionSearchText: String = ""
    @State private var selectedActionIndex: Int = 0
    @State private var pendingDestructiveAction: (action: DoraxItemAction, item: DoraxCommandItem?)? = nil
    @State private var activeOverlay: SheetOverlay? = nil
    @State private var formValues: [String: String] = [:]

    private enum SheetOverlay: Equatable {
        case logs
        case configure
    }

    private var pack: DoraxPackV2 { bound.pack }
    private var command: DoraxPackCommand { bound.command }

    /// Unified Dock Surface rule: driven directly by the launcher's single input bar (`prompt.query`).
    private var effectiveQuery: String {
        prompt.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cacheEntry: DoraxCommandCacheEntry {
        runtime.state(packID: pack.id, commandID: command.id, filter: selectedFilter == "All" ? "" : selectedFilter)
    }

    private var output: DoraxCommandOutput? { cacheEntry.output }

    private var filterOptions: [String] {
        let declared = output?.filterOptions ?? command.filterOptions ?? []
        if declared.isEmpty { return [] }
        return declared.contains("All") ? declared : (["All"] + declared)
    }

    private var filteredItems: [DoraxCommandItem] {
        guard let items = output?.items else { return [] }
        let q = effectiveQuery.lowercased()
        return items.filter { item in
            if selectedFilter != "All", let cat = item.category, !cat.isEmpty {
                if cat.caseInsensitiveCompare(selectedFilter) != .orderedSame {
                    return false
                }
            }
            guard !q.isEmpty else { return true }
            let hay = "\(item.title) \(item.subtitle ?? "") \(item.category ?? "") \(item.keywords.joined(separator: " "))".lowercased()
            return hay.contains(q)
        }
    }

    private var selectedItem: DoraxCommandItem? {
        if let id = selectedItemID, let found = filteredItems.first(where: { $0.id == id }) {
            return found
        }
        return filteredItems.first
    }

    private var effectiveAppearance: DoraxPackAppearance? {
        let cfg = registry.commandConfig(packID: pack.id, commandID: command.id)
        if !cfg.tintHex.isEmpty {
            let glow = bound.effectiveAppearance?.glow ?? .soft
            return DoraxPackAppearance(tint: cfg.tintHex, glow: glow == .none ? .soft : glow)
        }
        return output?.appearance ?? bound.effectiveAppearance
    }

    private var accentColor: Color {
        effectiveAppearance?.tint.flatMap { DockAuraEngine.color(fromHex: $0) } ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !sharesOneCard {
                topBar
                Divider().opacity(0.18)
            }

            ZStack {
                if let overlay = activeOverlay {
                    switch overlay {
                    case .logs:
                        logsView
                    case .configure:
                        configureView
                    }
                } else {
                    mainBody
                }

                if showActionsPopover, activeOverlay == nil, pendingDestructiveAction == nil {
                    Color.black.opacity(0.18)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showActionsPopover = false
                        }
                    DoraxInlineActionsDrawer(
                        entries: filteredActionEntries,
                        itemTitle: selectedItem?.title,
                        accentColor: accentColor,
                        searchText: $actionSearchText,
                        selectedIndex: $selectedActionIndex,
                        onSelect: handleDrawerEntry,
                        onDismiss: { showActionsPopover = false }
                    )
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
                }

                if let pending = pendingDestructiveAction {
                    destructiveConfirmationOverlay(action: pending.action, item: pending.item)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.18)
            bottomFooter
        }
        .frame(width: 680, height: 440, alignment: .topLeading)
        .modifier(BoardGlass(radius: 22))
        .doraxAuraRim(cornerRadius: 22, appearance: sharesOneCard ? DoraxPackAppearance(tint: nil, glow: .none) : effectiveAppearance)
        .onAppear {
            initializeFormDefaults()
            activateAura()
            installKeyBridge()
            syncHeaderBar()
            if command.mode != .form {
                Task { await refresh(force: false) }
            }
        }
        .onDisappear {
            ScopedListKeyBridge.shared.move = nil
            ScopedListKeyBridge.shared.run = nil
            ScopedListKeyBridge.shared.openActions = nil
            ScopedListKeyBridge.shared.closeOverlay = nil
            DockAuraEngine.shared.deactivate(id: "sheet:\(bound.id)")
            headerBar.reset(ifMatching: bound.id)
        }
        .onChange(of: output) { _, _ in
            syncHeaderBar()
        }
        .onChange(of: activeOverlay) { _, _ in
            syncHeaderBar()
        }
        .onChange(of: cacheEntry.isRefreshing) { _, _ in
            syncHeaderBar()
        }
        .onChange(of: prompt.query) { _, _ in
            if let first = filteredItems.first,
               selectedItemID == nil || !filteredItems.contains(where: { $0.id == selectedItemID })
            {
                selectedItemID = first.id
            }
            syncHeaderBar()
        }
        .onChange(of: selectedFilter) { _, _ in
            syncHeaderBar()
            if command.mode != .form {
                Task { await refresh(force: false) }
            }
        }
        .task(id: "\(bound.id)-\(activeOverlay == nil)-\(selectedFilter)") {
            guard activeOverlay == nil,
                  command.mode != .form,
                  let interval = command.refreshSeconds,
                  interval > 0
            else { return }
            let sleepNanos = UInt64(max(2, interval)) * 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sleepNanos)
                guard !Task.isCancelled else { break }
                await refresh(force: true)
            }
        }
        .onKeyPress(.downArrow) {
            guard activeOverlay == nil, pendingDestructiveAction == nil else { return .ignored }
            stepSelection(delta: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard activeOverlay == nil, pendingDestructiveAction == nil else { return .ignored }
            stepSelection(delta: -1)
            return .handled
        }
        .onKeyPress(.return) {
            guard activeOverlay == nil,
                  command.mode != .form,
                  pendingDestructiveAction == nil,
                  !showActionsPopover
            else { return .ignored }
            triggerPrimaryAction()
            return .handled
        }
        .onKeyPress(.escape) {
            if pendingDestructiveAction != nil {
                pendingDestructiveAction = nil
                return .handled
            }
            if activeOverlay != nil {
                activeOverlay = nil
                return .handled
            }
            _ = prompt.leaveScopeForGlobal()
            return .handled
        }
    }

    // MARK: - Top Bar (`<` Back + Live Filter + Top-Right Filter Dropdown)

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                if activeOverlay != nil {
                    activeOverlay = nil
                } else {
                    _ = prompt.leaveScopeForGlobal()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(activeOverlay != nil ? "Back to \(command.title)" : "Back to Global Context")

            Image(systemName: command.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accentColor)

            if activeOverlay == nil {
                Text(command.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let items = output?.items, !items.isEmpty {
                    Text("\(filteredItems.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                Spacer()
            } else {
                Text(activeOverlay == .logs ? "\(pack.name) — Pack Logs" : "Configure \(command.title)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            if cacheEntry.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
            }

            if activeOverlay == nil && !filterOptions.isEmpty {
                Menu {
                    ForEach(filterOptions, id: \.self) { opt in
                        Button {
                            selectedFilter = opt
                        } label: {
                            HStack {
                                Text(opt)
                                if selectedFilter == opt { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedFilter)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Button {
                Task { await refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    // MARK: - Main Body (Dispatches by `command.mode`)

    @ViewBuilder
    private var mainBody: some View {
        VStack(spacing: 0) {
            if let error = cacheEntry.lastError {
                inlineErrorBar(error)
            }

            if !missingRequiredPreferences.isEmpty {
                DoraxRequiredPreferencesView(pack: pack, missingPrefs: missingRequiredPreferences, accentColor: accentColor) {
                    Task { await refresh(force: true) }
                }
            } else {
                switch command.mode {
                case .list: listModeView
                case .grid: gridModeView
                case .detail, .cli, .instant, .ai: detailModeView
                case .form: formModeView
                case .notch: notchModePreview
                }
            }
        }
    }

    private var missingRequiredPreferences: [DoraxPackPreference] {
        (pack.metadata.preferences ?? []).filter { pref in
            guard pref.required else { return false }
            let val = DoraxPackPreferenceStore.value(for: pref, packID: pack.id) ?? ""
            return val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func inlineErrorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
            Button("Retry") {
                Task { await refresh(force: true) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
    }

    // MARK: - List + Split Detail Mode

    @ViewBuilder
    private var listModeView: some View {
        if output == nil && cacheEntry.isRefreshing {
            loadingPlaceholder
        } else if filteredItems.isEmpty {
            emptyPlaceholder(output?.emptyMessage ?? "No items match \"\(effectiveQuery)\".")
        } else {
            let hasDetail = selectedItem?.detail != nil
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredItems) { item in
                                itemRow(item, isSelected: item.id == selectedItem?.id)
                                    .id(item.id)
                                    .onTapGesture {
                                        selectedItemID = item.id
                                    }
                                    .onTapGesture(count: 2) {
                                        selectedItemID = item.id
                                        triggerPrimaryAction()
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selectedItemID) { _, newID in
                        if let id = newID {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
                .frame(width: hasDetail ? 310 : nil)

                if let detail = selectedItem?.detail {
                    Divider().opacity(0.18)
                    splitDetailPane(detail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func itemRow(_ item: DoraxCommandItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            itemLeadingIcon(item)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                ForEach(item.accessories) { acc in
                    accessoryView(acc)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func itemLeadingIcon(_ item: DoraxCommandItem) -> some View {
        if let hex = item.swatchHex, let swatch = DockAuraEngine.color(fromHex: hex) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(swatch)
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        } else if let rawPath = item.iconPath, !rawPath.isEmpty {
            let expanded = NSString(string: rawPath).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: expanded))
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: item.icon ?? command.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accentColor)
                    .frame(width: 22, height: 22)
            }
        } else if let bid = item.appIconBundleId,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: item.icon ?? command.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 22, height: 22)
        }
    }

    @ViewBuilder
    private func accessoryView(_ acc: DoraxAccessory) -> some View {
        let tint = acc.colorHex.flatMap { DockAuraEngine.color(fromHex: $0) }
        switch acc.kind.lowercased() {
        case "tag":
            Text(acc.text ?? "")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(tint ?? .primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((tint ?? Color.secondary).opacity(0.16), in: Capsule())
        case "metric":
            Text(acc.text ?? "")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(tint ?? .secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        case "progress":
            ProgressView(value: min(1, max(0, acc.progress ?? 0)))
                .frame(width: 44)
                .tint(tint ?? accentColor)
        case "color":
            Circle()
                .fill(tint ?? accentColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        case "date":
            Text(acc.text ?? "")
                .font(.system(size: 10.5))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(tint ?? .secondary)
        case "avatar":
            Text(String((acc.text ?? "?").prefix(2)).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(tint ?? accentColor, in: Circle())
        default:
            Text(acc.text ?? "")
                .font(.system(size: 11))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(tint ?? .secondary)
        }
    }

    // MARK: - Split Markdown + Right Metadata Sidebar

    private func splitDetailPane(_ detail: DoraxItemDetail) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let imgPath = detail.imagePath, !imgPath.isEmpty {
                        DoraxThumbnailImage(path: imgPath, maxPixelSize: 960, cornerRadius: 10)
                            .frame(height: 175)
                    }
                    DoraxMarkdownBlockView(markdown: detail.markdown)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !detail.metadata.isEmpty {
                Divider().opacity(0.15)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(detail.metadata) { meta in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meta.label.uppercased())
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(meta.value)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(meta.colorHex.flatMap { DockAuraEngine.color(fromHex: $0) } ?? .primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 138)
            }
        }
    }

    // MARK: - Grid Mode (Step 4: Visual Swatches & Metric Cards)

    @ViewBuilder
    private var gridModeView: some View {
        if output == nil && cacheEntry.isRefreshing {
            loadingPlaceholder
        } else if filteredItems.isEmpty {
            emptyPlaceholder(output?.emptyMessage ?? "No grid items to display.")
        } else {
            let columns = [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 10)]
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(filteredItems) { item in
                            let isSelected = item.id == selectedItem?.id
                            Group {
                                if let thumb = item.thumbnailPath, !thumb.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ZStack(alignment: .topTrailing) {
                                            DoraxThumbnailImage(path: thumb, maxPixelSize: 480, cornerRadius: 8)
                                                .frame(height: 92)
                                            if let firstAcc = item.accessories.first {
                                                accessoryView(firstAcc)
                                                    .padding(5)
                                                    .background(.black.opacity(0.55), in: Capsule())
                                                    .padding(6)
                                            }
                                        }
                                        Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                        if let sub = item.subtitle, !sub.isEmpty {
                                            Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                } else {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            itemLeadingIcon(item)
                                            Spacer()
                                            if let firstAcc = item.accessories.first { accessoryView(firstAcc) }
                                        }
                                        Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        if let sub = item.subtitle, !sub.isEmpty {
                                            Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                                }
                            }
                            .id(item.id)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isSelected ? accentColor.opacity(0.20) : Color.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isSelected ? accentColor.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
                            )
                            .onTapGesture { selectedItemID = item.id }
                            .onTapGesture(count: 2) {
                                selectedItemID = item.id
                                triggerPrimaryAction()
                            }
                        }
                    }
                    .padding(14)
                }
                .onChange(of: selectedItemID) { _, newID in
                    if let id = newID {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Detail / CLI / Instant / AI Mode

    @ViewBuilder
    private var detailModeView: some View {
        if output == nil && cacheEntry.isRefreshing {
            loadingPlaceholder
        } else if let detail = output?.detail ?? selectedItem?.detail {
            splitDetailPane(detail)
        } else if !filteredItems.isEmpty {
            listModeView
        } else {
            emptyPlaceholder(output?.emptyMessage ?? "Ready.")
        }
    }

    // MARK: - Form Mode (Step 4)

    private var formModeView: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(command.formFields ?? []) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            let binding = Binding<String>(
                                get: { formValues[field.id] ?? field.defaultValue ?? "" },
                                set: { formValues[field.id] = $0 }
                            )
                            switch field.type.lowercased() {
                            case "secret":
                                SecureField(field.placeholder ?? field.title, text: binding)
                                    .textFieldStyle(.roundedBorder)
                            case "toggle":
                                Toggle(field.placeholder ?? field.title, isOn: Binding(
                                    get: { (formValues[field.id] ?? field.defaultValue) == "true" },
                                    set: { formValues[field.id] = $0 ? "true" : "false" }
                                ))
                            case "select":
                                Picker("", selection: binding) {
                                    ForEach(field.options ?? [], id: \.self) { opt in
                                        Text(opt).tag(opt)
                                    }
                                }
                                .labelsHidden()
                            default:
                                TextField(field.placeholder ?? field.title, text: binding)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    Button {
                        Task { await refresh(force: true, withFormValues: formValues) }
                    } label: {
                        Label("Run \(command.title)", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(16)
            }
            .frame(width: output != nil ? 280 : nil)

            if let detail = output?.detail {
                Divider().opacity(0.18)
                splitDetailPane(detail)
            } else if !filteredItems.isEmpty {
                Divider().opacity(0.18)
                listModeView
            }
        }
    }

    // MARK: - Notch Mode Preview

    private var notchModePreview: some View {
        VStack(spacing: 14) {
            if let notch = output?.notch {
                HStack(spacing: 8) {
                    if let icon = notch.wingIcon {
                        Image(systemName: icon).foregroundStyle(accentColor)
                    }
                    Text(notch.wingText)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.black, in: Capsule())

                if let title = notch.title {
                    Text(title).font(.system(size: 15, weight: .semibold))
                }
                if let sub = notch.subtitle {
                    Text(sub).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button("Pin to Notch") {
                        DynamicNotchState.shared.publishPackActivity(
                            DoraxNotchLiveActivity(packID: pack.id, packName: pack.name, payload: notch))
                        showBanner("Pinned to Dynamic Island Notch")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Dismiss from Notch") {
                        DynamicNotchState.shared.dismissPackActivity()
                        showBanner("Dismissed from Notch")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                loadingPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Footer (Pack Icon + Primary Action ↵ + Searchable Actions ⌘K)

    private var bottomFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: pack.metadata.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentColor)
            Text("\(pack.name) · \(command.title)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let primary = primaryAction {
                Button {
                    invokeAction(primary, item: selectedItem)
                } label: {
                    HStack(spacing: 5) {
                        Text(primary.title)
                            .font(.system(size: 11, weight: .semibold))
                        Text("↵")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(primary.destructive ? .red : .primary)
            }

            Button {
                actionSearchText = ""
                selectedActionIndex = 0
                showActionsPopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text("Actions")
                        .font(.system(size: 11, weight: .medium))
                    Text("⌘K")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private var primaryAction: DoraxItemAction? {
        selectedItem?.actions.first
    }

    private var filteredActionEntries: [DoraxSheetActionEntry] {
        let q = actionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let itemActions = (selectedItem?.actions ?? [])
            .filter { q.isEmpty || $0.title.lowercased().contains(q) }
            .map { DoraxSheetActionEntry.item($0) }
        let packEntries: [DoraxSheetActionEntry] = [
            .upgradeWithAI,
            .configurePack,
            .viewLogs(runtime.logs(for: pack.id).count),
            .forceRefresh,
        ].filter { q.isEmpty || $0.title.lowercased().contains(q) }
        return itemActions + packEntries
    }

    private func handleDrawerEntry(_ entry: DoraxSheetActionEntry) {
        showActionsPopover = false
        switch entry {
        case .item(let action):
            invokeAction(action, item: selectedItem)
        case .upgradeWithAI:
            prompt.openExtensionStudio(
                target: .appPlugin,
                upgradePackID: pack.id,
                packStudioMode: .upgradeExisting)
        case .configurePack:
            activeOverlay = .configure
        case .viewLogs:
            activeOverlay = .logs
        case .forceRefresh:
            Task { await refresh(force: true) }
        }
    }

    // MARK: - Red Destructive Confirmation Overlay

    private func destructiveConfirmationOverlay(action: DoraxItemAction, item: DoraxCommandItem?) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                Text(action.title)
                    .font(.system(size: 15, weight: .bold))
                Text(action.confirmMessage ?? "Are you sure you want to run \"\(action.title)\" on \(item?.title ?? command.title)?")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("Cancel") {
                        pendingDestructiveAction = nil
                    }
                    .buttonStyle(.bordered)
                    Button(action.title) {
                        pendingDestructiveAction = nil
                        Task { await executeAction(action, item: item) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(20)
            .frame(width: 340)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.red.opacity(0.5), lineWidth: 1.5))
        }
    }

    // MARK: - `View Pack Logs` Overlay

    private var logsView: some View {
        let entries = runtime.logs(for: pack.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(entries.count) recent log entries")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Logs") { runtime.clearLogs(for: pack.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            if entries.isEmpty {
                emptyPlaceholder("No logs recorded for \(pack.name) yet.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(entry.level == .error ? Color.red : (entry.level == .warning ? Color.orange : Color.green))
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(entry.commandID)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        Text("\(entry.durationMs) ms")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(entry.timestamp, style: .time)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(entry.message)
                                        .font(.system(size: 11.5))
                                }
                            }
                            .padding(8)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    // MARK: - `Configure Command & Pack` Overlay (hotkey, alias, tint, enable/disable, Keychain prefs, hooks)

    private var configureView: some View {
        let cmdCfg = registry.commandConfig(packID: pack.id, commandID: command.id)
        let packCfg = registry.packConfig(for: pack.id)

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Command Settings") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Command", isOn: Binding(
                            get: { cmdCfg.isEnabled },
                            set: { v in registry.updateCommandConfig(packID: pack.id, commandID: command.id) { $0.isEnabled = v } }
                        ))
                        HStack {
                            Text("Alias").frame(width: 90, alignment: .leading).font(.system(size: 12))
                            TextField("e.g. ports", text: Binding(
                                get: { cmdCfg.alias },
                                set: { v in registry.updateCommandConfig(packID: pack.id, commandID: command.id) { $0.alias = v } }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Hotkey").frame(width: 90, alignment: .leading).font(.system(size: 12))
                            TextField("e.g. ⌥⇧P", text: Binding(
                                get: { cmdCfg.hotkey },
                                set: { v in registry.updateCommandConfig(packID: pack.id, commandID: command.id) { $0.hotkey = v } }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Tint (#HEX)").frame(width: 90, alignment: .leading).font(.system(size: 12))
                            TextField(pack.metadata.appearance?.tint ?? "#38BDF8", text: Binding(
                                get: { cmdCfg.tintHex },
                                set: { v in registry.updateCommandConfig(packID: pack.id, commandID: command.id) { $0.tintHex = v } }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(6)
                }

                if let prefs = pack.metadata.preferences, !prefs.isEmpty {
                    GroupBox("Pack Preferences (Secrets stored in Keychain)") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(prefs) { pref in
                                DoraxPreferenceEditorRow(pref: pref, packID: pack.id)
                            }
                        }
                        .padding(6)
                    }
                }

                if let hooks = pack.metadata.hooks, !hooks.isEmpty {
                    GroupBox("Reactive Hooks (\(hooks.count))") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Enable Pack Hooks", isOn: Binding(
                                get: { packCfg.hooksEnabled },
                                set: { v in
                                    var updated = packCfg
                                    updated.hooksEnabled = v
                                    registry.setPackConfig(updated, for: pack.id)
                                }
                            ))
                            ForEach(hooks) { hook in
                                let perm = hook.on.requiredPermission
                                Toggle("Allow \(hook.id) (\(perm))", isOn: Binding(
                                    get: { packCfg.grantedPermissions.contains(perm) },
                                    set: { granted in
                                        var updated = packCfg
                                        if granted { updated.grantedPermissions.insert(perm) }
                                        else { updated.grantedPermissions.remove(perm) }
                                        registry.setPackConfig(updated, for: pack.id)
                                    }
                                ))
                                .font(.system(size: 11.5))
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox("Global Dock Glow") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Dock & Sheet Glow", isOn: $aura.isEnabled)
                        HStack {
                            Text("Intensity (\(Int(aura.intensity * 100))%)")
                                .font(.system(size: 12))
                                .frame(width: 115, alignment: .leading)
                            Slider(value: $aura.intensity, in: 0.1...1.0)
                        }
                        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                            Text("macOS Reduce Motion is active — animated glow styles stay calm.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                DoraxPackManagementBox(
                    pack: pack,
                    command: command,
                    registry: registry,
                    prompt: prompt,
                    onReloaded: { msg in
                        showBanner(msg)
                        Task { await refresh(force: true) }
                    },
                    onDismissOverlay: { activeOverlay = nil },
                    onError: { showBanner($0) })
            }
            .padding(14)
        }
    }

    // MARK: - Helpers

    private var loadingPlaceholder: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Running \(command.title)…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyPlaceholder(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: command.icon)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func initializeFormDefaults() {
        for field in command.formFields ?? [] {
            if formValues[field.id] == nil, let def = field.defaultValue {
                formValues[field.id] = def
            }
        }
    }

    private func activateAura() {
        if let app = effectiveAppearance, app.glow.normalized != .none {
            DockAuraEngine.shared.activate(id: "sheet:\(bound.id)", appearance: app, priority: 65)
        }
    }

    private func installKeyBridge() {
        let bridge = ScopedListKeyBridge.shared
        bridge.move = { down in
            if showActionsPopover {
                let entries = filteredActionEntries
                guard !entries.isEmpty else { return false }
                let clamped = min(max(0, selectedActionIndex), entries.count - 1)
                selectedActionIndex = min(entries.count - 1, max(0, clamped + (down ? 1 : -1)))
                return true
            }
            guard activeOverlay == nil, pendingDestructiveAction == nil, !filteredItems.isEmpty else {
                return false
            }
            stepSelection(delta: down ? 1 : -1)
            return true
        }
        bridge.run = {
            if let pending = pendingDestructiveAction {
                pendingDestructiveAction = nil
                Task { await executeAction(pending.action, item: pending.item) }
                return true
            }
            if showActionsPopover {
                let entries = filteredActionEntries
                guard !entries.isEmpty else { return false }
                let clamped = min(max(0, selectedActionIndex), entries.count - 1)
                handleDrawerEntry(entries[clamped])
                return true
            }
            guard activeOverlay == nil else { return false }
            if command.mode == .form {
                Task { await refresh(force: true, withFormValues: formValues) }
                return true
            }
            guard let primary = primaryAction else { return false }
            invokeAction(primary, item: selectedItem)
            return true
        }
        bridge.openActions = {
            guard activeOverlay == nil, pendingDestructiveAction == nil else { return false }
            if showActionsPopover { return true }
            actionSearchText = ""
            selectedActionIndex = 0
            showActionsPopover = true
            return true
        }
        bridge.closeOverlay = {
            if pendingDestructiveAction != nil {
                pendingDestructiveAction = nil
                return true
            }
            if showActionsPopover {
                showActionsPopover = false
                return true
            }
            if activeOverlay != nil {
                activeOverlay = nil
                return true
            }
            return false
        }
    }

    private func refresh(force: Bool, withFormValues: [String: String]? = nil) async {
        let filterArg = selectedFilter == "All" ? "" : selectedFilter
        _ = await runtime.runCommand(
            command,
            in: pack,
            query: effectiveQuery,
            filter: filterArg,
            formValues: withFormValues,
            forceRefresh: force)
    }

    private func stepSelection(delta: Int) {
        let items = filteredItems
        guard !items.isEmpty else { return }
        if let currentID = selectedItemID,
           let idx = items.firstIndex(where: { $0.id == currentID })
        {
            let next = min(items.count - 1, max(0, idx + delta))
            selectedItemID = items[next].id
        } else {
            selectedItemID = items[0].id
        }
    }

    private func triggerPrimaryAction() {
        guard let primary = primaryAction else { return }
        invokeAction(primary, item: selectedItem)
    }

    private func invokeAction(_ action: DoraxItemAction, item: DoraxCommandItem?) {
        if action.destructive {
            pendingDestructiveAction = (action, item)
            return
        }
        Task { await executeAction(action, item: item) }
    }

    private func executeAction(_ action: DoraxItemAction, item: DoraxCommandItem?) async {
        let filterArg = selectedFilter == "All" ? "" : selectedFilter
        let res = await runtime.runItemActionDetailed(
            action, in: pack, command: command, item: item, filter: filterArg)
        switch res {
        case .success(let outcome):
            let kind = action.kind.lowercased()
            let cancelledPicker = outcome.message.isEmpty && (kind == "pick_folder" || kind == "pick_files")
            if outcome.didReplaceOutput {
                selectedItemID = nil
                if !outcome.message.isEmpty { showBanner(outcome.message) }
            } else if !cancelledPicker {
                showBanner(outcome.message.isEmpty ? "\(action.title) completed" : outcome.message)
                if ["script", "run", "cli", "pick_folder", "pick_files", "refresh"].contains(kind) {
                    await refresh(force: true)
                }
            }
        case .failure(let err):
            showBanner("Failed: \(err.message)", isError: true)
        }
    }

    private func showBanner(_ text: String, isError: Bool = false) {
        DynamicNotchState.shared.publishTransientToast(
            packID: pack.id,
            packName: pack.name,
            title: text,
            subtitle: command.title,
            icon: isError ? "exclamationmark.triangle.fill" : command.icon,
            tintHex: isError ? "#EF4444" : (effectiveAppearance?.tint ?? "#34D399"),
            durationSeconds: 3.0)
    }

    private func syncHeaderBar() {
        let overlayTitle: String? = {
            switch activeOverlay {
            case .logs: return "\(pack.name) — Logs"
            case .configure: return "Configure \(command.title)"
            case nil: return nil
            }
        }()
        let itemCount: Int? = (activeOverlay == nil && (output?.items.isEmpty == false))
            ? filteredItems.count
            : nil
        let ph: String = {
            switch command.mode {
            case .form: return "Type input or submit below…"
            case .ai, .detail, .cli, .instant: return "Filter or ask \(command.title)…"
            case .list, .grid, .notch: return "Filter \(command.title)…"
            }
        }()
        headerBar.update(
            id: bound.id,
            title: overlayTitle ?? command.title,
            icon: command.icon,
            tintHex: effectiveAppearance?.tint,
            count: itemCount,
            filterOptions: activeOverlay == nil ? filterOptions : [],
            selectedFilter: selectedFilter,
            isRefreshing: cacheEntry.isRefreshing,
            placeholder: ph,
            onBack: {
                if activeOverlay != nil {
                    activeOverlay = nil
                } else {
                    _ = prompt.leaveScopeForGlobal()
                }
            },
            onSelectFilter: filterOptions.isEmpty ? nil : { opt in
                selectedFilter = opt
            },
            onRefresh: {
                Task { await refresh(force: true) }
            })
    }
}

// MARK: - Block-Aware Markdown Detail Renderer

private struct DoraxMarkdownBlockView: View {
    let markdown: String

    private enum Block: Identifiable {
        case heading(id: Int, level: Int, text: String)
        case code(id: Int, text: String)
        case quote(id: Int, text: String)
        case bullet(id: Int, text: String)
        case paragraph(id: Int, text: String)

        var id: Int {
            switch self {
            case .heading(let id, _, _),
                 .code(let id, _),
                 .quote(let id, _),
                 .bullet(let id, _),
                 .paragraph(let id, _):
                return id
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var nextID = 0
        var inCode = false
        var codeLines: [String] = []
        var paraLines: [String] = []

        func flushPara() {
            let joined = paraLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paraLines.removeAll()
            guard !joined.isEmpty else { return }
            result.append(.paragraph(id: nextID, text: joined))
            nextID += 1
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    result.append(.code(id: nextID, text: codeLines.joined(separator: "\n")))
                    nextID += 1
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flushPara()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }
            if trimmed.isEmpty {
                flushPara()
                continue
            }
            if trimmed.hasPrefix("### ") {
                flushPara()
                result.append(.heading(id: nextID, level: 3, text: String(trimmed.dropFirst(4))))
                nextID += 1
            } else if trimmed.hasPrefix("## ") {
                flushPara()
                result.append(.heading(id: nextID, level: 2, text: String(trimmed.dropFirst(3))))
                nextID += 1
            } else if trimmed.hasPrefix("# ") {
                flushPara()
                result.append(.heading(id: nextID, level: 1, text: String(trimmed.dropFirst(2))))
                nextID += 1
            } else if trimmed.hasPrefix("> ") {
                flushPara()
                result.append(.quote(id: nextID, text: String(trimmed.dropFirst(2))))
                nextID += 1
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushPara()
                result.append(.bullet(id: nextID, text: String(trimmed.dropFirst(2))))
                nextID += 1
            } else {
                paraLines.append(rawLine)
            }
        }
        if inCode && !codeLines.isEmpty {
            result.append(.code(id: nextID, text: codeLines.joined(separator: "\n")))
        }
        flushPara()
        return result
    }

    private func inlineMarkdownText(_ raw: String, font: Font) -> Text {
        if let attr = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr).font(font)
        }
        return Text(raw).font(font)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    inlineMarkdownText(
                        text,
                        font: .system(size: level == 1 ? 15 : (level == 2 ? 13.5 : 12.5), weight: .bold)
                    )
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .code(_, let text):
                    Text(text.isEmpty ? " " : text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                case .quote(_, let text):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: 3)
                        inlineMarkdownText(text, font: .system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                case .bullet(_, let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                        inlineMarkdownText(text, font: .system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .paragraph(_, let text):
                    inlineMarkdownText(text, font: .system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
