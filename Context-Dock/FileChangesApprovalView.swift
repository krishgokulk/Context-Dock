import SwiftUI

// MARK: - File Changes Approval View
// Shows proposed file changes with diff preview, similar to VS Code

struct FileChangesApprovalView: View {
    @ObservedObject var fileManager: L2AIFileManager
    let onApprove: () -> Void
    let onDeny: () -> Void
    
    @State private var selectedChangeID: UUID?
    @State private var showingDiff = true
    
    var body: some View {
        HSplitView {
            // Left: List of changes
            changesList
                .frame(minWidth: 250, idealWidth: 300)
            
            // Right: Diff preview
            if let selectedChange = selectedChange {
                diffPreview(for: selectedChange)
                    .frame(minWidth: 400)
            } else {
                emptyPreview
            }
        }
        .frame(width: 900, height: 600)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 4) {
                    Text("Review AI Proposed Changes")
                        .font(.headline)
                    if let operation = fileManager.currentOperation {
                        Text(operation.userQuery)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .onAppear {
            // Select first change by default
            selectedChangeID = fileManager.pendingChanges.first?.id
        }
    }
    
    // MARK: - Changes List
    
    private var changesList: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Proposed Changes", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Text("\(approvedCount)/\(fileManager.pendingChanges.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Changes
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($fileManager.pendingChanges) { $change in
                        ChangeRow(
                            change: $change,
                            isSelected: selectedChangeID == change.id,
                            onSelect: { selectedChangeID = change.id }
                        )
                        Divider()
                    }
                }
            }
        }
    }
    
    // MARK: - Diff Preview
    
    private func diffPreview(for change: L2AIFileManager.FileChange) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        changeIcon(for: change.changeType)
                        Text(change.fileURL.lastPathComponent)
                            .font(.headline)
                    }
                    
                    Text(change.fileURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                if let diff = change.diff {
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.green)
                            Text("\(diff.addedLines)")
                        }
                        .font(.caption)
                        
                        HStack(spacing: 4) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                            Text("\(diff.deletedLines)")
                        }
                        .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Reasoning
            VStack(alignment: .leading, spacing: 8) {
                Label("AI Reasoning", systemImage: "brain")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                
                Text(change.reasoning)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.1))
            
            Divider()
            
            // Content preview
            if showingDiff, let diff = change.diff {
                diffView(diff: diff)
            } else if change.changeType == .create, let content = change.newContent {
                newFileView(content: content)
            } else if change.changeType == .modify, let content = change.newContent {
                fullContentView(content: content, title: "New Content")
            }
        }
    }
    
    private func diffView(diff: L2AIFileManager.FileDiff) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                    // Hunk header
                    Text("@@ -\(hunk.originalRange.start),\(hunk.originalRange.count) +\(hunk.newRange.start),\(hunk.newRange.count) @@")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                    
                    // Lines
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
            }
        }
        .font(.system(.body, design: .monospaced))
    }
    
    private func newFileView(content: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(content.components(separatedBy: .newlines).enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.1))
                }
            }
        }
    }
    
    private func fullContentView(content: String, title: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(content.components(separatedBy: .newlines).enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 2)
                }
            }
        }
    }
    
    private var emptyPreview: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            
            Text("Select a change to preview")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
    
    // MARK: - Action Bar
    
    private var actionBar: some View {
        HStack(spacing: 16) {
            // Bulk actions
            Button(action: approveAll) {
                Label("Approve All", systemImage: "checkmark.circle")
            }
            .buttonStyle(.bordered)
            
            Button(action: denyAll) {
                Label("Deny All", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            // Main actions
            Button("Cancel") {
                onDeny()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape)
            
            Button(action: {
                Task {
                    do {
                        try await fileManager.approveChanges()
                        onApprove()
                    } catch {
                        // Handle error
                        print("Error: \(error)")
                    }
                }
            }) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Apply Changes (\(approvedCount))")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(approvedCount == 0)
            .keyboardShortcut(.return)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Helpers
    
    private var selectedChange: L2AIFileManager.FileChange? {
        fileManager.pendingChanges.first { $0.id == selectedChangeID }
    }
    
    private var approvedCount: Int {
        fileManager.pendingChanges.filter(\.approved).count
    }
    
    private func changeIcon(for type: L2AIFileManager.FileChange.ChangeType) -> some View {
        Group {
            switch type {
            case .create:
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
            case .modify:
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.blue)
            case .delete:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            case .rename:
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
    
    private func approveAll() {
        for index in fileManager.pendingChanges.indices {
            fileManager.pendingChanges[index].approved = true
        }
    }
    
    private func denyAll() {
        for index in fileManager.pendingChanges.indices {
            fileManager.pendingChanges[index].approved = false
        }
    }
}

// MARK: - Change Row

struct ChangeRow: View {
    @Binding var change: L2AIFileManager.FileChange
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Toggle("", isOn: $change.approved)
                .toggleStyle(.checkbox)
                .labelsHidden()
            
            // Icon
            changeIcon
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(change.fileURL.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Text(change.changeType.rawValue)
                        .font(.caption)
                        .foregroundStyle(changeColor)
                    
                    if let diff = change.diff {
                        Text(diff.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // Arrow
            if isSelected {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
    
    private var changeIcon: some View {
        Group {
            switch change.changeType {
            case .create:
                Image(systemName: "doc.badge.plus")
                    .foregroundStyle(.green)
            case .modify:
                Image(systemName: "doc.badge.ellipsis")
                    .foregroundStyle(.blue)
            case .delete:
                Image(systemName: "doc.badge.minus")
                    .foregroundStyle(.red)
            case .rename:
                Image(systemName: "doc.badge.arrow.up.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.title3)
    }
    
    private var changeColor: Color {
        switch change.changeType {
        case .create: return .green
        case .modify: return .blue
        case .delete: return .red
        case .rename: return .orange
        }
    }
}

// MARK: - Diff Line View

struct DiffLineView: View {
    let line: L2AIFileManager.FileDiff.DiffLine
    
    var body: some View {
        HStack(spacing: 8) {
            // Line type indicator
            Text(line.type.rawValue)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(lineColor)
                .frame(width: 20, alignment: .center)
            
            // Content
            Text(line.content)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
        .background(lineBackground)
    }
    
    private var lineColor: Color {
        switch line.type {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .secondary
        }
    }
    
    private var lineBackground: Color {
        switch line.type {
        case .addition: return Color.green.opacity(0.1)
        case .deletion: return Color.red.opacity(0.1)
        case .context: return Color.clear
        }
    }
}

// MARK: - Preview

#Preview {
    let fileManager = L2AIFileManager.shared
    
    // Mock some changes
    fileManager.pendingChanges = [
        L2AIFileManager.FileChange(
            fileURL: URL(fileURLWithPath: "/path/to/MyView.swift"),
            changeType: .modify,
            originalContent: "old content",
            newContent: "new content",
            diff: L2AIFileManager.FileDiff(hunks: [
                L2AIFileManager.FileDiff.DiffHunk(
                    originalRange: L2AIFileManager.FileDiff.DiffHunk.LineRange(start: 10, count: 3),
                    newRange: L2AIFileManager.FileDiff.DiffHunk.LineRange(start: 10, count: 4),
                    lines: [
                        L2AIFileManager.FileDiff.DiffLine(content: "func example() {", type: .context),
                        L2AIFileManager.FileDiff.DiffLine(content: "    print(\"old\")", type: .deletion),
                        L2AIFileManager.FileDiff.DiffLine(content: "    print(\"new\")", type: .addition),
                        L2AIFileManager.FileDiff.DiffLine(content: "    // New line", type: .addition),
                        L2AIFileManager.FileDiff.DiffLine(content: "}", type: .context)
                    ]
                )
            ]),
            reasoning: "Updated print statement to use new API"
        ),
        L2AIFileManager.FileChange(
            fileURL: URL(fileURLWithPath: "/path/to/NewFile.swift"),
            changeType: .create,
            newContent: "import SwiftUI\n\nstruct NewView: View {\n    var body: some View {\n        Text(\"Hello\")\n    }\n}",
            reasoning: "Created new SwiftUI view as requested"
        )
    ]
    
    return FileChangesApprovalView(
        fileManager: fileManager,
        onApprove: {},
        onDeny: {}
    )
}
