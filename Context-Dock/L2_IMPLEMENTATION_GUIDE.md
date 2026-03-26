# L2 AI Task Executor - Complete Implementation Guide

## Overview
Your L2 layer now has intelligent task execution with:
- **Smart query analysis** → Creates detailed todo lists
- **Tool detection** → Knows what's installed on the Mac
- **Auto-installation** → Suggests & installs tools via Homebrew
- **Task execution** → Runs commands with approval flow
- **Extension learning** → Generates reusable extensions from completed tasks

## Architecture

```
User Query ("compress this PDF")
    ↓
L2AITaskExecutor.executeTask()
    ↓
1. Analyze Query with AI
   - Breaks down into steps
   - Identifies required tools
   - Creates terminal commands
    ↓
2. Check Tools
   - Detects installed tools
   - Suggests missing tools
   - Offers Homebrew installation
    ↓
3. Execute Steps
   - Runs each command
   - Captures output
   - Handles errors
    ↓
4. Learn & Suggest
   - Generates extension script
   - Saves for reuse
   - Context-aware (file types)
```

## Key Features

### 1. Intelligent Query Analysis
```swift
// User types: "compress this image to 50% quality"
// AI creates:
{
  "steps": [
    {
      "description": "Check if ImageMagick is installed",
      "requiredTool": "imagemagick",
      "command": null
    },
    {
      "description": "Compress image using ImageMagick",
      "requiredTool": "imagemagick",  
      "command": "convert INPUT -quality 50 OUTPUT"
    }
  ]
}
```

### 2. Tool Detection & Installation
```swift
// Automatic tool detection
TerminalTool.detect("imagemagick")
// Returns: TerminalTool with path, version, capabilities

// Smart installation via Homebrew
installTool("imagemagick")
// → Shows approval dialog
// → Installs via "brew install imagemagick"
// → Caches for future use
```

### 3. Context-Aware Execution
```swift
// File context from selected files
FileContext(
  selectedFiles: [URL],
  fileTypes: ["pdf", "jpg"],
  totalSize: 1024000
)

// AI uses context to:
// - Recommend appropriate tools
// - Generate file-specific commands
// - Create targeted extensions
```

### 4. Extension Generation
After successful task completion:
```bash
#!/bin/bash
# Extension: Compress Image to 50%
# Trigger: jpg, png, gif
# Description: Compresses images to 50% quality using ImageMagick

INPUT="$1"
OUTPUT="${INPUT%.*}_compressed.${INPUT##*.}"

convert "$INPUT" -quality 50 "$OUTPUT"
echo "Compressed: $OUTPUT"
```

## Integration with ContentView

### In ContentView.swift, update L2 query handler:

```swift
private func handleL2Query(_ query: String) {
    // ... existing code ...
    
    // NEW: Use L2AITaskExecutor
    l2CurrentTask = Task {
        do {
            // Get file context
            let context: L2AITaskExecutor.FileContext? = {
                if case .filesSelected(let urls) = currentContext {
                    let fileTypes = Set(urls.map { $0.pathExtension })
                    let totalSize = urls.reduce(0) { total, url in
                        total + (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0)
                    }
                    return L2AITaskExecutor.FileContext(
                        selectedFiles: urls,
                        fileTypes: fileTypes,
                        totalSize: totalSize
                    )
                }
                return nil
            }()
            
            // Create AI provider
            let aiProvider = settings.createAIProvider()
            
            // Execute task
            let task = try await L2AITaskExecutor.shared.executeTask(
                query: query,
                context: context,
                aiProvider: aiProvider
            )
            
            // Display results
            await MainActor.run {
                // Show completed steps
                for (index, step) in task.todoList.enumerated() {
                    let message = AIChatMessage(
                        role: .assistant,
                        content: "✅ Step \(index + 1): \(step.description)\n\(step.output ?? "")"
                    )
                    l2ChatMessages.append(message)
                }
                
                // Offer extension if suggested
                if let ext = task.suggestedExtension {
                    let extMessage = AIChatMessage(
                        role: .assistant,
                        content: """
                        💡 I can create a reusable extension for this:
                        
                        **\(ext.name)**
                        \(ext.description)
                        
                        Would you like to save it?
                        """,
                        hasInstallButton: true
                    )
                    l2ChatMessages.append(extMessage)
                }
                
                l2IsLoading = false
            }
        } catch {
            await MainActor.run {
                let errorMessage = AIChatMessage(
                    role: .assistant,
                    content: "❌ Error: \(error.localizedDescription)",
                    isError: true
                )
                l2ChatMessages.append(errorMessage)
                l2IsLoading = false
            }
        }
    }
}
```

