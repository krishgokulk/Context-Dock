// ChatImagePaste.swift
// Context-Dock
//
// ⌘V of an image, in a chat input field.
//
// Every composer in the app is a SwiftUI `TextField`, which accepts text off the
// pasteboard and silently ignores everything else. So a user who copied a screenshot —
// from Preview, from ⌘⇧4, from another chat — pressed ⌘V into the box and nothing at all
// happened. Not an error, not a chip: nothing. The only way in was the + menu, which is
// two clicks away from a gesture people have used for thirty years.
//
// A local key monitor takes ⌘V before the field does, but only when the pasteboard
// actually holds an image or image files. Text paste is untouched — the event is passed
// straight through — so the ordinary case behaves exactly as it did.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ChatImagePaste {

    /// Image files on the pasteboard, written to disk if they were raw image data.
    ///
    /// Returns an empty array when the pasteboard holds anything else, which is what keeps
    /// this from swallowing an ordinary text paste.
    static func imagesOnPasteboard() -> [URL] {
        let pasteboard = NSPasteboard.general

        // File copies from Finder come through as URLs already, and keeping the original
        // file means keeping its name, which is what the user recognises in the chip.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let images = urls.filter {
                guard let type = UTType(filenameExtension: $0.pathExtension) else { return false }
                return type.conforms(to: .image)
            }
            if !images.isEmpty { return images }
        }

        // A screenshot or a copied image is raw data, so it needs a file of its own before
        // anything downstream can attach it.
        guard let image = NSImage(pasteboard: pasteboard),
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return [] }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970)).png")
        guard (try? png.write(to: url)) != nil else { return [] }
        return [url]
    }
}

extension View {
    /// Accepts pasted images into a chat composer.
    ///
    /// `onPasteCommand` is not enough here: a focused `TextField` consumes ⌘V itself, so
    /// the modifier never fires for the case that matters.
    func acceptsPastedImages(_ handler: @escaping ([URL]) -> Void) -> some View {
        modifier(ChatImagePasteModifier(handler: handler))
    }
}

private struct ChatImagePasteModifier: ViewModifier {
    let handler: ([URL]) -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.contains(.command),
                        !event.modifierFlags.contains(.option),
                        event.charactersIgnoringModifiers?.lowercased() == "v"
                    else { return event }

                    let images = ChatImagePaste.imagesOnPasteboard()
                    // Nothing image-shaped on the pasteboard: this is a text paste, and it
                    // belongs to the text field.
                    guard !images.isEmpty else { return event }

                    handler(images)
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
