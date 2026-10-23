import AppKit
import ImageIO
import UniformTypeIdentifiers

private enum Failure: Error {
    case check(String)
}

@MainActor
private func expect(_ condition: Bool, _ message: String) throws {
    if condition == false { throw Failure.check(message) }
}

@MainActor
private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@MainActor
private func fixture(width: Int = 1600, height: Int = 960, alpha: Bool = true) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let w = CGFloat(width)
    let h = CGFloat(height)
    let colors = [
        NSColor(srgbRed: 0.85, green: 0.12, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.75, blue: 0.21, alpha: 1),
        NSColor(srgbRed: 0.13, green: 0.24, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.78, blue: 0.12, alpha: 1),
    ]
    for row in 0..<2 {
        for column in 0..<2 {
            context.setFillColor(colors[row * 2 + column].cgColor)
            context.fill(CGRect(x: CGFloat(column) * w / 2, y: CGFloat(row) * h / 2, width: w / 2, height: h / 2))
        }
    }
    if alpha {
        context.clear(CGRect(x: w * 5 / 8, y: h / 8, width: w / 8, height: h / 8))
        let translucent = CGRect(x: w * 5 / 8, y: h * 5 / 8, width: w / 8, height: h / 8)
        context.clear(translucent)
        context.setFillColor(NSColor(srgbRed: 0.6, green: 0.2, blue: 0.8, alpha: 0.4).cgColor)
        context.fill(translucent)
    }
    // Adjacent single-pixel stripes distinguish native decoding from a resized thumbnail.
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: w / 2 - 1, y: h / 2 - 11, width: 1, height: 23))
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: w / 2, y: h / 2 - 11, width: 1, height: 23))
    return context.makeImage()!
}

@MainActor
private func encoded(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
        throw Failure.check("Could not create the image fixture encoder")
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try expect(CGImageDestinationFinalize(destination), "Could not encode the image fixture")
    return data as Data
}

@MainActor
private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw Failure.check("The imported image has no native raster pixels")
    }
    return NSBitmapImageRep(cgImage: cgImage)
}

@MainActor
private func composite(_ document: EditorDocument) throws -> NSBitmapImageRep {
    guard let image = document.renderCompositeImage() else {
        throw Failure.check("Could not render the imported document")
    }
    return try bitmap(image)
}

@MainActor
private func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor {
    let raw = bitmap.colorAt(x: x, y: y)!
    // Respect each bitmap's ICC profile, rather than assuming byte layout or device RGB.
    var components = [raw.redComponent, raw.greenComponent, raw.blueComponent, raw.alphaComponent]
    return NSColor(colorSpace: bitmap.colorSpace, components: &components, count: 4)
        .usingColorSpace(.sRGB)!
}

@MainActor
private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
    if a.alphaComponent < 0.001 && b.alphaComponent < 0.001 { return 0 }
    return max(
        abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
        abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent)
    )
}

@MainActor
private func expectSamePixels(_ actual: NSBitmapImageRep, _ expected: NSBitmapImageRep, _ message: String) throws {
    try expect(
        actual.pixelsWide == expected.pixelsWide && actual.pixelsHigh == expected.pixelsHigh,
        "\(message): native pixel dimensions changed"
    )
    let w = expected.pixelsWide
    let h = expected.pixelsHigh
    var points: [(Int, Int)] = []
    for y in stride(from: 0, to: h, by: max(1, h / 17)) {
        for x in stride(from: 0, to: w, by: max(1, w / 19)) { points.append((x, y)) }
    }
    points += [(1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2)]
    points += [(w * 11 / 16, h * 13 / 16), (w * 11 / 16, h * 5 / 16)]
    for y in (h / 2 - 3)...(h / 2 + 3) {
        for x in (w / 2 - 3)...(w / 2 + 3) { points.append((x, y)) }
    }
    for (x, y) in points {
        try expect(
            distance(color(actual, x: x, y: y), color(expected, x: x, y: y)) < 0.02,
            "\(message): normalized color or alpha changed at (\(x), \(y))"
        )
    }
}

private struct FileSnapshot: Equatable {
    let data: Data
    let modificationDate: Date?

