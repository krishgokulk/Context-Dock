import AddressBook
import AppIntents
import AppKit
import Combine
import Contacts
import Darwin
import FoundationModels
import PDFKit
import Quartz
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import Vision

extension LauncherView {
    // MARK: - Folder Preview Helper
    func showFolderPreviewInline(path: String) {
        #if DEBUG
        print("📂 Opening folder preview inline: \(path)")
        #endif
        folderPreviewPath = path
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showFolderPreview = true
        }
    }

    func quickLookSelectedItem() {
        guard let index = searchState.selectedIndex, index < searchState.results.count else {
            return
        }
        let result = searchState.results[index]

        // Handle contacts separately - show contact preview
        if result.type == .contact {
            contactPreviewData = result
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showContactPreview = true
            }
            return
        }

        // Only Quick Look files and folders
        guard let filePath = result.filePath else {
            #if DEBUG
            print("⚠️ Cannot Quick Look: No file path")
            #endif
            return
        }

        let url = URL(fileURLWithPath: filePath)

        // Verify the file/folder exists
        guard FileManager.default.fileExists(atPath: filePath) else {
            #if DEBUG
            print("⚠️ File does not exist: \(filePath)")
            #endif
            return
        }

        // For folders, show custom preview
        if result.type == .folder {
            #if DEBUG
            print("👁️ Showing custom folder preview for: \(filePath)")
            #endif
            showFolderPreviewInline(path: filePath)
            return
        }

        // For files, use Quick Look
        #if DEBUG
        print("👁️ Quick Look preview for file: \(filePath)")
        #endif

        _ = showQuickLookURL(url, toggleIfSame: true)
    }

    // MARK: - Browser Helper Functions
    func openBrowserURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

}
