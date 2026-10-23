import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum EditorImageImport {
    static let supportedContentTypes: [UTType] = {
        let identifiers = CGImageSourceCopyTypeIdentifiers() as! [String]
        return identifiers.compactMap { UTType($0) }.filter {
            $0.conforms(to: .image)
                && !$0.conforms(to: .svg)
                // Generic ImageIO RAW decoding can return an embedded preview.
                && !$0.conforms(to: .rawImage)
        }
    }()

    static func fromFile(_ url: URL) throws -> NSImage {
        guard url.isFileURL else { throw ImportError.unsupportedImage }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImportError.unreadableFile(url.lastPathComponent)
        }
        return try image(from: source)
    }

    static func fromPasteboard(_ pasteboard: NSPasteboard) throws -> NSImage {
        let preferredTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        var hasImageRepresentation = false
        // The board-wide types include macOS conversions synthesized from the first
        // representation. Read declared item data, or a small JPEG can masquerade as TIFF.
        for item in pasteboard.pasteboardItems ?? [] {
            let advertisedTypes = item.types
            let candidates = preferredTypes.filter { advertisedTypes.contains($0) }
                + advertisedTypes.filter { !preferredTypes.contains($0) && isRasterRepresentation($0) }
            if !candidates.isEmpty { hasImageRepresentation = true }
            for type in candidates {
                guard let data = item.data(forType: type),
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else { continue }
                if let image = try? image(from: source) {
                    return image
                }
            }
        }
        throw hasImageRepresentation ? ImportError.damagedClipboardImage : ImportError.noClipboardImage
    }

    private static let supportedTypeIdentifiers = Set(supportedContentTypes.map(\.identifier))

    private static func isRasterRepresentation(_ pasteboardType: NSPasteboard.PasteboardType) -> Bool {
        guard let type = UTType(pasteboardType.rawValue) else { return false }
        return type.conforms(to: .image)
            && !type.conforms(to: .svg)
            && !type.conforms(to: .rawImage)
    }

    private static func image(from source: CGImageSource) throws -> NSImage {
        guard let identifier = CGImageSourceGetType(source),
              supportedTypeIdentifiers.contains(identifier as String) else {
            throw ImportError.unsupportedImage
        }
        guard CGImageSourceGetCount(source) > 0 else { throw ImportError.damagedImage }

        // Decode the first full image, never its embedded thumbnail. Eager decoding also
        // makes damage an import error rather than a later drawing failure.
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ]
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary),
              decoded.width > 0, decoded.height > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ImportError.damagedImage
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientationValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let orientation = (1...8).contains(orientationValue)
            ? CGImagePropertyOrientation(rawValue: UInt32(orientationValue)) ?? .up
            : .up
        var pointSize = CGSize(
            width: logicalLength(pixels: decoded.width, dpi: properties[kCGImagePropertyDPIWidth]),
            height: logicalLength(pixels: decoded.height, dpi: properties[kCGImagePropertyDPIHeight])
        )
        if swapsAxes(orientation) {
            pointSize = CGSize(width: pointSize.height, height: pointSize.width)
        }
        return NSImage(cgImage: try normalized(decoded, orientation: orientation), size: pointSize)
    }

    private static func logicalLength(pixels: Int, dpi value: Any?) -> CGFloat {
        guard let dpi = (value as? NSNumber)?.doubleValue, dpi.isFinite, dpi > 0 else {
            return CGFloat(pixels)
        }
        let points = Double(pixels) * 72 / dpi
        return points.isFinite && points > 0 ? CGFloat(points) : CGFloat(pixels)
    }

    private static func swapsAxes(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .leftMirrored, .right, .rightMirrored, .left: return true
        default: return false
        }
    }

    private static func normalized(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> CGImage {
        guard orientation != .up else { return image }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let transform: CGAffineTransform
        switch orientation {
        case .up:
            return image
        case .upMirrored:
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case .down:
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case .downMirrored:
            transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case .leftMirrored:
            transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case .right:
            transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case .rightMirrored:
            transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left:
            transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        @unknown default:
            throw ImportError.unsupportedImage
        }

        guard let sourceSpace = image.colorSpace else { throw ImportError.unsupportedImage }
        // Indexed palettes cannot back a bitmap context; their base space carries the profile.
        let colorSpace = sourceSpace.model == .indexed ? sourceSpace.baseColorSpace : sourceSpace
        guard let colorSpace else { throw ImportError.unsupportedImage }
        let alpha: CGImageAlphaInfo = colorSpace.model == .cmyk ? .none : .premultipliedLast
        var bitmapInfo = CGBitmapInfo(rawValue: alpha.rawValue)
        if image.bitmapInfo.contains(.floatComponents) {
            bitmapInfo.insert(.floatComponents)
        }
        let outputWidth = swapsAxes(orientation) ? image.height : image.width
        let outputHeight = swapsAxes(orientation) ? image.width : image.height
        // Quartz bitmap contexts use 8-, 16-, or 32-bit components, not packed 10/12-bit samples.
        let bitsPerComponent = image.bitsPerComponent <= 8 ? 8 : image.bitsPerComponent <= 16 ? 16 : 32
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { throw ImportError.unsupportedImage }

        // Exactly one destination raster is needed only for a non-upright source.
        // Keeping the source color space avoids a needless sRGB/profile conversion.
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = context.makeImage() else { throw ImportError.damagedImage }
        return normalized
    }

    private enum ImportError: LocalizedError {
        case unreadableFile(String)
        case unsupportedImage
        case damagedImage
        case noClipboardImage
        case damagedClipboardImage

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let name):
                return "The file “\(name)” could not be opened as a raster image. It may be unreadable, damaged, or unsupported."
            case .unsupportedImage:
                return "This image format is not supported. Choose a raster image such as PNG, JPEG, TIFF, or HEIF."
            case .damagedImage:
                return "The image could not be decoded at its full resolution. It may be incomplete or damaged."
            case .noClipboardImage:
                return "The clipboard does not contain an image. Copy image pixels, not a file or a text path, then try again."
            case .damagedClipboardImage:
                return "The clipboard image could not be opened. Its image data may be damaged or unsupported."
            }
        }
    }
}
