import AppKit

extension NSImage {
    var pngData: Data? {
        guard
            let tiffData = tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
    }

    var pixelSize: CGSize {
        if let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }

        return size
    }

    func thumbnail(maxDimension: CGFloat) -> NSImage {
        let aspectRatio = size.width / max(size.height, 1)
        let targetSize: CGSize

        if aspectRatio >= 1 {
            targetSize = CGSize(width: maxDimension, height: maxDimension / aspectRatio)
        } else {
            targetSize = CGSize(width: maxDimension * aspectRatio, height: maxDimension)
        }

        let image = NSImage(size: targetSize)
        image.lockFocus()
        draw(in: CGRect(origin: .zero, size: targetSize))
        image.unlockFocus()
        return image
    }
}

func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
        return .zero
    }

    let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
    let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

    return CGRect(
        x: (containerSize.width - fittedSize.width) * 0.5,
        y: (containerSize.height - fittedSize.height) * 0.5,
        width: fittedSize.width,
        height: fittedSize.height
    )
}
