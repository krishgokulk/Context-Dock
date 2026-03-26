import SwiftUI

// MARK: - L2 Extensions Sheet

struct L2ExtensionsSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var extManager = L2ExtensionManager.shared
    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("L2 Extensions")
                        .font(.title2).fontWeight(.bold)
                    Text("Custom tools the AI can call directly")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { extManager.openExtensionsFolder() }) {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                Button(action: { showEditor = true }) {
                    Label("New Extension", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 16) {

                    // ── Example Gallery ───────────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Example Extensions", systemImage: "star.circle.fill")
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(.purple)
                            Spacer()
                            Text("tap to install")
                                .font(.caption2).foregroundStyle(.tertiary)
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

                    if extManager.extensions.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 36))
                                .foregroundStyle(.blue.opacity(0.4))
                            Text("No installed extensions yet")
                                .font(.subheadline).fontWeight(.semibold)
                            Text("Install an example above or create your own.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(action: { showEditor = true }) {
                                Label("New Extension", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(30)
                        .frame(maxWidth: .infinity)
                    } else {
                        // Tip card
                        HStack(spacing: 10) {
                            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                            Text("Ask naturally — \"save this page to Obsidian\", \"compress selected files\". The AI picks the right tool automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)

                        ForEach(extManager.extensions) { ext in
                            L2ExtensionCard(ext: ext)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .frame(width: 680, height: 560)
        .task { await extManager.loadExtensions() }
        .sheet(isPresented: $showEditor) {
            L2ExtensionEditorSheet(onSave: {
                Task { await extManager.loadExtensions() }
            })
        }
    }
}

// MARK: - Example Extensions Gallery

struct L2ExampleExtension: Identifiable {
    let id = UUID()
    let toolName: String
    let displayName: String
    let description: String
    let icon: String
    let contextApp: String?       // bundle ID or nil
    let contextAppLabel: String?  // friendly name for badge
    let accentColor: Color
    let triggers: [String]
    let json: String
    let script: String

    var isInstalled: Bool {
        let extDir = L2ExtensionManager.shared.extensionsDirectory
            .appendingPathComponent(toolName.replacingOccurrences(of: "_", with: "-"))
        return FileManager.default.fileExists(atPath: extDir.path)
    }

    func install() {
        let folderName = toolName.replacingOccurrences(of: "_", with: "-")
        let folder = L2ExtensionManager.shared.extensionsDirectory.appendingPathComponent(folderName)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? json.data(using: .utf8)?.write(to: folder.appendingPathComponent("extension.json"))
        let scriptURL = folder.appendingPathComponent("run.sh")
        try? script.data(using: .utf8)?.write(to: scriptURL)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: - Built-in examples
    static let all: [L2ExampleExtension] = safariExamples + finderExamples

    static let safariExamples: [L2ExampleExtension] = [
        L2ExampleExtension(
            toolName: "safari_save_to_notes",
            displayName: "Save Page to Notes",
            description: "Save the current Safari tab as a note with title, URL and date",
            icon: "note.text",
            contextApp: "com.apple.Safari",
            contextAppLabel: "Safari",
            accentColor: .blue,
            triggers: ["save", "note this", "save page", "save to notes"],
            json: """
{
  "tool_name": "safari_save_to_notes",
  "display_name": "Save Page to Notes",
  "description": "Save the current Safari tab (title + URL) to Apple Notes",
  "version": "1.0",
  "author": "ILauncher",
  "icon": "note.text",
  "parameters": {},
  "script": "run.sh",
  "script_type": "bash",
  "context_app": "com.apple.Safari",
  "triggers": ["save", "note this", "save page", "save to notes"]
}
""",
            script: """
#!/bin/bash
# Save current Safari tab to Apple Notes
RESULT=$(osascript <<'APPLESCRIPT'
tell application "Safari"
    set pageTitle to name of front document
    set pageURL to URL of front document
end tell
set noteBody to pageTitle & return & pageURL & return & (do shell script "date '+%Y-%m-%d %H:%M'")
tell application "Notes"
    make new note at folder "Notes" with properties {name:pageTitle, body:noteBody}
end tell
return "Saved: " & pageTitle
APPLESCRIPT)
echo "$RESULT"
"""
        ),
        L2ExampleExtension(
            toolName: "safari_copy_markdown_link",
            displayName: "Copy as Markdown Link",
            description: "Copy current tab as [title](url) markdown to clipboard",
            icon: "link",
            contextApp: "com.apple.Safari",
            contextAppLabel: "Safari",
            accentColor: .blue,
            triggers: ["copy link", "markdown link", "copy as markdown", "copy url"],
            json: """
{
  "tool_name": "safari_copy_markdown_link",
  "display_name": "Copy as Markdown Link",
  "description": "Copy the current Safari tab as a Markdown link [title](url) to clipboard",
  "version": "1.0",
  "author": "ILauncher",
  "icon": "link",
  "parameters": {},
  "script": "run.sh",
  "script_type": "bash",
  "context_app": "com.apple.Safari",
  "triggers": ["copy link", "markdown link", "copy as markdown", "copy url"]
}
""",
            script: """
#!/bin/bash
RESULT=$(osascript -e 'tell application "Safari" to return {name of front document, URL of front document}')
TITLE=$(echo "$RESULT" | awk -F', ' '{print $1}')
URL=$(echo "$RESULT" | awk -F', ' '{print $2}')
echo "[$TITLE]($URL)" | pbcopy
echo "Copied: [$TITLE]($URL)"
"""
        ),
        L2ExampleExtension(
            toolName: "safari_open_in_chrome",
            displayName: "Open in Chrome",
            description: "Open the current Safari URL in Google Chrome",
            icon: "safari",
            contextApp: "com.apple.Safari",
            contextAppLabel: "Safari",
            accentColor: .blue,
            triggers: ["open in chrome", "switch to chrome", "chrome"],
            json: """
{
  "tool_name": "safari_open_in_chrome",
  "display_name": "Open in Chrome",
  "description": "Open the current Safari tab URL in Google Chrome",
  "version": "1.0",
  "author": "ILauncher",
  "icon": "safari",
  "parameters": {},
  "script": "run.sh",
  "script_type": "bash",
  "context_app": "com.apple.Safari",
  "triggers": ["open in chrome", "switch to chrome", "chrome"]
}
""",
            script: """
#!/bin/bash
URL=$(osascript -e 'tell application "Safari" to return URL of front document')
open -a "Google Chrome" "$URL"
echo "Opened in Chrome: $URL"
"""
        ),
        L2ExampleExtension(
            toolName: "safari_reader_mode",
            displayName: "Toggle Reader Mode",
            description: "Enter or exit Safari Reader Mode on the current tab",
            icon: "doc.plaintext",
            contextApp: "com.apple.Safari",
            contextAppLabel: "Safari",
            accentColor: .blue,
            triggers: ["reader mode", "reader view", "reading mode", "distraction free"],
            json: """
{
  "tool_name": "safari_reader_mode",
  "display_name": "Toggle Reader Mode",
  "description": "Enter or exit Safari Reader Mode on the current tab",
  "version": "1.0",
  "author": "ILauncher",
  "icon": "doc.plaintext",
  "parameters": {},
  "script": "run.sh",
  "script_type": "bash",
  "context_app": "com.apple.Safari",
  "triggers": ["reader mode", "reader view", "reading mode"]
}
""",
            script: """
#!/bin/bash
osascript -e 'tell application "Safari" to do JavaScript "document.querySelector(\\"button[aria-label*=\\\\'Reader\\\\']\\")||document.querySelector(\\"#reader-button\\")||document.querySelector(\\"button.reader-button\\")" in front document' 2>/dev/null || true
# Use keyboard shortcut as reliable fallback
osascript -e 'tell application "System Events" to keystroke "r" using {shift down, command down}'
echo "Toggled Reader Mode"
"""
        ),
        L2ExampleExtension(
            toolName: "safari_download_all_images",
            displayName: "Download Page Images",
            description: "Download all images from the current Safari tab to ~/Downloads/images/",
            icon: "photo.on.rectangle.angled",
            contextApp: "com.apple.Safari",
            contextAppLabel: "Safari",
            accentColor: .blue,
            triggers: ["download images", "save images", "grab images", "get images"],
            json: """
{
  "tool_name": "safari_download_all_images",
  "display_name": "Download Page Images",
  "description": "Download all images from the current Safari tab to ~/Downloads/images/",
  "version": "1.0",
  "author": "ILauncher",
  "icon": "photo.on.rectangle.angled",
  "parameters": {},
  "script": "run.sh",
  "script_type": "bash",
  "context_app": "com.apple.Safari",
  "triggers": ["download images", "save images", "grab images"]
}
""",
            script: """
#!/bin/bash
URL=$(osascript -e 'tell application "Safari" to return URL of front document')
DEST="$HOME/Downloads/images"
mkdir -p "$DEST"
# Extract image URLs from page source and download
curl -s "$URL" | grep -oE '(https?://[^"]+\\.(?:jpg|jpeg|png|gif|webp))' | sort -u | head -20 | while read -r img; do
    filename=$(basename "$img" | cut -d'?' -f1)
    curl -s -o "$DEST/$filename" "$img" && echo "Downloaded: $filename"
done
echo "Done — check ~/Downloads/images/"
"""
        ),
    ]

    static let finderExamples: [L2ExampleExtension] = [
        L2ExampleExtension(
            toolName: "finder_compress_selected",
            displayName: "Compress Selected",
            description: "Zip selected files in Finder into an archive on the Desktop",
            icon: "archivebox",
            contextApp: "com.apple.finder",
            contextAppLabel: "Finder",
            accentColor: .orange,
            triggers: ["compress", "zip", "archive", "compress selected"],
            json: """
{
  "tool_name": "finder_compress_selected",
  "display_name": "Compress Selected",
  "description": "Zip the files currently selected in Finder and save archive to Desktop",
  "version": "1.0",
  "author": "ILauncher",
  "icon": "archivebox",
  "parameters": {},
  "script": "run.sh",
  "script_type": "bash",
  "context_app": "com.apple.finder",
  "triggers": ["compress", "zip", "archive", "compress selected"]
}
""",
            script: """
#!/bin/bash
# Get selected Finder items via AppleScript
ITEMS=$(osascript <<'AS'
set output to ""
tell application "Finder"
    set sel to selection
    repeat with f in sel
        set output to output & (POSIX path of (f as alias)) & "\n"
    end repeat
end tell
return output
AS)
if [ -z "$ITEMS" ]; then echo "No files selected in Finder"; exit 1; fi
ARCHIVE="$HOME/Desktop/Archive_$(date +%Y%m%d_%H%M%S).zip"
echo "$ITEMS" | tr '\\n' '\\0' | xargs -0 zip -j "$ARCHIVE"
echo "Created: $(basename "$ARCHIVE")"
"""
        ),
        L2ExampleExtension(
            toolName: "finder_copy_paths",
            displayName: "Copy File Paths",
            description: "Copy full POSIX paths of selected Finder files to clipboard",
            icon: "doc.on.clipboard",
            contextApp: "com.apple.finder",
            contextAppLabel: "Finder",
            accentColor: .orange,
            triggers: ["copy path", "get path", "copy file path", "copy paths"],
            json: """
{
  "tool_name": "finder_copy_paths",
  "display_name": "Copy File Paths",
  "description": "Copy full POSIX paths of the files selected in Finder to clipboard",
  "version": "1.0",
  "author": "ILauncher",
  "icon": "doc.on.clipboard",
  "parameters": {},
  "script": "run.sh",
  "script_type": "bash",
  "context_app": "com.apple.finder",
  "triggers": ["copy path", "get path", "copy file path", "copy paths"]
}
""",
            script: """
#!/bin/bash
PATHS=$(osascript <<'AS'
set output to ""
tell application "Finder"
    set sel to selection
    repeat with f in sel
        set output to output & (POSIX path of (f as alias)) & "\n"
    end repeat
end tell
return output
AS)
if [ -z "$PATHS" ]; then echo "No files selected"; exit 1; fi
echo -n "$PATHS" | pbcopy
COUNT=$(echo "$PATHS" | grep -c .)
echo "Copied $COUNT path(s) to clipboard"
"""
        ),
        L2ExampleExtension(
            toolName: "finder_open_terminal_here",
            displayName: "Open Terminal Here",
            description: "Open a Terminal window at the current Finder folder",
            icon: "terminal",
            contextApp: "com.apple.finder",
            contextAppLabel: "Finder",
            accentColor: .orange,
            triggers: ["terminal here", "open terminal", "open in terminal"],
            json: """
{
  "tool_name": "finder_open_terminal_here",
  "display_name": "Open Terminal Here",
  "description": "Open Terminal at the current Finder window location",
  "version": "1.0",
  "author": "ILauncher",
  "icon": "terminal",
  "parameters": {},
  "script": "run.sh",
  "script_type": "bash",
  "context_app": "com.apple.finder",
  "triggers": ["terminal here", "open terminal", "open in terminal"]
}
""",
            script: """
#!/bin/bash
DIR=$(osascript -e 'tell application "Finder" to return POSIX path of (insertion location as alias)' 2>/dev/null \
   || osascript -e 'tell application "Finder" to return POSIX path of (target of front window as alias)')
osascript -e "tell application \"Terminal\" to do script \"cd '$DIR'\" activate" 2>/dev/null \
  || open -a Terminal "$DIR"
echo "Opened Terminal at: $DIR"
"""
        ),
        L2ExampleExtension(
            toolName: "finder_rename_with_date",
            displayName: "Rename with Date",
            description: "Prepend today's date (YYYY-MM-DD) to all selected Finder files",
            icon: "calendar.badge.plus",
            contextApp: "com.apple.finder",
            contextAppLabel: "Finder",
            accentColor: .orange,
            triggers: ["rename with date", "add date", "prepend date", "date prefix"],
            json: """
{
  "tool_name": "finder_rename_with_date",
  "display_name": "Rename with Date",
  "description": "Prepend today's date (YYYY-MM-DD_) to all files selected in Finder",
  "version": "1.0",
  "author": "ILauncher",
  "icon": "calendar.badge.plus",
  "parameters": {},
  "script": "run.sh",
  "script_type": "bash",
  "context_app": "com.apple.finder",
  "triggers": ["rename with date", "add date", "prepend date"]
}
""",
            script: """
#!/bin/bash
DATE=$(date +%Y-%m-%d)
ITEMS=$(osascript <<'AS'
set output to ""
tell application "Finder"
    set sel to selection
    repeat with f in sel
        set output to output & (POSIX path of (f as alias)) & "\n"
    end repeat
end tell
return output
AS)
if [ -z "$ITEMS" ]; then echo "No files selected in Finder"; exit 1; fi
COUNT=0
while IFS= read -r path; do
    [ -z "$path" ] && continue
    dir=$(dirname "$path"); base=$(basename "$path")
    mv "$path" "$dir/${DATE}_${base}" && COUNT=$((COUNT+1))
done <<< "$ITEMS"
echo "Renamed $COUNT file(s) with prefix $DATE"
"""
        ),
        L2ExampleExtension(
            toolName: "finder_show_file_info",
            displayName: "Show File Info",
            description: "Show size, creation date, and kind for selected files",
            icon: "info.circle",
            contextApp: "com.apple.finder",
            contextAppLabel: "Finder",
            accentColor: .orange,
            triggers: ["file info", "file details", "info", "show info"],
            json: """
{
  "tool_name": "finder_show_file_info",
  "display_name": "Show File Info",
  "description": "Show size, creation date, permissions, and kind for selected Finder files",
  "version": "1.0",
  "author": "ILauncher",
  "icon": "info.circle",
  "parameters": {},
  "script": "run.sh",
  "script_type": "bash",
  "context_app": "com.apple.finder",
  "triggers": ["file info", "file details", "info", "show info"]
}
""",
            script: """
#!/bin/bash
ITEMS=$(osascript <<'AS'
set output to ""
tell application "Finder"
    set sel to selection
    repeat with f in sel
        set output to output & (POSIX path of (f as alias)) & "\n"
    end repeat
end tell
return output
AS)
if [ -z "$ITEMS" ]; then echo "No files selected"; exit 1; fi
while IFS= read -r path; do
    [ -z "$path" ] && continue
    echo "── $(basename "$path")"
    ls -lah "$path" | awk '{print "  Size: "$5"  Permissions: "$1"  Modified: "$6,$7,$8}'
    mdls -name kMDItemContentType -name kMDItemCreationDate "$path" 2>/dev/null | sed 's/^/  /'
done <<< "$ITEMS"
"""
        ),
    ]
}

struct L2ExampleCard: View {
    let example: L2ExampleExtension
    var onInstall: () -> Void
    @State private var installed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(example.accentColor.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: example.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(example.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(example.displayName)
                        .font(.caption).fontWeight(.semibold)
                        .lineLimit(1)
                    if let label = example.contextAppLabel {
                        HStack(spacing: 3) {
                            Image(systemName: "app.connected.to.app.below.fill")
                                .font(.system(size: 7))
                            Text(label)
                                .font(.caption2)
                        }
                        .foregroundStyle(example.accentColor)
                    }
                }
            }

            Text(example.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Button(action: {
                example.install()
                installed = true
                onInstall()
            }) {
                Label(installed || example.isInstalled ? "Installed" : "Install",
                      systemImage: installed || example.isInstalled ? "checkmark.circle.fill" : "plus.circle")
                    .font(.caption2).fontWeight(.medium)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(installed || example.isInstalled ? .green : example.accentColor)
            .disabled(installed || example.isInstalled)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 180, height: 140)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - L2 Extension Editor Sheet

struct L2ExtensionEditorSheet: View {
    @Environment(\.dismiss) var dismiss
    var initialJSON: String?
    var initialScript: String?
    var onSave: (() -> Void)?

    // Two-pane: left = JSON editor, right = script editor
    @State private var jsonText: String = defaultJSON
    @State private var scriptText: String = defaultScript
    @State private var saveError: String?
    @State private var saveSuccess = false
    @State private var selectedPane: Int = 0   // 0 = JSON, 1 = Script
    @State private var parsedName: String = ""

    // Context app picker (multi-select)
    @State private var contextAppBundleIds: [String] = []   // empty = always available
    @State private var runningApps: [(name: String, bundleId: String, icon: NSImage?)] = []

    static let defaultJSON = """
    {
      "tool_name": "my_tool",
      "display_name": "My Tool",
      "description": "Describe what this tool does so the AI knows when to call it",
      "version": "1.0",
      "author": "me",
      "icon": "hammer",
      "parameters": {
        "input": {
          "type": "string",
          "description": "The input to process",
          "required": true
        }
      },
      "script": "run.sh",
      "script_type": "bash",
      "triggers": ["keyword1", "keyword2"]
    }
    """

    static let defaultScript = """
    #!/bin/bash
    # My Tool — L2 Extension
    # Parameters arrive as environment variables (uppercased key names)
    # e.g. "input" → $INPUT

    echo "Running with input: $INPUT"
    """

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New L2 Extension")
                        .font(.title3).fontWeight(.bold)
                    Text("Paste from AI or write your own — saved automatically")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Paste from clipboard shortcut
                Button(action: pasteFromClipboard) {
                    Label("Paste from AI", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help("Paste extension.json + script that Claude or another AI generated")

                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save Extension") { saveExtension() }
                    .buttonStyle(.borderedProminent)
                    .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()

            Divider()

            // Error / success banner
            if let error = saveError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.caption)
                    Spacer()
                    Button("Dismiss") { saveError = nil }.font(.caption)
                }
                .padding(.horizontal).padding(.vertical, 8)
                .background(.red.opacity(0.08))
            }
            if saveSuccess {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Extension saved! The AI can now use it.").font(.caption)
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 8)
                .background(.green.opacity(0.08))
            }

            // Context App Picker (multi-select)
            HStack(spacing: 10) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Only activate when:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Menu {
                    Button {
                        contextAppBundleIds = []
                        injectContextApps([])
                    } label: {
                        HStack {
                            if contextAppBundleIds.isEmpty {
                                Image(systemName: "checkmark")
                            }
                            Label("Any app (always available)", systemImage: "infinity")
                        }
                    }

                    if !runningApps.isEmpty {
                        Divider()
                        Text("Running Apps — tap to toggle").font(.caption2)
                        ForEach(runningApps, id: \.bundleId) { app in
                            Button {
                                toggleContextApp(bundleId: app.bundleId)
                            } label: {
                                HStack {
                                    if contextAppBundleIds.contains(app.bundleId) {
                                        Image(systemName: "checkmark")
                                    }
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                    }
                                    Text(app.name)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if contextAppBundleIds.isEmpty {
                            Image(systemName: "infinity").font(.caption2)
                            Text("Any app").font(.caption)
                        } else if contextAppBundleIds.count == 1,
                                  let app = runningApps.first(where: { $0.bundleId == contextAppBundleIds[0] }) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().scaledToFit().frame(width: 14, height: 14)
                            }
                            Text(app.name).font(.caption)
                        } else {
                            Image(systemName: "apps.iphone").font(.caption2)
                            Text("\(contextAppBundleIds.count) apps").font(.caption)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                if !contextAppBundleIds.isEmpty {
                    let names = contextAppBundleIds.compactMap { id in
                        runningApps.first(where: { $0.bundleId == id })?.name ?? id
                    }.joined(separator: ", ")
                    Text("Only shows when: \(names)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.secondary.opacity(0.03))

            Divider()

            // Two-pane editor
            HStack(spacing: 0) {
                // LEFT: JSON editor
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("extension.json", systemImage: "doc.text")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Spacer()
                        // Live name preview
                        if !parsedName.isEmpty {
                            Text(parsedName)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.blue.opacity(0.12), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.secondary.opacity(0.05))

                    Divider()

                    TextEditor(text: $jsonText)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .onChange(of: jsonText) {
                            updateParsedName()
                            syncContextAppFromJSON()
                        }
                }
                .frame(maxWidth: .infinity)
                .background(.background)

                Divider()

                // RIGHT: Script editor
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label(scriptFilename, systemImage: "terminal")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Spacer()
                        // Script type indicator
                        Text(scriptTypeLabel)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.12), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.secondary.opacity(0.05))

                    Divider()

                    TextEditor(text: $scriptText)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                }
                .frame(maxWidth: .infinity)
                .background(.background)
            }

            Divider()

            // Bottom hints
            HStack(spacing: 20) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").foregroundStyle(.purple).font(.caption)
                    Text("Ask Claude: \"Write an L2 extension JSON for [task] with a bash script\"")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Parameters become env vars: minutes → $MINUTES")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.secondary.opacity(0.04))
        }
        .frame(width: 820, height: 580)
        .onAppear {
            if let j = initialJSON  { jsonText  = j }
            if let s = initialScript { scriptText = s }
            updateParsedName()
            loadRunningApps()
            syncContextAppFromJSON()
        }
    }

    // MARK: - Computed helpers

    private var scriptFilename: String {
        if let data = jsonText.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["script"] as? String { return s }
        return "script.sh"
    }

    private var scriptTypeLabel: String {
        if let data = jsonText.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["script_type"] as? String { return s }
        return "bash"
    }

    private func updateParsedName() {
        if let data = jsonText.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = obj["tool_name"] as? String {
            parsedName = name
        } else {
            parsedName = ""
        }
    }

    // MARK: - Paste from clipboard

    /// Detect whether clipboard contains JSON (extension.json), a script, or both separated by "---"
    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }

        // Check if clipboard has both JSON and script separated by "---" or "```"
        // Try to detect JSON block
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{") {
            // It's JSON — paste into JSON pane
            jsonText = trimmed
            updateParsedName()
            saveError = nil
        } else if trimmed.hasPrefix("#!/") || trimmed.hasPrefix("#!") {
            // It's a script — paste into script pane
            scriptText = trimmed
        } else {
            // Try to split by markdown code fences
            let parts = trimmed.components(separatedBy: "```")
            var foundJSON = false
            var foundScript = false
            for part in parts {
                let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = p.hasPrefix("json") ? String(p.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                         : p.hasPrefix("bash") ? String(p.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                         : p
                if body.hasPrefix("{") && !foundJSON {
                    jsonText = body; foundJSON = true; updateParsedName()
                } else if (body.hasPrefix("#!/") || body.hasPrefix("#")) && body.contains("\n") && !foundScript {
                    scriptText = body; foundScript = true
                }
            }
            if !foundJSON && !foundScript {
                // Just paste as JSON and let user sort it out
                jsonText = trimmed
                updateParsedName()
            }
        }
        saveError = nil
        saveSuccess = false
    }

    // MARK: - Context App Helpers

    private func loadRunningApps() {
        let ws = NSWorkspace.shared
        runningApps = ws.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&
                app.bundleIdentifier != Bundle.main.bundleIdentifier &&
                app.localizedName != nil
            }
            .compactMap { app in
                guard let name = app.localizedName,
                      let bundleId = app.bundleIdentifier else { return nil }
                let icon = app.icon.map { img -> NSImage in
                    let copy = img.copy() as! NSImage
                    copy.size = NSSize(width: 16, height: 16)
                    return copy
                }
                return (name: name, bundleId: bundleId, icon: icon)
            }
            .sorted { $0.name < $1.name }
    }

    /// Toggle a single app in/out of the multi-app selection
    private func toggleContextApp(bundleId: String) {
        if let idx = contextAppBundleIds.firstIndex(of: bundleId) {
            contextAppBundleIds.remove(at: idx)
        } else {
            contextAppBundleIds.append(bundleId)
        }
        injectContextApps(contextAppBundleIds)
    }

    /// Inject `context_apps` (array) into the JSON, keeping backward-compat single `context_app`
    private func injectContextApps(_ bundleIds: [String]) {
        guard var obj = parsedJSONObject() else { return }
        if bundleIds.isEmpty {
            obj.removeValue(forKey: "context_app")
            obj.removeValue(forKey: "context_apps")
        } else if bundleIds.count == 1 {
            obj["context_app"]  = bundleIds[0]   // compat
            obj["context_apps"] = bundleIds       // new
        } else {
            obj["context_apps"] = bundleIds
            obj["context_app"]  = bundleIds[0]   // compat: first app
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            jsonText = str
        }
    }

    /// Read `context_apps` (or old `context_app`) from current JSON and sync picker state
    private func syncContextAppFromJSON() {
        guard let obj = parsedJSONObject() else { contextAppBundleIds = []; return }
        if let arr = obj["context_apps"] as? [String], !arr.isEmpty {
            contextAppBundleIds = arr
        } else if let single = obj["context_app"] as? String, !single.isEmpty {
            contextAppBundleIds = [single]
        } else {
            contextAppBundleIds = []
        }
    }

    private func parsedJSONObject() -> [String: Any]? {
        guard let data = jsonText.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Save

    private func saveExtension() {
        saveError = nil
        saveSuccess = false

        // Validate JSON
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            saveError = "Invalid JSON — check for missing commas or unclosed braces"
            return
        }

        guard let toolName = obj["tool_name"] as? String, !toolName.isEmpty else {
            saveError = "Missing \"tool_name\" field in JSON"
            return
        }

        guard let scriptFile = obj["script"] as? String, !scriptFile.isEmpty else {
            saveError = "Missing \"script\" field in JSON (e.g. \"run.sh\")"
            return
        }

        // Sanitise folder name
        let folderName = toolName.replacingOccurrences(of: "_", with: "-")
        let extManager = L2ExtensionManager.shared
        let folder = extManager.extensionsDirectory.appendingPathComponent(folderName)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            // Write extension.json (pretty-printed)
            let prettyData = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try prettyData.write(to: folder.appendingPathComponent("extension.json"))

            // Write script file
            let scriptURL = folder.appendingPathComponent(scriptFile)
            try scriptText.data(using: .utf8)?.write(to: scriptURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            saveSuccess = true
            onSave?()

            // Auto-dismiss after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }

        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - L2 Extension Card

struct L2ExtensionCard: View {
    let ext: L2Extension
    @StateObject private var extManager = L2ExtensionManager.shared
    @State private var showParams = false
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.blue.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: ext.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(ext.displayName)
                            .font(.subheadline).fontWeight(.semibold)
                        Text(ext.toolName)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                        if let contextApp = ext.contextApp, !contextApp.isEmpty {
                            let appName = NSWorkspace.shared.runningApplications
                                .first(where: { $0.bundleIdentifier == contextApp })?.localizedName
                                ?? contextApp.components(separatedBy: ".").last ?? contextApp
                            HStack(spacing: 3) {
                                Image(systemName: "app.connected.to.app.below.fill")
                                    .font(.system(size: 8))
                                Text(appName)
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                            .foregroundStyle(.orange)
                        }
                    }
                    Text(ext.description)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { ext.isEnabled },
                        set: { _ in extManager.toggleEnabled(ext) }
                    ))
                    .labelsHidden().scaleEffect(0.8)

                    if ext.usageCount > 0 {
                        Text("\(ext.usageCount) uses")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(12)

            if !ext.parameters.isEmpty {
                Divider().padding(.horizontal, 12)
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showParams.toggle() } }) {
                    HStack {
                        Text("\(ext.parameters.count) parameter\(ext.parameters.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        Image(systemName: showParams ? "chevron.up" : "chevron.down")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text(ext.scriptType.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.12), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                if showParams {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(ext.parameters.keys.sorted()), id: \.self) { key in
                            if let param = ext.parameters[key] {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("$\(key.uppercased())")
                                        .font(.system(.caption, design: .monospaced))
                                        .fontWeight(.medium)
                                    Text("(\(param.type)\(param.required ? ", required" : ""))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("— \(param.description)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
        .padding(.horizontal)
        .opacity(ext.isEnabled ? 1.0 : 0.5)
        .sheet(isPresented: $showEditor) {
            L2ExtensionEditorSheet(
                initialJSON: loadJSON(for: ext),
                initialScript: loadScript(for: ext),
                onSave: { Task { await extManager.loadExtensions() } }
            )
        }
        .contextMenu {
            Button("Edit Extension") { showEditor = true }
            Button("Open in Finder") {
                if let folder = ext.folderPath {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                }
            }
            Divider()
            Button("Remove Extension", role: .destructive) { extManager.removeExtension(ext) }
        }
    }

    private func loadJSON(for ext: L2Extension) -> String {
        guard let folder = ext.folderPath,
              let data = try? Data(contentsOf: folder.appendingPathComponent("extension.json")),
              let str = String(data: data, encoding: .utf8) else { return L2ExtensionEditorSheet.defaultJSON }
        return str
    }

    private func loadScript(for ext: L2Extension) -> String {
        guard let scriptURL = ext.scriptURL,
              let str = try? String(contentsOf: scriptURL) else { return L2ExtensionEditorSheet.defaultScript }
        return str
    }
}
