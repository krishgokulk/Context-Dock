//
//  ServicesProvider.swift
//  ILauncher
//
//  Created by ILauncher on 23/12/2025.
//

import AppKit
import Foundation

/// Provides macOS Services menu integration for ILauncher
/// This allows shortcuts to appear in the Services menu of all apps
@objc class ServicesProvider: NSObject {
    
    static let shared = ServicesProvider()
    
    private override init() {
        super.init()
    }
    
    // MARK: - Service Methods
    
    /// Handle files sent via Services menu
    @objc func handleFiles(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        print("🔧 [Services] handleFiles called")
        print("🔧 [Services] Pasteboard types: \(pasteboard.types ?? [])")
        
        // Try multiple methods to get file URLs
        var fileURLs: [URL] = []
        
        // Method 1: Read as file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            fileURLs = urls
            print("✅ [Services] Got \(urls.count) URLs via readObjects")
        }
        
        // Method 2: Try getting file paths as strings
        if fileURLs.isEmpty, let paths = pasteboard.propertyList(forType: .string) as? String {
            let pathComponents = paths.components(separatedBy: "\n")
            fileURLs = pathComponents.compactMap { path in
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return URL(fileURLWithPath: trimmed)
            }
            print("✅ [Services] Got \(fileURLs.count) URLs via string paths")
        }
        
        guard !fileURLs.isEmpty else {
            print("⚠️ [Services] No file URLs found in pasteboard")
            error.pointee = "No files found in pasteboard" as NSString
            return
        }
        
        print("📁 [Services] Received \(fileURLs.count) file(s):")
        for (index, url) in fileURLs.enumerated() {
            print("   \(index + 1). \(url.lastPathComponent) (\(url.path))")
        }
        
        // Post notification with file URLs
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .servicesFilesReceived,
                object: nil,
                userInfo: ["urls": fileURLs]
            )
            
            // Also trigger the launcher to open
            NotificationCenter.default.post(
                name: .servicesOpenWithFiles,
                object: nil,
                userInfo: ["urls": fileURLs]
            )
        }
    }
    
    /// Handle text sent via Services menu
    @objc func handleText(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        print("🔧 [Services] handleText called")
        print("🔧 [Services] Pasteboard types: \(pasteboard.types ?? [])")
        
        guard let text = pasteboard.string(forType: .string) else {
            print("⚠️ [Services] No text in pasteboard")
            error.pointee = "No text found in pasteboard" as NSString
            return
        }
        
        let preview = text.prefix(100)
        print("📝 [Services] Received text (\(text.count) chars): \"\(preview)\(text.count > 100 ? "..." : "")\"")
        
        // Post notification with text
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .servicesTextReceived,
                object: nil,
                userInfo: ["text": text]
            )
            
            // Also trigger the launcher to open
            NotificationCenter.default.post(
                name: .servicesOpenWithText,
                object: nil,
                userInfo: ["text": text]
            )
        }
    }
    
    /// Handle URLs sent via Services menu
    @objc func handleURL(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        print("🔧 [Services] handleURL called")
        
        guard let urlString = pasteboard.string(forType: .string),
              let url = URL(string: urlString) else {
            print("⚠️ [Services] No valid URL in pasteboard")
            return
        }
        
        print("🌐 [Services] Received URL: \(urlString)")
        
        // Post notification with URL
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .servicesURLReceived,
                object: nil,
                userInfo: ["url": url, "urlString": urlString]
            )
        }
    }
    
    /// Open ILauncher with the current selection
    @objc func openWithSelection(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        print("🔧 [Services] openWithSelection called")
        print("🔧 [Services] Pasteboard types: \(pasteboard.types ?? [])")
        
        var contextDetected = false
        
        // Try to get files first (highest priority)
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !fileURLs.isEmpty {
            print("📁 [Services] Got \(fileURLs.count) file(s) from selection")
            DispatchQueue.main.async {
                // Activate app and show launcher
                NSApp.activate(ignoringOtherApps: true)
                
                // Post notification to open with files
                NotificationCenter.default.post(
                    name: .servicesOpenWithFiles,
                    object: nil,
                    userInfo: ["urls": fileURLs]
                )
            }
            contextDetected = true
        }
        
        // Try to get text (if no files)
        if !contextDetected, let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("📝 [Services] Got text from selection: \(text.prefix(100))...")
            DispatchQueue.main.async {
                // Activate app and show launcher
                NSApp.activate(ignoringOtherApps: true)
                
                // Post notification to open with text
                NotificationCenter.default.post(
                    name: .servicesOpenWithText,
                    object: nil,
                    userInfo: ["text": text]
                )
            }
            contextDetected = true
        }
        
        if !contextDetected {
            print("⚠️ [Services] No valid data in pasteboard")
            error.pointee = "No files or text found in selection" as NSString
            
            // Still open launcher, but without context
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                // Trigger show via hotkey notification
                NotificationCenter.default.post(name: .launcherWindowOpened, object: nil)
            }
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let servicesFilesReceived = Notification.Name("servicesFilesReceived")
    static let servicesTextReceived = Notification.Name("servicesTextReceived")
    static let servicesURLReceived = Notification.Name("servicesURLReceived")
    static let servicesOpenWithFiles = Notification.Name("servicesOpenWithFiles")
    static let servicesOpenWithText = Notification.Name("servicesOpenWithText")
}
