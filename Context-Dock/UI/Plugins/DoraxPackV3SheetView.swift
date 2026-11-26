// Context-Dock/UI/Plugins/DoraxPackV3SheetView.swift
// Context-Dock
//
// Unified 680 × 440 Result Sheet renderer for `.doraxpack` v3 commands (Steps 3 & 4).
// Supports all v3 modes: `list`, `grid`, `detail`, `form`, `instant`, `notch`, `cli`, `ai`.
//
// Chrome matches DoraX's 680 × 440 Result Sheet:
// - Top bar: `<` Back button + live filter input + top-right filter/sort dropdown (`▾`) + refresh spinner
// - Body:
//   * `list`: scrollable items with icon/app icon/swatch + right accessories (`text`, colored `tag`,
//     `date`, `progress`, `color`, `avatar`, CPU/RAM `metric`) + optional split Markdown/Metadata detail
//   * `grid`: responsive card & color-swatch grid
//   * `detail` / `cli` / `instant` / `ai`: Markdown + right Metadata sidebar
//   * `form`: typed inputs + Submit
// - Bottom footer: Pack icon + command title on left; Primary Action `↵` & searchable `Actions ⌘K`
//   on right (with per-action shortcuts, red destructive confirmation, `View Pack Logs`, and
//   `Configure Command` for hotkey, alias, tint, enable/disable, Keychain preferences, and hooks).

import AppKit
import SwiftUI

struct DoraxPackV3SheetView: View {
    let bound: DoraxBoundCommand
    @ObservedObject var prompt: AppChatPromptModel

    @ObservedObject private var runtime = DoraxPackV3Runtime.shared
    @ObservedObject private var registry = DoraxPackV3Registry.shared
    @ObservedObject private var aura = DockAuraEngine.shared
    @Environment(\.sharesOneCard) private var sharesOneCard

    @State private var localQuery: String = ""
    @State private var selectedFilter: String = "All"
    @State private var selectedItemID: String? = nil
    @State private var showActionsPopover: Bool = false
    @State private var actionSearchText: String = ""
    @State private var pendingDestructiveAction: (action: DoraxItemAction, item: DoraxCommandItem?)? = nil
    @State private var activeOverlay: SheetOverlay? = nil
    @State private var formValues: [String: String] = [:]
    @State private var statusBanner: String? = nil

    private enum SheetOverlay: Equatable {
        case logs
        case configure
    }

    private var pack: DoraxPackV2 { bound.pack }
    private var command: DoraxPackCommand { bound.command }

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
        let q = localQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            topBar
            Divider().opacity(0.18)

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
            if command.mode != .form {
                Task { await refresh(force: false) }
            }
        }
        .onDisappear {
            DockAuraEngine.shared.deactivate(id: "sheet:\(bound.id)")
        }
        .onChange(of: selectedFilter) { _, _ in
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
                TextField("Filter \(command.title)…", text: $localQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
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
            if let banner = statusBanner {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(banner).font(.system(size: 11)).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.12))
            }

            switch command.mode {
            case .list:
                listModeView
            case .grid:
                gridModeView
            case .detail, .cli, .instant, .ai:
                detailModeView
            case .form:
                formModeView
            case .notch:
                notchModePreview
            }
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
            emptyPlaceholder(output?.emptyMessage ?? "No items match \"\(localQuery)\".")
        } else {
            let hasDetail = selectedItem?.detail != nil
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredItems) { item in
                            itemRow(item, isSelected: item.id == selectedItem?.id)
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
                VStack(alignment: .leading, spacing: 8) {
                    if let attributed = try? AttributedString(
                        markdown: detail.markdown,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attributed)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(detail.markdown)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(filteredItems) { item in
                        let isSelected = item.id == selectedItem?.id
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                itemLeadingIcon(item)
                                Spacer()
                                if let firstAcc = item.accessories.first {
                                    accessoryView(firstAcc)
                                }
                            }
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            if let sub = item.subtitle, !sub.isEmpty {
                                Text(sub)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
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
            .popover(isPresented: $showActionsPopover, arrowEdge: .top) {
                actionsPopoverContent
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private var primaryAction: DoraxItemAction? {
        selectedItem?.actions.first
    }

    // MARK: - Searchable `Actions ⌘K` Popover

    private var actionsPopoverContent: some View {
        let itemActions = selectedItem?.actions ?? []
        let q = actionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchingItemActions = itemActions.filter {
            q.isEmpty || $0.title.lowercased().contains(q)
        }
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Search actions…", text: $actionSearchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matchingItemActions) { act in
                        Button {
                            showActionsPopover = false
                            invokeAction(act, item: selectedItem)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: act.icon)
                                    .frame(width: 14)
                                    .foregroundStyle(act.destructive ? .red : accentColor)
                                Text(act.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(act.destructive ? .red : .primary)
                                Spacer()
                                if let sc = act.shortcut, !sc.isEmpty {
                                    Text(sc)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().padding(.vertical, 4)

                    Button {
                        showActionsPopover = false
                        activeOverlay = .configure
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.3").frame(width: 14)
                            Text("Configure Command & Pack").font(.system(size: 12))
                            Spacer()
                            Text("⌘,").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showActionsPopover = false
                        activeOverlay = .logs
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass").frame(width: 14)
                            Text("View Pack Logs (\(runtime.logs(for: pack.id).count))").font(.system(size: 12))
                            Spacer()
                            Text("⌘L").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showActionsPopover = false
                        Task { await refresh(force: true) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise").frame(width: 14)
                            Text("Force Refresh").font(.system(size: 12))
                            Spacer()
                            Text("⌘R").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(width: 260, height: 240)
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
                                HStack {
                                    Text(pref.title).frame(width: 130, alignment: .leading).font(.system(size: 12))
                                    let binding = Binding<String>(
                                        get: { DoraxPackPreferenceStore.value(for: pref, packID: pack.id) ?? "" },
                                        set: { DoraxPackPreferenceStore.setValue($0, for: pref, packID: pack.id) }
                                    )
                                    if pref.type == .secret {
                                        SecureField(pref.placeholder ?? "Stored in Keychain", text: binding)
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        TextField(pref.placeholder ?? pref.title, text: binding)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
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

                GroupBox("Pack Folder & Hot-Reload") {
                    HStack(spacing: 8) {
                        Button("Reveal Pack Folder in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([pack.folderURL])
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Hot-Reload Pack") {
                            registry.reload()
                            activeOverlay = nil
                            showBanner("Reloaded \(pack.name)")
                            Task { await refresh(force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(6)
                }
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

    private func refresh(force: Bool, withFormValues: [String: String]? = nil) async {
        let filterArg = selectedFilter == "All" ? "" : selectedFilter
        _ = await runtime.runCommand(
            command,
            in: pack,
            query: localQuery,
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
        let res = await runtime.runItemAction(action, in: pack, item: item)
        switch res {
        case .success(let msg):
            showBanner(msg.isEmpty ? "\(action.title) completed" : msg)
            if action.kind == "script" || action.kind == "cli" {
                await refresh(force: true)
            }
        case .failure(let err):
            showBanner("Failed: \(err.message)")
        }
    }

    private func showBanner(_ text: String) {
        statusBanner = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if statusBanner == text { statusBanner = nil }
        }
    }
}
