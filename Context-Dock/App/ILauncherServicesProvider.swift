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
        #if DEBUG
        print("🔧 [Services] handleFiles called")
        #endif
        #if DEBUG
        print("🔧 [Services] Pasteboard types: \(pasteboard.types ?? [])")
        #endif
        
        // Try multiple methods to get file URLs
        var fileURLs: [URL] = []
        
        // Method 1: Read as file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            fileURLs = urls
            #if DEBUG
            print("✅ [Services] Got \(urls.count) URLs via readObjects")
            #endif
        }
        
        // Method 2: Try getting file paths as strings
        if fileURLs.isEmpty, let paths = pasteboard.propertyList(forType: .string) as? String {
            let pathComponents = paths.components(separatedBy: "\n")
            fileURLs = pathComponents.compactMap { path in
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return URL(fileURLWithPath: trimmed)
            }
            #if DEBUG
            print("✅ [Services] Got \(fileURLs.count) URLs via string paths")
            #endif
        }
        
        guard !fileURLs.isEmpty else {
            #if DEBUG
            print("⚠️ [Services] No file URLs found in pasteboard")
            #endif
            error.pointee = "No files found in pasteboard" as NSString
            return
        }
        
        #if DEBUG
        print("📁 [Services] Received \(fileURLs.count) file(s):")
        #endif
        for (index, url) in fileURLs.enumerated() {
            #if DEBUG
            print("   \(index + 1). \(url.lastPathComponent) (\(url.path))")
            #endif
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
        #if DEBUG
        print("🔧 [Services] handleText called")
        #endif
        #if DEBUG
        print("🔧 [Services] Pasteboard types: \(pasteboard.types ?? [])")
        #endif
        
        guard let text = pasteboard.string(forType: .string) else {
            #if DEBUG
            print("⚠️ [Services] No text in pasteboard")
            #endif
            error.pointee = "No text found in pasteboard" as NSString
            return
        }
        
        let preview = text.prefix(100)
        #if DEBUG
        print("📝 [Services] Received text (\(text.count) chars): \"\(preview)\(text.count > 100 ? "..." : "")\"")
        #endif
        
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
        #if DEBUG
        print("🔧 [Services] handleURL called")
        #endif
        
        guard let urlString = pasteboard.string(forType: .string),
              let url = URL(string: urlString) else {
            #if DEBUG
            print("⚠️ [Services] No valid URL in pasteboard")
            #endif
            return
        }
        
        #if DEBUG
        print("🌐 [Services] Received URL: \(urlString)")
        #endif
        
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
        #if DEBUG
        print("🔧 [Services] openWithSelection called")
        #endif
        #if DEBUG
        print("🔧 [Services] Pasteboard types: \(pasteboard.types ?? [])")
        #endif
        
        var contextDetected = false
        
        // Try to get files first (highest priority)
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !fileURLs.isEmpty {
            #if DEBUG
            print("📁 [Services] Got \(fileURLs.count) file(s) from selection")
            #endif
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
            #if DEBUG
            print("📝 [Services] Got text from selection: \(text.prefix(100))...")
            #endif
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
            #if DEBUG
            print("⚠️ [Services] No valid data in pasteboard")
            #endif
            error.pointee = "No files or text found in selection" as NSString
            
            // Still open launcher, but without context
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                // Trigger show via hotkey notificationd
                NotificationCenter.default.post(name: .launcherWindowOpened, object: nil)
            }
        }
    }
}

// MARK: - Notification Names
