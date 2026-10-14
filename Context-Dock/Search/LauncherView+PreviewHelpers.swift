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


}
