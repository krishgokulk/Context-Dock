// DropShelfItem.swift
// Context-Dock
//
// One thing the user parked on the shelf. The shelf owns a *copy* of it, so an item
// stays valid after the original is renamed, moved, or deleted — which is the whole
// point of parking something rather than remembering where it was.

import Foundation

struct DropShelfItem: Identifiable, Codable, Equatable {
    /// Top-level folder in the shelf. The user opens this directory in Finder, so the
    /// names are the ones they would have chosen themselves.
    enum Kind: String, Codable, CaseIterable {
        case images
        case documents
        case text
        case links
        case archives
        case other

        var folderName: String {
            switch self {
            case .images: return "Images"
            case .documents: return "Documents"
            case .text: return "Text"
            case .links: return "Links"
            case .archives: return "Archives"
            case .other: return "Other"
            }
        }

        static func fromFolderName(_ name: String) -> Kind? {
            allCases.first { $0.folderName == name }
        }
    }

    let id: UUID
    /// Path under the shelf root. Relative so the shelf survives the container moving.
    var relativePath: String
    var kind: Kind
    var originalName: String
    var sourceAppName: String
    var sourceBundleId: String
    var droppedAt: Date

    init(
        id: UUID = UUID(),
        relativePath: String,
        kind: Kind,
        originalName: String,
        sourceAppName: String = "",
        sourceBundleId: String = "",
        droppedAt: Date = Date()
    ) {
        self.id = id
        self.relativePath = relativePath
        self.kind = kind
        self.originalName = originalName
        self.sourceAppName = sourceAppName
        self.sourceBundleId = sourceBundleId
        self.droppedAt = droppedAt
    }
}