    init(_ url: URL) throws {
        data = try Data(contentsOf: url)
        modificationDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private struct PasteboardItemSnapshot: Equatable {
    let types: [String]
    let data: [Data?]
}

private struct PasteboardSnapshot: Equatable {
    let changeCount: Int
    let items: [PasteboardItemSnapshot]

    @MainActor
    init(_ pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        items = (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(
                types: item.types.map(\.rawValue), data: item.types.map { item.data(forType: $0) }
            )
        }
    }
}

@MainActor
private func filePNG() throws {
    try withTemporaryDirectory { directory in
        let native = fixture()
        let expected = NSBitmapImageRep(cgImage: native)
        let url = directory.appendingPathComponent("native.png")
        try encoded(native, as: .png).write(to: url)
        let before = try FileSnapshot(url)
        let imported = try EditorImageImport.fromFile(url)
        try expectSamePixels(bitmap(imported), expected, "Opening PNG")
        let document = EditorDocument(baseImage: imported)
        try expect(document.pixelSize == CGSize(width: 1600, height: 960), "The document used a fitted preview size")
        try expectSamePixels(composite(document), expected, "Rendering imported PNG")
        try expect(try FileSnapshot(url) == before, "Import modified the original file or its modification date")
    }
}

@MainActor
private func clipboardPNG() throws {
    let native = fixture()
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let item = NSPasteboardItem()
    try expect(
        item.setData(try encoded(fixture(width: 80, height: 48, alpha: false), as: .jpeg), forType: .init("public.jpeg")),
        "Could not prepare the lower-resolution clipboard representation"
    )
    try expect(item.setData(try encoded(native, as: .png), forType: .png), "Could not prepare the clipboard PNG")
    try expect(item.setString("Clipboard text must not replace its image", forType: .string), "Could not prepare clipboard text")
    try expect(pasteboard.writeObjects([item]), "Could not populate the named clipboard")
    let before = PasteboardSnapshot(pasteboard)
    let imported = try EditorImageImport.fromPasteboard(pasteboard)
    let expected = NSBitmapImageRep(cgImage: native)
    try expectSamePixels(bitmap(imported), expected, "Opening clipboard PNG instead of its small JPEG")
    try expectSamePixels(composite(EditorDocument(baseImage: imported)), expected, "Rendering clipboard PNG")
    try expect(PasteboardSnapshot(pasteboard) == before, "Import changed clipboard items, bytes, or change count")
}

@MainActor
private func jpegOrientation() throws {
    try withTemporaryDirectory { directory in
        let native = fixture(width: 192, height: 128, alpha: false)
        let url = directory.appendingPathComponent("portrait.jpg")
        try encoded(native, as: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImageDestinationLossyCompressionQuality: 1,
        ]).write(to: url)
        let before = try FileSnapshot(url)
        let imported = try EditorImageImport.fromFile(url)
        let actual = try bitmap(imported)
        let original = NSBitmapImageRep(cgImage: native)
        try expect(actual.pixelsWide == 128 && actual.pixelsHigh == 192, "EXIF portrait orientation did not swap native dimensions")
        // EXIF 6 is a clockwise quarter-turn in top-left image coordinates.
        for (x, y) in [(18, 18), (173, 18), (18, 109), (173, 109)] {
            try expect(
                distance(color(actual, x: 127 - y, y: x), color(original, x: x, y: y)) < 0.08,
                "EXIF portrait orientation put a colored corner in the wrong location"
            )
        }
        try expectSamePixels(composite(EditorDocument(baseImage: imported)), actual, "Rendering the upright JPEG")
        try expect(try FileSnapshot(url) == before, "Orientation normalization rewrote the source JPEG")
    }
}

@MainActor
private func clipboardRetinaTIFF() throws {
    let native = fixture(width: 384, height: 256)
    let representation = NSBitmapImageRep(cgImage: native)
    representation.size = CGSize(width: 192, height: 128)
    guard let tiff = representation.representation(using: .tiff, properties: [:]) else {
        throw Failure.check("Could not encode the Retina TIFF fixture")
    }
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let item = NSPasteboardItem()
    try expect(item.setData(tiff, forType: .tiff), "Could not prepare clipboard TIFF")
    try expect(pasteboard.writeObjects([item]), "Could not populate the named clipboard")
    let before = PasteboardSnapshot(pasteboard)
    let imported = try EditorImageImport.fromPasteboard(pasteboard)
    try expect(
        abs(imported.size.width - 192) < 0.01 && abs(imported.size.height - 128) < 0.01,
        "Retina TIFF lost its two-native-pixels-per-logical-point metadata"
    )
    try expectSamePixels(bitmap(imported), representation, "Opening Retina TIFF")
    let document = EditorDocument(baseImage: imported)
    try expect(document.pixelSize == CGSize(width: 384, height: 256), "The Retina document used logical points as pixels")
    try expectSamePixels(composite(document), representation, "Rendering Retina TIFF")
    try expect(PasteboardSnapshot(pasteboard) == before, "Retina import changed the source clipboard")
}

@MainActor
private func expectImportError(_ message: String, _ operation: () throws -> NSImage) throws {
    do {
        _ = try operation()
    } catch {
        try expect(error is LocalizedError, "\(message): failure is not a user-facing LocalizedError")
        return
    }
    throw Failure.check("\(message): import unexpectedly succeeded")
}

@MainActor
private func importErrors() throws {
    try withTemporaryDirectory { directory in
        let textURL = directory.appendingPathComponent("notes.txt")
        try Data("This is not an image.".utf8).write(to: textURL)
        let corruptURL = directory.appendingPathComponent("damaged.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]).write(to: corruptURL)
        let pdfURL = directory.appendingPathComponent("vector.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 120, height: 80)
        guard let consumer = CGDataConsumer(url: pdfURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw Failure.check("Could not create the unsupported vector fixture")
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.red.cgColor)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        for url in [textURL, corruptURL, pdfURL] {
            let before = try FileSnapshot(url)
            try expectImportError("Rejecting \(url.lastPathComponent)") { try EditorImageImport.fromFile(url) }
            try expect(try FileSnapshot(url) == before, "A failed import changed its source file")
        }

        let imageURL = directory.appendingPathComponent("real-image.png")
        try encoded(fixture(width: 160, height: 96), as: .png).write(to: imageURL)
        for type in [NSPasteboard.PasteboardType.string, .fileURL] {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let value = type == .string ? imageURL.path : imageURL.absoluteString
            let item = NSPasteboardItem()
            try expect(item.setString(value, forType: type), "Could not prepare a non-image clipboard")
            try expect(pasteboard.writeObjects([item]), "Could not populate the named non-image clipboard")
            let before = PasteboardSnapshot(pasteboard)
            try expectImportError("Rejecting clipboard \(type.rawValue)") { try EditorImageImport.fromPasteboard(pasteboard) }
            try expect(PasteboardSnapshot(pasteboard) == before, "A failed import changed the clipboard")
        }
        let empty = NSPasteboard.withUniqueName()
        defer { empty.releaseGlobally() }
        let before = PasteboardSnapshot(empty)
        try expectImportError("Rejecting an empty clipboard") { try EditorImageImport.fromPasteboard(empty) }
        try expect(PasteboardSnapshot(empty) == before, "An empty clipboard was changed by import")
    }
}

@MainActor
private func rectangle(_ document: EditorDocument, color: EditorColor) {
    document.activateTool(.rectangle)
    document.setShapeStyle(.filled)
    document.applySelectedColor(color)
    document.beginInteraction(at: CGPoint(x: 40, y: 40))
    document.endInteraction(at: CGPoint(x: 160, y: 120))
}

@MainActor
private func documentIsolation() throws {
    try withTemporaryDirectory { directory in
        let native = fixture(width: 320, height: 224)
        let data = try encoded(native, as: .png)
        let url = directory.appendingPathComponent("original.png")
        try data.write(to: url)
        let fileBefore = try FileSnapshot(url)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        try expect(item.setData(data, forType: .png), "Could not prepare clipboard document")
        try expect(pasteboard.writeObjects([item]), "Could not populate the clipboard document")
        let clipboardBefore = PasteboardSnapshot(pasteboard)
        let firstImage = try EditorImageImport.fromFile(url)
        let secondImage = try EditorImageImport.fromPasteboard(pasteboard)
        let firstPointSize = firstImage.size
        let secondPointSize = secondImage.size
        let original = NSBitmapImageRep(cgImage: native)
        let first = EditorDocument(baseImage: firstImage)
        let second = EditorDocument(baseImage: secondImage)

        rectangle(first, color: EditorColor(red: 0.9, green: 0.1, blue: 0.8, alpha: 1))
        let firstAnnotations = first.annotations
        let firstComposite = try composite(first)
        try expect(
            firstAnnotations.count == 1 && second.annotations.isEmpty && second.canUndo == false,
            "Creating an annotation in the file document changed the clipboard document"
        )
        try expect(
            distance(color(firstComposite, x: 100, y: 80), color(original, x: 100, y: 80)) > 0.2,
            "The imported-document annotation did not visibly change the composite"
        )
        try expectSamePixels(composite(second), original, "The untouched second document")
        rectangle(second, color: EditorColor(red: 0.1, green: 0.9, blue: 0.7, alpha: 1))
        let secondAnnotations = second.annotations
        let secondComposite = try composite(second)
        try expect(firstAnnotations != secondAnnotations, "The two documents shared an annotation identity or style")
        first.undo()
        try expect(first.annotations.isEmpty && first.canRedo, "The first document did not undo its own annotation")
        try expect(second.annotations == secondAnnotations && second.canUndo && second.canRedo == false, "Undo crossed document history")
        try expectSamePixels(composite(second), secondComposite, "Another document's undo changed pixels")
        first.redo()
        try expect(first.annotations == firstAnnotations, "Redo did not restore the first document's annotation")
        try expectSamePixels(composite(first), firstComposite, "Redo changed imported-image pixels")

        first.beginCrop()
        first.updateCropRect(CGRect(x: 32, y: 24, width: 220, height: 144))
        try expect(first.applyCrop(), "The imported image could not be cropped")
        try expect(first.pixelSize == CGSize(width: 220, height: 144), "Crop did not use native imported pixels")
        guard let croppedImage = first.renderCompositeImage() else {
            throw Failure.check("Could not render the edited imported image for export")
        }
        let exportURL = directory.appendingPathComponent("edited.png")
        try ScreenshotExportFormat.png.write(croppedImage, to: exportURL, jpegQuality: 0.9)
        let exported = try bitmap(EditorImageImport.fromFile(exportURL))
        try expectSamePixels(exported, try bitmap(croppedImage), "Export of the cropped imported document")
        try expect(
            distance(color(exported, x: 68, y: 56), color(firstComposite, x: 100, y: 80)) < 0.02,
            "Crop/export lost or moved the edited annotation"
        )
        try expectSamePixels(composite(second), secondComposite, "Crop/export changed the other document")
        first.undo()
        try expect(first.pixelSize == CGSize(width: 320, height: 224) && first.annotations == firstAnnotations, "Undo did not restore pre-crop image and annotations")
        second.undo()
        try expect(second.annotations.isEmpty && second.canRedo && first.annotations == firstAnnotations, "The second document's undo changed the first")
        first.undo()
        second.redo()
        try expect(first.annotations.isEmpty && first.canRedo && second.annotations == secondAnnotations, "Redo branches were shared between documents")

        try expect(
            firstImage.size == firstPointSize && secondImage.size == secondPointSize,
            "Editing/cropping/export changed an original image's logical point size"
        )
        try expectSamePixels(bitmap(firstImage), original, "Editing/cropping/export mutated the original file NSImage")
        try expectSamePixels(bitmap(secondImage), original, "Editing/cropping/export mutated the original clipboard NSImage")
        try expect(try FileSnapshot(url) == fileBefore, "Editing/cropping/export changed the original file")
        try expect(PasteboardSnapshot(pasteboard) == clipboardBefore, "Editing/cropping/export changed the source clipboard")
    }
}

@main
private struct ImageImportTests {
    @MainActor
    static func main() {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "file-png": try filePNG()
            case "clipboard-png": try clipboardPNG()
            case "jpeg-orientation": try jpegOrientation()
            case "clipboard-retina-tiff": try clipboardRetinaTIFF()
            case "import-errors": try importErrors()
            case "document-isolation": try documentIsolation()
            default: throw Failure.check("Unknown image import test scenario")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
