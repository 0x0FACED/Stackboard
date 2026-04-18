import AppKit

enum ClipboardSnapshot {
    case text(String)
    case image(NSImage)
    case file(URL)
}

enum ClipboardService {
    static func currentSnapshot(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot? {
        if let fileURL = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.first as? URL,
           fileURL.isFileURL {
            return .file(fileURL)
        }

        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
            return .image(image)
        }

        if let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .newlines),
           text.isEmpty == false {
            return .text(text)
        }

        return nil
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func copy(_ image: NSImage, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    static func copy(_ fileURL: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
    }
}
