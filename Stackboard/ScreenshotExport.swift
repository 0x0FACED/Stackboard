import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotExportFormat: String, CaseIterable {
    case png = "PNG"
    case jpeg = "JPEG"

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }

    func write(_ image: NSImage, to url: URL, jpegQuality: Double) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScreenshotExportError.renderingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, contentType.identifier as CFString, 1, nil
        ) else {
            throw ScreenshotExportError.encodingFailed
        }
        var properties: [CFString: Any] = [:]
        if self == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
            // JPEG cannot store alpha; composite transparent source pixels over white.
            properties[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1)
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotExportError.encodingFailed
        }
        try (data as Data).write(to: url, options: .atomic)
    }
}

enum ScreenshotExportError: LocalizedError {
    case renderingFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .renderingFailed: return "The screenshot could not be rendered."
        case .encodingFailed: return "The screenshot could not be encoded in the selected format."
        }
    }
}
