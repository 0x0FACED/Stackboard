import AppKit
import SwiftUI

enum ClipboardUIStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.47, green: 0.92, blue: 0.81, alpha: 1)
        }
        return NSColor(srgbRed: 0.04, green: 0.40, blue: 0.34, alpha: 1)
    })
    static let selectionFill = accent.opacity(0.12)
    static let contentBackground = Color(nsColor: .textBackgroundColor)
}

struct ClipboardItemThumbnail: View {
    let item: ClipboardHistoryItem
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.44))
                    .foregroundStyle(isMissingFile ? Color.orange : .secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var isMissingFile: Bool {
        item.kind == .file && item.fileExists == false
    }

    private var systemImage: String {
        switch item.kind {
        case .text: return "doc.text"
        case .image: return "photo"
        case .file: return isMissingFile ? "exclamationmark.triangle" : "doc"
        }
    }
}
