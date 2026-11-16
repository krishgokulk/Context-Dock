import AppKit
import Contacts
import QuickLookThumbnailing
import SwiftUI

enum ApprovalCardEnrichment {

    // MARK: - Contact Photo

    static func contactPhoto(for query: String) -> NSImage? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]

        // Try name predicate first
        if !trimmed.contains("@"),
           trimmed.rangeOfCharacter(from: .decimalDigits) == nil || trimmed.contains(" ")
        {
            if let contacts = try? store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: trimmed),
                keysToFetch: keys),
               let match = contacts.first,
               let data = match.thumbnailImageData
            {
                return NSImage(data: data)
            }
        }

        // Try phone number
        if trimmed.rangeOfCharacter(from: .decimalDigits) != nil, trimmed.count >= 7 {
            let phoneNumber = CNPhoneNumber(stringValue: trimmed)
            if let contacts = try? store.unifiedContacts(
                matching: CNContact.predicateForContacts(matching: phoneNumber),
                keysToFetch: keys),
               let match = contacts.first,
               let data = match.thumbnailImageData
            {
                return NSImage(data: data)
            }
        }

        // Try email
        if trimmed.contains("@") {
            if let contacts = try? store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingEmailAddress: trimmed),
                keysToFetch: keys),
               let match = contacts.first,
               let data = match.thumbnailImageData
            {
                return NSImage(data: data)
            }
        }

        return nil
    }

    // MARK: - File Thumbnail

    static func fileThumbnail(at path: String, size: CGSize = CGSize(width: 48, height: 48)) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: 2.0,
            representationTypes: .thumbnail)
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let img = representation.nsImage
            if img.size.width > 0 { return img }
        } catch {}
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = size
        return icon
    }

    static func fileIcon(at path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    static func fileName(at path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func fileSize(at path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = attrs[.size] as? Int64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