## Tool Capabilities Database

Built-in knowledge of common tools:

### Image Tools
- **imagemagick**: convert, resize, compress, format conversion, watermark
- **sips**: image processing (built-in to macOS)
- **pngquant**: PNG compression
- **jpegoptim**: JPEG optimization

### PDF Tools
- **gs** (Ghostscript): compress, merge, split
- **pdftk**: manipulate PDFs
- **qpdf**: PDF optimization

### Video Tools
- **ffmpeg**: video conversion, compression, trimming

### Archives
- **zip, tar, 7z**: compression and archiving

## Example Workflows

### 1. Compress Image
```
User: "compress this image"
Context: image.jpg selected

AI Plan:
1. Detect imagemagick → Install if needed
2. Run: convert image.jpg -quality 85 image_compressed.jpg

Extension Created:
- Name: "Image Compressor"
- Triggers: jpg, png, gif
- Script: convert "$1" -quality 85 "${1%.*}_compressed.${1##*.}"
```

### 2. PDF to DOCX
```
User: "convert this PDF to Word document"
Context: report.pdf selected

AI Plan:
1. Detect pandoc → Install if needed
2. Run: pandoc report.pdf -o report.docx

Extension Created:
- Name: "PDF to DOCX Converter"
- Triggers: pdf
- Script: pandoc "$1" -o "${1%.pdf}.docx"
```

### 3. Batch Resize Images
```
User: "resize all these images to 800px wide"
Context: 5 JPG files selected

AI Plan:
1. Detect imagemagick → Already installed ✓
2. For each file: convert image.jpg -resize 800x image_800.jpg

Extension Created:
- Name: "Batch Image Resizer"
- Triggers: jpg, png
- Script: Loop through all arguments and resize
```

## Security Features

### Command Classification
All commands go through `TerminalCommandClassifier`:
- **Safe** (green): Auto-execute (ls, cat, grep)
- **Low** (green): Auto-execute with log
- **Medium** (yellow): Requires approval (brew install, git commit)
- **High** (orange): Warning + approval
- **Critical** (red): Blocked (rm -rf, sudo)

### User Control
- Approve/deny each command
- Edit commands before execution
- Remember choices for future
- Audit log of all executions

## Next Steps

1. **Add AI Provider Integration**
   - Connect to your existing AI system in ContentView
   - Pass real responses to L2AITaskExecutor

2. **Enhance Tool Database**
   - Add more tools to ToolCapabilities
   - Create category-specific recommendations

3. **UI Improvements**
   - Show live progress for each step
   - Visual tool installation flow
   - Extension management UI

4. **Learning System**
   - Track successful task patterns
   - Suggest extensions proactively
   - File type → extension mapping

## Testing

```swift
// Test query
let query = "compress this PDF"
let context = FileContext(
    selectedFiles: [URL(fileURLWithPath: "/path/to/file.pdf")],
    fileTypes: ["pdf"],
    totalSize: 1024000
)

let task = try await L2AITaskExecutor.shared.executeTask(
    query: query,
    context: context,
    aiProvider: settingsAIProvider
)

print("Status: \(task.status)")
print("Steps: \(task.todoList.count)")
```

## Summary

Your L2 is now a **powerful AI assistant** that:
✅ Understands natural language tasks
✅ Creates detailed execution plans
✅ Detects & installs required tools
✅ Executes commands safely
✅ Learns and creates reusable extensions
✅ Works with any selected file type

This transforms ILauncher from a simple launcher into an **intelligent automation system** that learns from every task!
