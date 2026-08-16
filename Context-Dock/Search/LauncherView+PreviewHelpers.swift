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
    /// Folders go to the preview surface like everything else. `folderPreviewPath` stays
    /// because the scope key reads it — it says which folder is being looked at, which is
    /// still true.
    ///
    /// `toggleIfSame` is false when the caller is retargeting an open preview as the
    /// selection moves — there, landing back on the same folder must re-show it, not
    /// close the window out from under the arrow keys.
    func showFolderPreviewInline(path: String, toggleIfSame: Bool = true) {
        folderPreviewPath = path
        PreviewController.shared.present(
            url: URL(fileURLWithPath: path),
            toggleIfSame: toggleIfSame
        )
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
