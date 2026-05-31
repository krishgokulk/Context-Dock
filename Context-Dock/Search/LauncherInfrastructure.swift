import AddressBook
import AppIntents
import AppKit
import Combine  // For ObservableObject
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz  // For Quick Look
// WebKit removed — L3 is now the media player layer
import SwiftTerm  // For terminal integration
import SwiftUI
import UniformTypeIdentifiers
import Vision

// SearchResult → moved to SearchResult.swift

final class MenuIconMemoryCache {
    static let shared = MenuIconMemoryCache()

    private let lock = NSLock()
    private var images: [String: NSImage] = [:]
    private var misses = Set<String>()

    private init() {}

    func image(for key: String, load: () -> NSImage?) -> NSImage? {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedKey.isEmpty else { return nil }

        lock.lock()
        if let image = images[normalizedKey] {
            lock.unlock()
            return image
        }
        if misses.contains(normalizedKey) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let image = load() else {
            lock.lock()
            misses.insert(normalizedKey)
            lock.unlock()
            return nil
        }

        lock.lock()
        images[normalizedKey] = image
        lock.unlock()
        return image
    }
}

final class FinderFolderSnapshotWatcher {
    let path: String
    private let fileDescriptor: CInt
    private let source: DispatchSourceFileSystemObject
    private var isStopped = false

    init?(path: String, onChange: @escaping (String) -> Void) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let fd = Darwin.open(normalizedPath, O_EVTONLY)
        guard fd >= 0 else { return nil }

        self.path = normalizedPath
        self.fileDescriptor = fd
        self.source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            onChange(self.path)
        }
        source.setCancelHandler { [fileDescriptor] in
            Darwin.close(fileDescriptor)
        }
        source.resume()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        source.cancel()
    }

    deinit {
        stop()
    }
}

struct OptionalDragProviderModifier: ViewModifier {
    let provider: (() -> NSItemProvider?)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let provider {
            content.onDrag {
                provider() ?? NSItemProvider()
            }
        } else {
            content
        }
    }
}

// MARK: - Shortcuts Query Helper
class ShortcutsLinkQuery {
    struct ShortcutInfo {
        let name: String
    }

    func shortcuts() throws -> [ShortcutInfo] {
        var results: [ShortcutInfo] = []

        // Method 1: Try using the shortcuts command-line tool
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["list"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse the output - each line is a shortcut name
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        results.append(ShortcutInfo(name: trimmed))
                    }
                }
            }

            if task.terminationStatus == 0 {
                print("✅ Successfully queried shortcuts using CLI tool")
                return results
            }
        } catch {
            print("⚠️ Failed to use shortcuts CLI: \(error)")
        }

        // Method 2: Fallback to AppleScript
        print("📝 Trying AppleScript fallback...")
        let script = """
            tell application "Shortcuts Events"
                get name of every shortcut
            end tell
            """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let output = scriptObject.executeAndReturnError(&error)

            if let error = error {
                print("AppleScript error: \(error)")
                throw NSError(
                    domain: "ShortcutsQuery", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to query shortcuts: \(error)"])
            }

            // Parse the AppleScript result
            if output.numberOfItems > 0 {
                for i in 1...output.numberOfItems {
                    if let name = output.atIndex(i)?.stringValue {
                        results.append(ShortcutInfo(name: name))
                    }
                }
            }
        }

        return results
    }
}

// FuzzyMatcher → moved to FuzzyMatcher.swift

// ShortcutMetadata, ShortcutMetadataJSON, GroupedResults → moved to SearchResult.swift
