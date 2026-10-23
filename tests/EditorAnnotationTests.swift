import AppKit
import ImageIO

private enum Failure: Error {
    case check(String)
}

@MainActor
private func expect(_ condition: Bool, _ message: String) throws {
    if condition == false { throw Failure.check(message) }
}

@MainActor
private func makeImage() -> NSImage {
    let context = CGContext(
        data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for y in stride(from: 0, to: 400, by: 16) {
        for x in stride(from: 0, to: 640, by: 16) {
            let dark = (x / 16 + y / 16) % 2 == 0
            context.setFillColor(NSColor(
                red: dark ? 0.12 : 0.8, green: dark ? 0.23 : 0.65,
                blue: dark ? 0.34 : 0.5, alpha: 1
            ).cgColor)
            context.fill(CGRect(x: x, y: y, width: 16, height: 16))
        }
    }
    context.clear(CGRect(x: 480, y: 0, width: 160, height: 80))
    return NSImage(cgImage: context.makeImage()!, size: CGSize(width: 320, height: 200))
}

@MainActor
private func pixels(_ document: EditorDocument) throws -> NSBitmapImageRep {
    guard let image = document.renderCompositeImage(),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw Failure.check("Could not render the document")
    }
    return NSBitmapImageRep(cgImage: cgImage)
}

@MainActor
private func color(_ bitmap: NSBitmapImageRep, _ point: CGPoint) -> NSColor {
    let raw = bitmap.colorAt(x: Int(point.x), y: Int(point.y))!
    // colorAt uses the legacy color-space name; preserve the bitmap's actual ICC profile.
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
private func same(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, at point: CGPoint, _ message: String) throws {
    try expect(distance(color(a, point), color(b, point)) < 0.015, "\(message) at \(point)")
}

@MainActor
private func rectangle(_ document: EditorDocument, color: EditorColor = .red) {
    _ = document.handleEscape()
    document.activateTool(.rectangle)
    document.setShapeStyle(.filled)
    document.applySelectedColor(color)
    document.beginInteraction(at: CGPoint(x: 80, y: 80))
    document.endInteraction(at: CGPoint(x: 420, y: 280))
}

@MainActor
private func erase(_ document: EditorDocument, from start: CGPoint, to end: CGPoint, width: Double = 32) {
    document.activateTool(.eraser)
    document.eraserWidth = width
    document.beginInteraction(at: start)
    document.updateInteraction(at: end)
    document.endInteraction(at: end)
}

@MainActor
private func background() throws {
    let document = EditorDocument(baseImage: makeImage())
    let original = try pixels(document)
    erase(document, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 620, y: 380), width: 128)
    let result = try pixels(document)
    try expect(result.pixelsWide == 640 && result.pixelsHigh == 400, "Export changed source resolution")
    for y in stride(from: 0, to: 400, by: 11) {
        for x in stride(from: 0, to: 640, by: 11) {
            try same(result, original, at: CGPoint(x: x, y: y), "Eraser changed source color or alpha")
        }
    }
}

@MainActor
private func partial() throws {
    let document = EditorDocument(baseImage: makeImage())
    let original = try pixels(document)
    rectangle(document, color: EditorColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 0.65))
    let before = try pixels(document)
    erase(document, from: CGPoint(x: 100, y: 160), to: CGPoint(x: 380, y: 160))
    let after = try pixels(document)
    for x in [100, 160, 240, 320, 380] {
        try same(after, original, at: CGPoint(x: x, y: 160), "Sparse pointer events left an unerased gap")
    }
    try same(after, before, at: CGPoint(x: 240, y: 138), "Eraser exceeded its brush width")
    try same(after, before, at: CGPoint(x: 240, y: 210), "Eraser deleted the whole shape")
    try expect(distance(color(after, CGPoint(x: 240, y: 210)), color(original, CGPoint(x: 240, y: 210))) > 0.1, "Shape fixture was not visible")
}

@MainActor
private func outsidePath() throws {
    let document = EditorDocument(baseImage: makeImage())
    let original = try pixels(document)
    document.activateTool(.rectangle)
    document.setShapeStyle(.filled)
    document.beginInteraction(at: .zero)
    document.endInteraction(at: CGPoint(x: 640, y: 400))
    let before = try pixels(document)
    document.activateTool(.eraser)
    document.eraserWidth = 20
    document.beginInteraction(at: CGPoint(x: 50, y: 100))
    document.updateInteraction(at: CGPoint(x: -100, y: 100))
    document.updateInteraction(at: CGPoint(x: -100, y: 200))
    document.endInteraction(at: CGPoint(x: 50, y: 200))
    let after = try pixels(document)
    try same(after, original, at: CGPoint(x: 4, y: 100), "Crossing the image edge did not erase")
    try same(after, before, at: CGPoint(x: 4, y: 150), "Outside motion drew an artificial erase stroke along the image edge")
}

@MainActor
private func ordering() throws {
    let document = EditorDocument(baseImage: makeImage())
    let point = CGPoint(x: 240, y: 160)
    let original = try pixels(document)
    rectangle(document)
    rectangle(document, color: EditorColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 0.5))
    let before = try pixels(document)
    erase(document, from: CGPoint(x: 100, y: 160), to: CGPoint(x: 380, y: 160))
    let erased = try pixels(document)
    try same(erased, original, at: point, "Erase removed only the top annotation")
    rectangle(document, color: .green)
    let repainted = try pixels(document)
    try expect(distance(color(repainted, point), color(erased, point)) > 0.1, "Earlier eraser also erased later drawing")
    document.undo()
    try same(try pixels(document), erased, at: point, "Undo of later drawing changed the erasure")
    document.undo()
    try same(try pixels(document), before, at: point, "Undo did not restore both erased annotations")
}

@MainActor
private func cancellation() throws {
    let document = EditorDocument(baseImage: makeImage())
    let center = CGPoint(x: 240, y: 160)
    let original = try pixels(document)
    rectangle(document)
    let before = try pixels(document)
    document.activateTool(.eraser)
    document.eraserWidth = 32
    document.beginInteraction(at: center)
    try same(try pixels(document), original, at: center, "Live eraser dot was missing from export")
    document.undo()
    try same(try pixels(document), before, at: center, "Undo of active erasing removed the previous annotation")
    document.beginInteraction(at: center)
    document.updateInteraction(at: CGPoint(x: 320, y: 160))
    try expect(document.handleEscape(), "Escape did not cancel the active eraser")
    try same(try pixels(document), before, at: center, "Escape left an erase mask behind")
    document.beginInteraction(at: center)
    document.updateInteraction(at: CGPoint(x: 320, y: 160))
    document.activateTool(.pen)
    try same(try pixels(document), before, at: center, "Switching tools left an erase mask behind")
    erase(document, from: center, to: center)
    let dotted = try pixels(document)
    try same(dotted, original, at: center, "Click did not erase a circular brush footprint")
    try same(dotted, before, at: CGPoint(x: 258, y: 160), "Click brush erased beyond its radius")
    document.undo()
    try same(try pixels(document), before, at: center, "Undo did not restore a click erasure")
}

@MainActor
private func annotationTypes() throws {
    for kind in ["pen", "arrow", "rectangle-outline", "rectangle-filled", "ellipse-outline", "ellipse-filled", "blur", "text"] {
        let document = EditorDocument(baseImage: makeImage())
        let original = try pixels(document)
        document.setLineWidthControlValue(16)
        if kind == "text" {
            document.activateTool(.text)
            document.setTextSizeControlValue(48)
            document.beginInteraction(at: CGPoint(x: 100, y: 120))
            document.setPendingText("MMMMMMMM")
            document.commitPendingTextInsertion()
        } else {
            let tool: EditorTool
            if kind.hasPrefix("rectangle") { tool = .rectangle }
            else if kind.hasPrefix("ellipse") { tool = .ellipse }
            else if kind == "arrow" { tool = .arrow }
            else if kind == "blur" { tool = .blur }
            else { tool = .pen }
            document.activateTool(tool)
            document.setShapeStyle(kind.hasSuffix("filled") ? .filled : .outline)
            document.beginInteraction(at: CGPoint(x: 100, y: 100))
            document.updateInteraction(at: CGPoint(x: 400, y: 260))
            document.endInteraction(at: CGPoint(x: 400, y: 260))
        }
        let before = try pixels(document)
        var marked: [CGPoint] = []
        for y in stride(from: 82, to: 282, by: 4) {
            for x in stride(from: 82, to: 422, by: 4) {
                let p = CGPoint(x: x, y: y)
                if distance(color(before, p), color(original, p)) > 0.1 { marked.append(p) }
            }
        }
        guard let target = marked.min(by: { hypot($0.x - 250, $0.y - 180) < hypot($1.x - 250, $1.y - 180) }),
              let untouched = marked.first(where: { hypot($0.x - target.x, $0.y - target.y) > 40 }) else {
            throw Failure.check("No visible marks to exercise for \(kind)")
        }
        erase(document, from: target, to: target, width: 24)
        let after = try pixels(document)
        try same(after, original, at: target, "Could not erase \(kind)")
        try same(after, before, at: untouched, "Partial erasing deleted the entire \(kind)")
        document.undo()
        try same(try pixels(document), before, at: target, "Undo could not restore \(kind)")
    }
}

@MainActor
private func makeTextImage(pixelRatio: CGFloat = 2) -> NSImage {
    let context = CGContext(
        data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
    return NSImage(
        cgImage: context.makeImage()!,
        size: CGSize(width: 640 / pixelRatio, height: 400 / pixelRatio)
    )
}

@MainActor
private func textAnnotation(_ document: EditorDocument, id: UUID? = nil) throws -> EditorTextAnnotation {
    for case let .text(annotation) in document.annotations {
        if id == nil || annotation.id == id { return annotation }
    }
    throw Failure.check("Expected a committed text object")
}

@MainActor
private func textOverlay(_ document: EditorDocument) throws -> EditorSelectionOverlay {
    guard let overlay = document.selectionOverlay, overlay.kind == .text else {
        throw Failure.check("Expected the text object's selection bounds")
    }
    return overlay
}

@MainActor
@discardableResult
private func addText(
    _ document: EditorDocument, _ text: String, at origin: CGPoint,
    size: Double = 30, font: EditorTextFont = .system
) throws -> EditorTextAnnotation {
    document.activateTool(.text)
    document.beginInteraction(at: origin)
    try expect(document.pendingTextInsertion?.annotationID == nil, "Fixture reopened an existing object")
    document.setTextSizeControlValue(size)
    document.setTextFont(font)
    document.applySelectedColor(EditorColor(red: 0, green: 0, blue: 0, alpha: 1))
    document.setPendingText(text)
    try expect(document.commitPendingTextInsertion(), "Nonblank text was not committed")
    guard let id = document.selectedAnnotation?.id else {
        throw Failure.check("Committed text was not selected")
    }
    return try textAnnotation(document, id: id)
}

@MainActor
private func setTextWidth(_ document: EditorDocument, to width: CGFloat) throws {
    document.activateTool(.move)
    let overlay = try textOverlay(document)
    let grab = CGPoint(x: overlay.handleRect.midX, y: overlay.handleRect.midY)
    let destination = CGPoint(x: grab.x + width - overlay.rect.width, y: grab.y)
    document.beginInteraction(at: grab)
    document.updateInteraction(at: destination)
    document.endInteraction(at: destination)
    try expect(abs(try textOverlay(document).rect.width - width) < 0.01, "Width handle did not set the source-pixel width")
}

@MainActor
private func changedPixels(_ bitmap: NSBitmapImageRep, from background: NSBitmapImageRep) throws -> Set<Int> {
    try expect(
        bitmap.pixelsWide == background.pixelsWide && bitmap.pixelsHigh == background.pixelsHigh,
        "Pixel comparison changed image dimensions"
    )
    var changed: Set<Int> = []
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            let point = CGPoint(x: x, y: y)
            if distance(color(bitmap, point), color(background, point)) > 0.04 {
                changed.insert(y * bitmap.pixelsWide + x)
            }
        }
    }
    return changed
}

@MainActor
private func expectInkInside(_ ink: Set<Int>, width: Int, rect: CGRect, _ message: String) throws {
    try expect(ink.count > 80, "\(message): no meaningful text ink")
    for index in ink {
        let x = index % width
        let y = index / width
        try expect(
            CGFloat(x) >= floor(rect.minX) && CGFloat(x + 1) <= ceil(rect.maxX)
                && CGFloat(y) >= floor(rect.minY) && CGFloat(y + 1) <= ceil(rect.maxY),
            "\(message): ink at (\(x), \(y)) escaped \(rect)"
        )
    }
}

@MainActor
private func expectMatchingInk(_ actual: Set<Int>, _ expected: Set<Int>, width: Int, height: Int) throws {
    try expect(expected.count > 80 && actual.count > 80, "Text comparison had no meaningful glyphs")
    try expect(
        abs(Double(actual.count) - Double(expected.count)) / Double(expected.count) < 0.04,
        "Export and layout have different amounts of glyph ink"
    )
    // A one-pixel antialiasing fringe may vary between bitmap contexts, not a whole glyph or baseline.
    func hasNeighbor(_ index: Int, in ink: Set<Int>) -> Bool {
        let x = index % width
        let y = index / width
        for row in max(y - 1, 0)...min(y + 1, height - 1) {
            for column in max(x - 1, 0)...min(x + 1, width - 1) {
                if ink.contains(row * width + column) { return true }
            }
        }
        return false
    }
    try expect(actual.allSatisfy { hasNeighbor($0, in: expected) }, "Export moved or distorted layout glyphs")
    try expect(expected.allSatisfy { hasNeighbor($0, in: actual) }, "Export omitted layout glyphs")
}

@MainActor
private func renderTextLayout(_ layout: EditorTextLayout, at origin: CGPoint) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw Failure.check("Could not create the independent layout bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.setFillColor(NSColor.white.cgColor)
    context.cgContext.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
    context.cgContext.translateBy(x: 0, y: 400)
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    layout.draw(at: origin)
    return bitmap
}

@MainActor
private func inkLineRects(_ layout: EditorTextLayout) -> [CGRect] {
    layout.layoutManager.ensureLayout(for: layout.textContainer)
    var result: [CGRect] = []
    layout.layoutManager.enumerateLineFragments(
        forGlyphRange: NSRange(location: 0, length: layout.layoutManager.numberOfGlyphs)
    ) { rect, _, _, glyphRange, _ in
        let range = layout.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let line = (layout.textStorage.string as NSString).substring(with: range)
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            result.append(rect)
        }
    }
    return result
}

@MainActor
private func textEditingLifecycle() throws {
    let document = EditorDocument(baseImage: makeTextImage())
    let background = try pixels(document)
    let origin = CGPoint(x: 64, y: 54)
    let originalText = "  Привет  \n\nМир \t\n"
    let original = try addText(document, originalText, at: origin, size: 28)
    try expect(original.text == originalText, "Commit trimmed meaningful spaces, blank lines, or the final newline")

    // The eraser must remain above this object even after its contents are replaced.
    erase(document, from: CGPoint(x: 0, y: 72), to: CGPoint(x: 640, y: 72), width: 24)
    let later = try addText(document, "Позже", at: CGPoint(x: 80, y: 300), size: 24)
    let originalOrder = document.annotations.map(\.id)
    let beforeEditing = try pixels(document)
    let hit = CGPoint(x: origin.x + 20, y: origin.y + 50)
    document.beginInteraction(at: hit)
    try expect(document.pendingTextInsertion?.annotationID == original.id, "Text-tool click created a duplicate instead of reopening text")
    try expect(document.pendingTextInsertion?.text == originalText, "Reopening lost the exact text contents")
    try expect(document.selectionOverlay == nil, "Selection chrome remained over native text input")
    try expect(
        document.committedAndActiveAnnotations.map(\.id) == originalOrder.filter { $0 != original.id },
        "The text being edited was still drawn underneath the input, or other objects disappeared"
    )
    document.setPendingText("Отменённая замена")
    document.setTextSizeControlValue(44)
    document.setTextFont(.serif)
    document.applySelectedColor(.blue)
    document.undo()
    let restored = try textAnnotation(document, id: original.id)
    try expect(document.pendingTextInsertion == nil, "Undo left text input open")
    try expect(document.annotations.map(\.id) == originalOrder, "Undoing text editing removed or reordered an object")
    try expect(restored == original, "Undoing text editing leaked pending content or typography")
    try expect(try changedPixels(pixels(document), from: beforeEditing).isEmpty, "Undoing text editing changed exported pixels")
    try expect(document.canRedo, "Undo discarded the changed native text session instead of making it redoable")
    document.redo()
    let redone = try textAnnotation(document, id: original.id)
    try expect(
        redone.text == "Отменённая замена" && redone.color == .blue
            && redone.font == .serif && redone.fontSize == 44,
        "Redo did not recover the entire pending text session"
    )
    try expect(document.annotations.map(\.id) == originalOrder, "Redoing text editing changed object order")
    document.undo()

    document.activateTool(.move)
    document.beginInteraction(at: hit)
    document.endInteraction(at: hit)
    try expect(document.beginEditingSelectedText(), "Selected text could not be reopened")
    try expect(document.deleteSelectedAnnotation() == false, "Object deletion consumed a native text-editing session")
    let replacement = "  Изменено\n\nНовый мир \t\n"
    document.setPendingText(replacement)
    document.commitPendingTextInsertion()
    try expect(document.annotations.map(\.id) == originalOrder, "Replacing text duplicated it, changed its UUID, or moved it above the eraser")
    try expect(try textAnnotation(document, id: original.id).text == replacement, "Replacement text was not saved verbatim")
    let replaced = try pixels(document)
    for y in 69...75 {
        for x in 0..<640 {
            try same(replaced, background, at: CGPoint(x: x, y: y), "Editing moved text above its existing eraser")
        }
    }
    try expect(try changedPixels(replaced, from: beforeEditing).isEmpty == false, "Replacing text did not change the exported glyphs")

    try expect(document.beginEditingText(at: hit), "Hit-testing could not reopen replaced text")
    document.setPendingText(" \n\t\n ")
    document.commitPendingTextInsertion()
    try expect(
        document.annotations.map(\.id) == originalOrder.filter { $0 != original.id },
        "Clearing text did not remove exactly that object"
    )
    let expected = EditorDocument(baseImage: makeTextImage())
    try addText(expected, "Позже", at: later.origin, size: 24)
    try expect(try changedPixels(pixels(document), from: pixels(expected)).isEmpty, "Clearing text left old ink or damaged a later object")

    let afterClearing = document.annotations.map(\.id)
    document.activateTool(.text)
    document.beginInteraction(at: CGPoint(x: 520, y: 20))
    document.setPendingText(" \t\n\n ")
    try expect(document.commitPendingTextInsertion() == false, "Blank new input created an object")
    try expect(document.annotations.map(\.id) == afterClearing, "Discarding blank input changed other objects")
}

@MainActor
private func textLayoutAndExport() throws {
    let origin = CGPoint(x: 83, y: 71)
    let content = "Привет, мир! Ещё слова\n\nВторая строка\n"
    for font in EditorTextFont.allCases {
        let document = EditorDocument(baseImage: makeTextImage())
        let background = try pixels(document)
        let inserted = try addText(document, content, at: origin, size: 30, font: font)
        try setTextWidth(document, to: 218)
        let annotation = try textAnnotation(document, id: inserted.id)
        let layout = EditorTextLayout(annotation: annotation)
        let overlay = try textOverlay(document)
        try expect(annotation.origin == origin, "Text insertion or wrapping moved the requested source origin")
        try expect(
            overlay.rect.origin == origin && abs(overlay.rect.width - 218) < 0.01
                && abs(overlay.rect.height - layout.size.height) < 0.01,
            "Selection does not enclose the actual wrapped layout"
        )
        let withoutFinalNewline = EditorTextLayout(
            text: String(content.dropLast()), width: annotation.width, font: font,
            fontSize: annotation.fontSize, color: annotation.color
        )
        try expect(
            layout.size.height - withoutFinalNewline.size.height > annotation.fontSize * 0.75,
            "The final newline did not reserve a full editable line"
        )
        let lines = inkLineRects(layout)
        try expect(lines.count >= 3, "Cyrillic text did not wrap into the expected multiple lines")
        try expect(
            zip(lines, lines.dropFirst()).contains { pair in
                pair.1.minY - pair.0.maxY > annotation.fontSize * 0.75
            },
            "An explicit blank line collapsed out of the text layout"
        )
        let exported = try changedPixels(pixels(document), from: background)
        try expectInkInside(exported, width: 640, rect: overlay.rect, "\(font) export escaped top-left text bounds")
        // This is deliberately not origin zero: the old baseline-minus-font-size export drew above y = 71.
        try expect(exported.allSatisfy { $0 % 640 >= 83 && $0 / 640 >= 71 }, "Export drew above or left of the requested origin")
        for line in lines {
            let top = Int(floor(origin.y + line.minY))
            let bottom = Int(ceil(origin.y + line.maxY))
            let lineInk = exported.filter { $0 / 640 >= top && $0 / 640 < bottom }
            try expect(lineInk.count > 20, "Export omitted a wrapped Cyrillic line")
        }
        let independentlyDrawn = try renderTextLayout(layout, at: origin)
        let expected = try changedPixels(independentlyDrawn, from: background)
        try expectInkInside(expected, width: 640, rect: overlay.rect, "Layout draw escaped its declared bounds")
        try expectMatchingInk(exported, expected, width: 640, height: 400)
    }
}

@MainActor
private func textMoveAndWidthResize() throws {
    let document = EditorDocument(baseImage: makeTextImage())
    let background = try pixels(document)
    let inserted = try addText(
        document, "Привет мир! Удобный текст\nЕщё строка",
        at: CGPoint(x: 83, y: 71), size: 30
    )
    try setTextWidth(document, to: 220)
    let initial = try textAnnotation(document, id: inserted.id)
    let initialBounds = try textOverlay(document).rect
    let initialInk = try changedPixels(pixels(document), from: background)
    let grab = CGPoint(x: initial.origin.x + 35, y: initial.origin.y + 20)
    document.beginInteraction(at: grab)
    document.updateInteraction(at: grab)
    document.endInteraction(at: grab)
    try expect(try textAnnotation(document, id: inserted.id).origin == initial.origin, "A zero-motion grab jumped the text origin")
    try expect(try changedPixels(pixels(document), from: background) == initialInk, "A zero-motion grab changed text pixels")

    let delta = CGSize(width: 47, height: 33)
    let destination = CGPoint(x: grab.x + delta.width, y: grab.y + delta.height)
    document.beginInteraction(at: grab)
    document.updateInteraction(at: destination)
    document.endInteraction(at: destination)
    let moved = try textAnnotation(document, id: inserted.id)
    try expect(
        moved.origin == CGPoint(x: initial.origin.x + delta.width, y: initial.origin.y + delta.height),
        "Moving text lost the pointer's grab offset"
    )
    try expect(moved.width == initial.width && moved.fontSize == initial.fontSize, "Moving text changed typography")
    let movedInk = try changedPixels(pixels(document), from: background)
    let translatedInk = Set(initialInk.map { $0 + Int(delta.height) * 640 + Int(delta.width) })
    try expectMatchingInk(movedInk, translatedInk, width: 640, height: 400)

    let beforeResize = try textOverlay(document)
    try expect(
        abs(beforeResize.handleRect.midX - beforeResize.rect.maxX) < 0.01
            && abs(beforeResize.handleRect.midY - beforeResize.rect.midY) < 0.01,
        "Text width handle was not at the right-middle edge"
    )
    let handleGrab = CGPoint(x: beforeResize.handleRect.midX - 4, y: beforeResize.handleRect.midY + 3)
    document.beginInteraction(at: handleGrab)
    document.updateInteraction(at: handleGrab)
    document.endInteraction(at: handleGrab)
    let noMotion = try textAnnotation(document, id: inserted.id)
    try expect(
        noMotion.origin == moved.origin && noMotion.width == moved.width && noMotion.fontSize == moved.fontSize,
        "An off-center, zero-motion handle grab changed text geometry"
    )
    try expect(try changedPixels(pixels(document), from: background) == movedInk, "A zero-motion resize changed exported ink")

    let narrower = CGPoint(x: handleGrab.x - 78, y: handleGrab.y + 15)
    document.beginInteraction(at: handleGrab)
    document.updateInteraction(at: narrower)
    document.endInteraction(at: narrower)
    let resized = try textAnnotation(document, id: inserted.id)
    let resizedBounds = try textOverlay(document).rect
    try expect(
        resized.origin == moved.origin && abs(resized.width - (moved.width - 78)) < 0.01,
        "Width resizing lost the handle's grab offset or moved the text"
    )
    try expect(resized.fontSize == moved.fontSize && resized.font == moved.font, "Width resizing scaled the font instead of wrapping")
    try expect(
        resizedBounds.height > beforeResize.rect.height
            && inkLineRects(EditorTextLayout(annotation: resized)).count > inkLineRects(EditorTextLayout(annotation: moved)).count,
        "Narrowing the text box did not create additional wrapped lines"
    )
    let resizedInk = try changedPixels(pixels(document), from: background)
    try expect(resizedInk != movedInk, "Width resizing did not visibly reflow text")
    try expectInkInside(resizedInk, width: 640, rect: resizedBounds, "Resized export escaped text bounds")
    try expect(initialBounds.width > resizedBounds.width, "Fixture did not narrow the text box")
}

@MainActor
private func textRetinaAndImageEdges() throws {
    let standard = EditorDocument(baseImage: makeTextImage(pixelRatio: 1))
    let retina = EditorDocument(baseImage: makeTextImage(pixelRatio: 2))
    let standardRatio = standard.pixelSize.width / standard.baseImage.size.width
    let retinaRatio = retina.pixelSize.width / retina.baseImage.size.width
    try expect(
        abs(CGFloat(standard.textFontSize) / standardRatio - CGFloat(retina.textFontSize) / retinaRatio) < 0.01,
        "Default text is smaller in native points on a Retina image"
    )
    for document in [standard, retina] {
        let background = try pixels(document)
        document.activateTool(.text)
        document.beginInteraction(at: CGPoint(x: 639, y: 399))
        guard let emptyBounds = document.pendingTextBounds, let empty = document.pendingTextInsertion else {
            throw Failure.check("Near-edge insertion did not create an editable empty line")
        }
        let source = CGRect(origin: .zero, size: document.pixelSize)
        try expect(
            emptyBounds.width > 0 && emptyBounds.height >= empty.fontSize
                && source.contains(emptyBounds),
            "The empty input line extended outside the source image"
        )
        document.applySelectedColor(EditorColor(red: 0, green: 0, blue: 0, alpha: 1))
        document.setPendingText("Край\nтекста")
        guard let pendingBounds = document.pendingTextBounds else {
            throw Failure.check("Typing removed the native text input bounds")
        }
        try expect(
            pendingBounds.origin == emptyBounds.origin && document.pendingTextInsertion?.text == "Край\nтекста",
            "Typing near the edge jumped the origin or truncated the stored text"
        )
        document.commitPendingTextInsertion()
        let edgeAnnotation = try textAnnotation(document)
        let visibleBounds = try textOverlay(document).rect.intersection(source)
        try expect(
            edgeAnnotation.origin == empty.origin && edgeAnnotation.fontSize == empty.fontSize,
            "Committing near-edge text moved it or shrank its font"
        )
        let clippedInk = try changedPixels(pixels(document), from: background)
        try expectInkInside(clippedInk, width: 640, rect: visibleBounds, "Near-edge text lost its visible first line")

        // Long input may intentionally overflow the source. Move it inward and widen it to recover every line.
        document.activateTool(.move)
        let grab = CGPoint(x: edgeAnnotation.origin.x + 5, y: edgeAnnotation.origin.y + empty.fontSize * 0.3)
        let destination = CGPoint(x: 69, y: 32 + empty.fontSize * 0.3)
        document.beginInteraction(at: grab)
        document.updateInteraction(at: destination)
        document.endInteraction(at: destination)
        try setTextWidth(document, to: 300)
        let widened = try textAnnotation(document, id: edgeAnnotation.id)
        let secondGrab = CGPoint(x: widened.origin.x + 5, y: widened.origin.y + empty.fontSize * 0.3)
        document.beginInteraction(at: secondGrab)
        document.updateInteraction(at: destination)
        document.endInteraction(at: destination)
        let annotation = try textAnnotation(document, id: edgeAnnotation.id)
        let bounds = try textOverlay(document).rect
        try expect(
            annotation.origin == CGPoint(x: 64, y: 32) && source.contains(bounds)
                && annotation.text == "Край\nтекста" && annotation.fontSize == empty.fontSize,
            "Moving and widening near-edge text could not recover its complete contents"
        )
        let exported = try changedPixels(pixels(document), from: background)
        try expectInkInside(exported, width: 640, rect: bounds, "Near-edge text was clipped or misplaced")
        try expectMatchingInk(
            exported, changedPixels(renderTextLayout(EditorTextLayout(annotation: annotation), at: annotation.origin), from: background),
            width: 640, height: 400
        )
    }
}

private let visualKinds = [
    "stroke", "arrow", "rectangle-outline", "rectangle-filled",
    "ellipse-outline", "ellipse-filled", "blur", "text",
]

@MainActor
private func expectSamePixels(_ actual: NSBitmapImageRep, _ expected: NSBitmapImageRep, _ message: String) throws {
    try expect(
        actual.pixelsWide == expected.pixelsWide && actual.pixelsHigh == expected.pixelsHigh
            && actual.bitsPerPixel == expected.bitsPerPixel && actual.bitmapFormat == expected.bitmapFormat,
        "\(message): bitmap format changed"
    )
    guard let actualBytes = actual.bitmapData, let expectedBytes = expected.bitmapData else {
        throw Failure.check("\(message): missing bitmap bytes")
    }
    let rowBytes = actual.pixelsWide * actual.bitsPerPixel / 8
    for row in 0..<actual.pixelsHigh {
        let left = UnsafeBufferPointer(start: actualBytes.advanced(by: row * actual.bytesPerRow), count: rowBytes)
        let right = UnsafeBufferPointer(start: expectedBytes.advanced(by: row * expected.bytesPerRow), count: rowBytes)
        try expect(left.elementsEqual(right), "\(message): pixels differ on row \(row)")
    }
}

@MainActor
private func annotation(_ document: EditorDocument, id: UUID) throws -> EditorAnnotation {
    guard let result = document.annotations.first(where: { $0.id == id }) else {
        throw Failure.check("Object \(id) disappeared")
    }
    return result
}

@MainActor
private func selectedOverlay(_ document: EditorDocument) throws -> EditorSelectionOverlay {
    guard let result = document.selectionOverlay else { throw Failure.check("Missing object selection overlay") }
    return result
}

@MainActor
private func drag(
    _ document: EditorDocument, from start: CGPoint, to end: CGPoint, constrained: Bool = false
) {
    document.beginInteraction(at: start)
    for step in 1...12 {
        let progress = CGFloat(step) / 12
        document.updateInteraction(
            at: CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress),
            constrainProportions: constrained
        )
    }
    document.endInteraction(at: end, constrainProportions: constrained)
}

@MainActor
private func selectObject(_ document: EditorDocument, at point: CGPoint) {
    document.activateTool(.move)
    document.beginInteraction(at: point)
    document.endInteraction(at: point)
}

@MainActor
private func objectGrab(_ kind: String) -> CGPoint {
    switch kind {
    case "stroke": return CGPoint(x: 180, y: 150)
    case "rectangle-outline", "ellipse-outline": return CGPoint(x: 200, y: 100)
    case "text": return CGPoint(x: 110, y: 110)
    default: return CGPoint(x: 200, y: 160)
    }
}

@MainActor
@discardableResult
private func createVisual(_ document: EditorDocument, kind: String) throws -> EditorAnnotation {
    _ = document.handleEscape()
    if kind == "text" {
        try addText(document, "Object\nhistory", at: CGPoint(x: 100, y: 100), size: 24)
    } else {
        let tool: EditorTool
        switch kind {
        case "stroke": tool = .pen
        case "arrow": tool = .arrow
        case "blur": tool = .blur
        default: tool = kind.hasPrefix("ellipse") ? .ellipse : .rectangle
        }
        document.activateTool(tool)
        document.setLineWidthControlValue(12)
        document.setShapeStyle(kind.hasSuffix("filled") ? .filled : .outline)
        document.applySelectedColor(.red)
        document.setBlurControlValue(12)
        document.beginInteraction(at: CGPoint(x: 100, y: 100))
        document.updateInteraction(at: CGPoint(x: 180, y: 150))
        document.endInteraction(at: CGPoint(x: 300, y: 220))
    }
    guard let result = document.annotations.last else { throw Failure.check("Could not create \(kind)") }
    return result
}

@MainActor
private func expectTranslated(_ actual: EditorAnnotation, from original: EditorAnnotation, by delta: CGSize) throws {
    func shifted(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + delta.width, y: point.y + delta.height)
    }
    try expect(actual.id == original.id, "Moving an object changed its UUID")
    switch (original, actual) {
    case let (.stroke(before), .stroke(after)):
        var expected = before
        expected.points = before.points.map(shifted)
        try expect(after == expected, "Moving a stroke distorted points, width, or color")
    case let (.eraser(before), .eraser(after)):
        var expected = before
        expected.points = before.points.map(shifted)
        try expect(after == expected, "Translating an eraser distorted its path or brush width")
    case let (.arrow(before), .arrow(after)):
        var expected = before
        expected.start = shifted(before.start)
        expected.end = shifted(before.end)
        try expect(after == expected, "Moving an arrow distorted endpoints or style")
    case let (.shape(before), .shape(after)):
        var expected = before
        expected.rect.origin = shifted(before.rect.origin)
        try expect(after == expected, "Moving a shape changed dimensions or style")
    case let (.blur(before), .blur(after)):
        var expected = before
        expected.rect.origin = shifted(before.rect.origin)
        try expect(after == expected, "Moving a blur changed dimensions or strength")
    case let (.text(before), .text(after)):
        var expected = before
        expected.origin = shifted(before.origin)
        try expect(after == expected, "Moving text changed contents or typography")
    default:
        throw Failure.check("Moving changed the annotation type")
    }
}

@MainActor
private func creationHistory() throws {
    for kind in visualKinds + ["eraser"] {
        let document = EditorDocument(baseImage: makeImage())
        let background = try pixels(document)
        try expect(
            document.canUndo == false && document.canRedo == false
                && document.undoActionName.isEmpty && document.redoActionName.isEmpty,
            "A new editor started with history"
        )
        if kind == "eraser" {
            rectangle(document)
        } else {
            document.setLineWidthControlValue(9)
            document.setShapeStyle(.filled)
            document.applySelectedColor(.green)
            document.setBlurControlValue(18)
            document.setTextFont(.serif)
            document.setTextSizeControlValue(22)
            try expect(document.canUndo == false, "Changing future drawing settings created history")
        }
        let before = document.annotations
        let beforePixels = try pixels(document)
        if kind == "eraser" {
            erase(document, from: CGPoint(x: 120, y: 160), to: CGPoint(x: 360, y: 160))
        } else {
            try createVisual(document, kind: kind)
        }
        let created = document.annotations
        let createdPixels = try pixels(document)
        try expect(document.canUndo && document.undoActionName.isEmpty == false, "Creation did not name an undo action for \(kind)")
        try expect(try changedPixels(createdPixels, from: beforePixels).isEmpty == false, "Creating \(kind) did not affect export")
        if kind == "eraser" {
            try same(createdPixels, background, at: CGPoint(x: 240, y: 160), "An eraser action did not expose source pixels")
        }
        document.undo()
        try expect(document.annotations == before, "Undo did not remove exactly the created \(kind)")
        try expect(document.canRedo && document.redoActionName.isEmpty == false, "Creation undo was not redoable for \(kind)")
        try expectSamePixels(pixels(document), beforePixels, "Undo changed the previous \(kind) composite")
        if before.isEmpty { try expect(document.canUndo == false, "One \(kind) creation produced multiple history entries") }
        document.redo()
        try expect(document.annotations == created, "Redo changed \(kind) payloads, IDs, or ordering")
        try expect(document.canRedo == false && document.redoActionName.isEmpty, "Redo left a stale next action")
        try expectSamePixels(pixels(document), createdPixels, "Redo did not reproduce \(kind) export")
        if kind == "eraser" {
            selectObject(document, at: CGPoint(x: 240, y: 160))
            try expect(document.selectedAnnotation == nil, "An eraser action became a selectable object")
        }
    }
}

@MainActor
private func objectMoveResizeHistory() throws {
    for kind in visualKinds {
        let document = EditorDocument(baseImage: makeImage())
        let sourcePixels = try pixels(document)
        let original = try createVisual(document, kind: kind)
        erase(document, from: CGPoint(x: 80, y: 190), to: CGPoint(x: 460, y: 190), width: 20)
        let eraser = document.annotations.last!
        let beforePixels = try pixels(document)
        let grab = objectGrab(kind)
        selectObject(document, at: grab)
        try expect(document.selectedAnnotation?.id == original.id, "Move tool could not select \(kind)")
        let originalSelection = document.selectedAnnotation
        let delta = CGSize(width: 23, height: 17)
        drag(document, from: grab, to: CGPoint(x: grab.x + delta.width, y: grab.y + delta.height))
        let moved = try annotation(document, id: original.id)
        try expectTranslated(moved, from: original, by: delta)
        try expect(document.annotations == [moved, eraser], "Moving \(kind) changed its index relative to a later mask")
        let movedPixels = try pixels(document)
        try expect(try changedPixels(movedPixels, from: beforePixels).isEmpty == false, "Moving \(kind) did not change export")
        if kind == "rectangle-filled" {
            try same(movedPixels, sourcePixels, at: CGPoint(x: 240, y: 190), "Moving a shape lifted it above its later eraser")
        }
        document.undo()
        try expect(document.annotations == [original, eraser] && document.selectedAnnotation == originalSelection, "One undo did not restore the whole \(kind) drag and selection")
        try expectSamePixels(pixels(document), beforePixels, "Move undo did not restore \(kind) ink")
        document.redo()
        try expect(document.annotations == [moved, eraser], "Move redo did not restore exact \(kind) geometry and index")
        try expectSamePixels(pixels(document), movedPixels, "Move redo changed \(kind) export")
        if kind == "arrow" { continue }

        let overlay = try selectedOverlay(document)
        let offCenterGrab = CGPoint(x: overlay.handleRect.midX - 3, y: overlay.handleRect.midY + 2)
        drag(document, from: offCenterGrab, to: offCenterGrab)
        try expect(document.annotations == [moved, eraser], "An off-center zero-motion \(kind) resize snapped geometry")
        let resizeDestination = CGPoint(
            x: offCenterGrab.x + (kind == "text" ? -90 : 35),
            y: offCenterGrab.y + 27
        )
        drag(document, from: offCenterGrab, to: resizeDestination)
        let resized = try annotation(document, id: original.id)
        let resizedBounds = try selectedOverlay(document).rect
        try expect(resized != moved && resized.id == moved.id, "Resizing \(kind) did not preserve and change the selected object")
        try expect(resized.lineWidth == moved.lineWidth, "Resizing \(kind) scaled its line width")
        try expect(document.annotations == [resized, eraser], "Resizing \(kind) changed its index relative to a later mask")
        if case let .text(before) = moved, case let .text(after) = resized {
            try expect(
                after.origin == before.origin && abs(after.width - (before.width - 90)) < 0.01
                    && after.fontSize == before.fontSize && after.font == before.font && after.text == before.text,
                "Text width dragging moved the origin or scaled its contents"
            )
        } else {
            try expect(
                abs(resizedBounds.minX - overlay.rect.minX) < 0.01
                    && abs(resizedBounds.minY - overlay.rect.minY) < 0.01
                    && abs(resizedBounds.width - overlay.rect.width - 35) < 0.01
                    && abs(resizedBounds.height - overlay.rect.height - 27) < 0.01,
                "Resizing \(kind) ignored the corner's pointer offset"
            )
        }
        let resizedPixels = try pixels(document)
        if kind == "rectangle-filled" {
            try same(resizedPixels, sourcePixels, at: CGPoint(x: 240, y: 190), "Resizing a shape lifted it above its later eraser")
        }
        document.undo()
        try expect(document.annotations == [moved, eraser], "One undo did not restore all \(kind) resize events")
        try expectSamePixels(pixels(document), movedPixels, "Resize undo changed \(kind) export")
        document.redo()
        try expect(document.annotations == [resized, eraser], "Resize redo changed \(kind) payload or index")
        try expectSamePixels(pixels(document), resizedPixels, "Resize redo changed \(kind) export")
        document.undo()
        document.undo()
        try expect(document.annotations == [original, eraser], "Zero-motion handle drag added a hidden history entry for \(kind)")
        document.undo()
        try expect(document.annotations == [original], "Undo eraser did not preserve the original \(kind)")
        document.undo()
        try expect(document.annotations.isEmpty && document.canUndo == false, "Drag events fragmented \(kind) history")
    }
}

@MainActor
private func arrowEndpointsAndDegenerateGeometry() throws {
    let document = EditorDocument(baseImage: makeImage())
    let original = try createVisual(document, kind: "arrow")
    selectObject(document, at: objectGrab("arrow"))
    guard case let .arrow(initial) = original else { throw Failure.check("Missing arrow fixture") }
    var overlay = try selectedOverlay(document)
    try expect(
        CGPoint(x: overlay.handleRect.midX, y: overlay.handleRect.midY) == initial.end,
        "The primary arrow handle is not the end point"
    )
    guard let startHandle = overlay.secondaryHandleRect else { throw Failure.check("Arrow has no start-point handle") }
    try expect(CGPoint(x: startHandle.midX, y: startHandle.midY) == initial.start, "Arrow start handle missed its endpoint")
    let grab = CGPoint(x: startHandle.midX + 3, y: startHandle.midY - 2)
    drag(document, from: grab, to: grab)
    try expect(document.annotations == [original], "A zero-motion arrow endpoint grab snapped the arrow")
    drag(document, from: grab, to: CGPoint(x: grab.x - 24, y: grab.y + 31))
    guard case let .arrow(startChanged) = try annotation(document, id: original.id) else {
        throw Failure.check("Arrow start editing changed its type")
    }
    try expect(
        startChanged.start == CGPoint(x: initial.start.x - 24, y: initial.start.y + 31)
            && startChanged.end == initial.end && startChanged.lineWidth == initial.lineWidth
            && startChanged.color == initial.color && startChanged.id == initial.id,
        "Dragging the start handle moved the wrong endpoint or lost its pointer offset"
    )
    let afterStart = document.annotations
    overlay = try selectedOverlay(document)
    let endGrab = CGPoint(x: overlay.handleRect.midX - 4, y: overlay.handleRect.midY + 2)
    drag(document, from: endGrab, to: CGPoint(x: endGrab.x + 42, y: endGrab.y - 19))
    guard case let .arrow(endChanged) = try annotation(document, id: original.id) else {
        throw Failure.check("Arrow end editing changed its type")
    }
    try expect(
        endChanged.start == startChanged.start
            && endChanged.end == CGPoint(x: initial.end.x + 42, y: initial.end.y - 19),
        "Dragging the end handle changed the start or lost the grab offset"
    )
    let afterBoth = document.annotations
    let bothPixels = try pixels(document)
    document.undo()
    try expect(document.annotations == afterStart, "Arrow end drag was not one history entry")
    document.undo()
    try expect(document.annotations == [original], "Arrow start drag was not one history entry")
    document.redo()
    document.redo()
    try expect(document.annotations == afterBoth, "Arrow endpoint redo did not preserve exact geometry")
    try expectSamePixels(pixels(document), bothPixels, "Redo changed arrow-head export")

    let head = EditorDocument(baseImage: makeImage())
    head.activateTool(.arrow)
    head.setLineWidthControlValue(24)
    head.beginInteraction(at: CGPoint(x: 100, y: 180))
    head.endInteraction(at: CGPoint(x: 400, y: 180))
    let headID = head.annotations[0].id
    selectObject(head, at: CGPoint(x: 600, y: 350))
    selectObject(head, at: CGPoint(x: 345, y: 154))
    try expect(head.selectedAnnotation?.id == headID, "Arrow-head ink outside shaft tolerance was not selectable")

    for tool in [EditorTool.pen, .arrow] {
        for end in [CGPoint(x: 300, y: 160), CGPoint(x: 160, y: 300)] {
            let thin = EditorDocument(baseImage: makeImage())
            thin.activateTool(tool)
            thin.setLineWidthControlValue(10)
            let start = CGPoint(x: 160, y: 160)
            drag(thin, from: start, to: end)
            let before = thin.annotations
            selectObject(thin, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
            let handle = try selectedOverlay(thin).handleRect
            let handlePoint = CGPoint(x: handle.midX, y: handle.midY)
            drag(thin, from: handlePoint, to: CGPoint(x: handlePoint.x + 31, y: handlePoint.y + 29))
            let bounds = try selectedOverlay(thin).rect
            try expect(
                bounds.minX.isFinite && bounds.minY.isFinite && bounds.width.isFinite && bounds.height.isFinite
                    && bounds.width > 0 && bounds.height > 0,
                "Resizing a horizontal or vertical \(tool) produced invalid geometry"
            )
            let after = thin.annotations
            let exported = try pixels(thin)
            thin.undo()
            try expect(thin.annotations == before, "Degenerate-path resize undo lost the original")
            thin.redo()
            try expect(thin.annotations == after, "Degenerate-path resize redo changed points")
            try expectSamePixels(pixels(thin), exported, "Degenerate-path redo changed export")
        }
    }

    let shape = EditorDocument(baseImage: makeImage())
    try createVisual(shape, kind: "rectangle-filled")
    selectObject(shape, at: objectGrab("rectangle-filled"))
    let before = try selectedOverlay(shape)
    let handle = CGPoint(x: before.handleRect.midX - 2, y: before.handleRect.midY + 2)
    drag(shape, from: handle, to: CGPoint(x: handle.x + 60, y: handle.y + 7), constrained: true)
    let after = try selectedOverlay(shape).rect
    try expect(
        abs(after.width / after.height - before.rect.width / before.rect.height) < 0.001
            && after.origin == before.rect.origin && after.width > before.rect.width,
        "Shift corner resizing did not preserve the object's aspect ratio and opposite corner"
    )
}

@MainActor
private func inkHitTestingAndMaskOrdering() throws {
    for kind in ["stroke", "arrow", "rectangle-outline", "ellipse-outline", "rectangle-filled", "ellipse-filled"] {
        let document = EditorDocument(baseImage: makeImage())
        let object = try createVisual(document, kind: kind)
        let emptyPoint: CGPoint
        switch kind {
        case "stroke", "arrow": emptyPoint = CGPoint(x: 110, y: 210)
        case "ellipse-filled": emptyPoint = CGPoint(x: 103, y: 103)
        default: emptyPoint = CGPoint(x: 200, y: 160)
        }
        selectObject(document, at: emptyPoint)
        if kind == "rectangle-filled" {
            try expect(document.selectedAnnotation?.id == object.id, "A filled rectangle's interior was not selectable")
        } else {
            try expect(document.selectedAnnotation == nil, "\(kind) selected empty space inside its bounding box")
        }
        selectObject(document, at: objectGrab(kind))
        try expect(document.selectedAnnotation?.id == object.id, "Actual \(kind) ink was not selectable")
        if kind == "ellipse-filled" {
            selectObject(document, at: CGPoint(x: 200, y: 160))
            try expect(document.selectedAnnotation?.id == object.id, "A filled ellipse's interior was not selectable")
        }
    }

    let document = EditorDocument(baseImage: makeImage())
    let source = try pixels(document)
    rectangle(document, color: .red)
    let bottom = document.annotations[0]
    rectangle(document, color: .blue)
    let top = document.annotations[1]
    let overlap = CGPoint(x: 240, y: 160)
    selectObject(document, at: overlap)
    try expect(document.selectedAnnotation?.id == top.id, "Overlapping objects did not select the topmost ink")
    erase(document, from: CGPoint(x: 100, y: 160), to: CGPoint(x: 380, y: 160), width: 36)
    let erased = document.annotations
    let erasedPixels = try pixels(document)
    try same(erasedPixels, source, at: overlap, "Mask did not hide both older objects")
    selectObject(document, at: overlap)
    try expect(document.selectedAnnotation == nil, "Masked ink remained selectable through an eraser")
    selectObject(document, at: CGPoint(x: 240, y: 210))
    try expect(document.selectedAnnotation?.id == top.id, "Unmasked portion of an object became unselectable")
    rectangle(document, color: .green)
    let later = document.annotations.last!
    let repaintedPixels = try pixels(document)
    selectObject(document, at: overlap)
    try expect(document.selectedAnnotation?.id == later.id, "Earlier eraser masked selection of a later object")
    document.undo()
    try expect(document.annotations == erased, "Undo removed an object other than the later repaint")
    try expectSamePixels(pixels(document), erasedPixels, "Undo repaint changed mask ordering")
    document.undo()
    try expect(document.annotations == [bottom, top], "Undo eraser lost earlier object order")
    selectObject(document, at: overlap)
    try expect(document.selectedAnnotation?.id == top.id, "Undo eraser did not restore selectability")
    document.redo()
    document.redo()
    try expectSamePixels(pixels(document), repaintedPixels, "Redo did not reproduce erased-then-repainted ordering")

    _ = document.handleEscape()
    document.activateTool(.ellipse)
    document.setShapeStyle(.outline)
    document.beginInteraction(at: CGPoint(x: 100, y: 100))
    document.endInteraction(at: CGPoint(x: 380, y: 260))
    selectObject(document, at: overlap)
    try expect(document.selectedAnnotation?.id == later.id, "An outline ellipse's empty hole blocked older visible ink")
}

@MainActor
private func selectedStyleHistory() throws {
    for kind in visualKinds {
        let document = EditorDocument(baseImage: makeImage())
        let original = try createVisual(document, kind: kind)
        selectObject(document, at: objectGrab(kind))
        document.beginStyleEditing()
        if kind == "blur" {
            for value in [16.0, 21, 28] { document.setBlurControlValue(value) }
            try expect(document.currentBlurControlValue == 28, "Blur control did not expose the selected object's value")
        } else if kind == "text" {
            for value in [28.0, 34, 40] { document.setTextSizeControlValue(value) }
            try expect(document.currentTextSizeControlValue == 40, "Text size control did not expose the selected object's value")
        } else {
            for value in [16.0, 21, 28] { document.setLineWidthControlValue(value) }
            try expect(document.currentLineWidthControlValue == 28, "Width control did not expose the selected object's value")
        }
        document.endStyleEditing()
        let styled = document.annotations
        let styledPixels = try pixels(document)
        try expect(styled != [original] && styled[0].id == original.id, "Slider did not style the existing \(kind)")
        document.undo()
        try expect(document.annotations == [original], "One undo did not restore an entire \(kind) slider drag")
        document.redo()
        try expect(document.annotations == styled, "Slider redo changed \(kind) style or ID")
        try expectSamePixels(pixels(document), styledPixels, "Slider redo changed \(kind) export")
        if kind != "blur" {
            document.applySelectedColor(.blue)
            let recolored = document.annotations
            try expect(recolored[0].color == .blue, "Color control did not update selected \(kind)")
            document.undo()
            try expect(document.annotations == styled, "One color update was not a separate history entry")
            document.redo()
            try expect(document.annotations == recolored, "Color redo changed the selected object")
        } else {
            document.applySelectedColor(.blue)
            try expect(document.annotations == styled, "Color control mutated a blur")
        }
        if case let .shape(shape) = styled[0] {
            let beforeRestyle = document.annotations
            let beforeRestylePixels = try pixels(document)
            document.setShapeStyle(shape.style == .filled ? .outline : .filled)
            try expect(document.currentShapeStyle != shape.style, "Shape-style control did not update selection")
            let restyled = document.annotations
            document.undo()
            try expect(document.annotations == beforeRestyle, "Style undo changed shape payload, identity, or order")
            try expectSamePixels(pixels(document), beforeRestylePixels, "Style undo did not restore filled/outline pixels")
            document.redo()
            try expect(document.annotations == restyled, "Shape-style redo changed the object")
        }
    }

    let document = EditorDocument(baseImage: makeTextImage())
    let original = try addText(document, "Before\nnative editing", at: CGPoint(x: 80, y: 60), size: 24)
    let before = document.annotations
    let beforePixels = try pixels(document)
    try expect(document.beginEditingSelectedText(), "Could not reopen text for a grouped native session")
    document.setPendingText("After\n\nmultiline editing\n")
    document.setTextFont(.monospaced)
    document.setTextSizeControlValue(36)
    document.applySelectedColor(.blue)
    try expect(document.duplicateSelectedAnnotation() == false, "Duplicate consumed active native input")
    document.commitPendingTextInsertion()
    let edited = document.annotations
    let editedPixels = try pixels(document)
    try expect(edited.count == 1 && edited[0].id == original.id, "Native Done duplicated the text object")
    document.undo()
    try expect(document.annotations == before, "Native Done did not group content and all styles into one edit")
    try expectSamePixels(pixels(document), beforePixels, "Native session undo left changed text ink")
    document.redo()
    try expect(document.annotations == edited, "Native session redo lost content or typography")
    try expectSamePixels(pixels(document), editedPixels, "Native session redo changed multiline export")
    document.undo()
    document.undo()
    try expect(document.annotations.isEmpty && document.canUndo == false, "Native session generated multiple document history entries")

    let ungrouped = EditorDocument(baseImage: makeImage())
    let arrow = try createVisual(ungrouped, kind: "arrow")
    selectObject(ungrouped, at: objectGrab("arrow"))
    ungrouped.setLineWidthControlValue(18)
    let firstWidth = ungrouped.annotations
    ungrouped.setLineWidthControlValue(26)
    let secondWidth = ungrouped.annotations
    ungrouped.undo()
    try expect(ungrouped.annotations == firstWidth, "Ungrouped width calls were incorrectly merged")
    ungrouped.undo()
    try expect(ungrouped.annotations == [arrow], "Ungrouped width undo did not restore the original")
    ungrouped.redo()
    ungrouped.redo()
    try expect(ungrouped.annotations == secondWidth, "Ungrouped width redo lost a style transition")
}

@MainActor
private func replacingID(_ annotation: EditorAnnotation, with id: UUID) -> EditorAnnotation {
    switch annotation {
    case var .stroke(value): value.id = id; return .stroke(value)
    case var .arrow(value): value.id = id; return .arrow(value)
    case var .shape(value): value.id = id; return .shape(value)
    case var .blur(value): value.id = id; return .blur(value)
    case var .text(value): value.id = id; return .text(value)
    case .eraser: return annotation
    }
}

@MainActor
private func duplicateDeleteHistory() throws {
    for kind in visualKinds {
        let document = EditorDocument(baseImage: makeImage())
        let original = try createVisual(document, kind: kind)
        erase(document, from: CGPoint(x: 80, y: 190), to: CGPoint(x: 420, y: 190), width: 20)
        selectObject(document, at: objectGrab(kind))
        try expect(document.selectedAnnotation?.id == original.id, "Duplicate fixture lost the visible \(kind)")
        let before = document.annotations
        let beforeSelection = document.selectedAnnotation
        let beforePixels = try pixels(document)
        try expect(document.duplicateSelectedAnnotation(), "Could not duplicate selected \(kind)")
        let duplicated = document.annotations
        guard let copy = duplicated.last else { throw Failure.check("Duplicate did not append \(kind)") }
        try expect(
            duplicated.count == before.count + 1 && Array(duplicated.dropLast()) == before
                && copy.id != original.id && document.selectedAnnotation?.id == copy.id,
            "Duplicate changed an existing ID/order or did not select the new \(kind)"
        )
        let originalBounds = EditorAnnotationGeometry.bounds(of: original)
        let copyBounds = EditorAnnotationGeometry.bounds(of: copy)
        let offset = CGSize(width: copyBounds.minX - originalBounds.minX, height: copyBounds.minY - originalBounds.minY)
        try expect(offset != .zero, "Duplicate did not offset \(kind) despite available source space")
        try expect(
            CGRect(origin: .zero, size: document.pixelSize).contains(copyBounds),
            "Duplicate placed a fitting \(kind) outside the source"
        )
        try expectTranslated(replacingID(copy, with: original.id), from: original, by: offset)
        let duplicatePixels = try pixels(document)
        try expect(try changedPixels(duplicatePixels, from: beforePixels).isEmpty == false, "Duplicate did not add visible \(kind) ink")
        if kind == "rectangle-filled" {
            let exposed = CGPoint(x: copyBounds.midX, y: 190)
            try expect(
                distance(color(duplicatePixels, exposed), color(beforePixels, exposed)) > 0.1,
                "Duplicate remained below the older eraser action"
            )
        }
        document.undo()
        try expect(document.annotations == before && document.selectedAnnotation == beforeSelection, "Duplicate undo did not restore exact \(kind) order and selection")
        try expectSamePixels(pixels(document), beforePixels, "Duplicate undo changed earlier eraser order")
        document.redo()
        try expect(document.annotations == duplicated && document.selectedAnnotation?.id == copy.id, "Duplicate redo minted another UUID or lost selection")
        try expectSamePixels(pixels(document), duplicatePixels, "Duplicate redo changed export")
        try expect(document.deleteSelectedAnnotation(), "Could not delete duplicate \(kind)")
        try expect(document.annotations == before, "Deleting a duplicate removed the wrong \(kind)")
        try expect(document.selectedAnnotation == nil, "Delete retained a dangling selected UUID")
        document.undo()
        try expect(document.annotations == duplicated && document.selectedAnnotation?.id == copy.id, "Delete undo did not restore the duplicate's ID/index/selection")
        document.redo()
        try expect(document.annotations == before, "Delete redo removed the wrong object")
        try expectSamePixels(pixels(document), beforePixels, "Delete redo changed prior eraser output")
        document.undo()
        document.undo()
        try expect(document.annotations == before && document.selectedAnnotation?.id == original.id, "Returning before duplication lost original selection")
        try expect(document.deleteSelectedAnnotation(), "Could not delete the original \(kind) below an eraser")
        try expect(document.annotations == Array(before.dropFirst()), "Delete did not remove the selected original index")
        document.undo()
        try expect(document.annotations == before && document.selectedAnnotation?.id == original.id, "Delete undo did not reinsert \(kind) at its original index")
        try expectSamePixels(pixels(document), beforePixels, "Delete undo reordered \(kind) above its eraser")
    }

    let edge = EditorDocument(baseImage: makeImage())
    edge.activateTool(.rectangle)
    edge.setShapeStyle(.filled)
    edge.beginInteraction(at: CGPoint(x: 530, y: 310))
    edge.endInteraction(at: CGPoint(x: 630, y: 390))
    selectObject(edge, at: CGPoint(x: 570, y: 340))
    let original = edge.annotations[0]
    try expect(edge.duplicateSelectedAnnotation(), "Near-edge object could not be duplicated")
    let copied = edge.annotations.last!
    let bounds = EditorAnnotationGeometry.bounds(of: copied)
    let originalBounds = EditorAnnotationGeometry.bounds(of: original)
    try expect(
        copied.id != original.id && bounds != originalBounds
            && bounds.size == originalBounds.size
            && CGRect(origin: .zero, size: edge.pixelSize).contains(bounds),
        "Near-edge duplicate shrank, overlapped exactly, or escaped available source space"
    )
}

@MainActor
private func redoBoundariesAndIsolation() throws {
    let document = EditorDocument(baseImage: makeImage())
    let original = try createVisual(document, kind: "rectangle-filled")
    let grab = objectGrab("rectangle-filled")
    selectObject(document, at: grab)
    document.applySelectedColor(.blue)
    let styled = document.annotations
    document.undo()
    let redoName = document.redoActionName
    try expect(document.annotations == [original] && document.canRedo, "Could not establish a redo branch")
    selectObject(document, at: CGPoint(x: 600, y: 350))
    try expect(document.deleteSelectedAnnotation() == false, "Delete without selection mutated the document")
    try expect(document.duplicateSelectedAnnotation() == false, "Duplicate without selection mutated the document")
    selectObject(document, at: grab)
    document.applySelectedColor(original.color!)
    document.setLineWidthControlValue(document.currentLineWidthControlValue)
    document.setShapeStyle(document.currentShapeStyle)
    let originalWidth = document.currentLineWidthControlValue
    document.beginStyleEditing()
    document.setLineWidthControlValue(originalWidth + 10)
    document.setLineWidthControlValue(originalWidth)
    document.endStyleEditing()
    drag(document, from: grab, to: grab)
    let overlay = try selectedOverlay(document)
    let handle = CGPoint(x: overlay.handleRect.midX - 3, y: overlay.handleRect.midY + 2)
    drag(document, from: handle, to: handle)
    try expect(
        document.annotations == [original] && document.canRedo && document.redoActionName == redoName,
        "Selection, unchanged styling, or zero-motion editing consumed the redo branch"
    )
    document.beginInteraction(at: grab)
    document.updateInteraction(at: CGPoint(x: grab.x + 33, y: grab.y + 21))
    try expect(document.handleEscape(), "Escape did not cancel an active object move")
    try expect(document.annotations == [original] && document.canRedo, "Escape left changed geometry or cleared redo")
    selectObject(document, at: grab)
    document.beginInteraction(at: handle)
    document.updateInteraction(at: CGPoint(x: handle.x + 40, y: handle.y + 30))
    document.activateTool(.pen)
    try expect(document.annotations == [original] && document.canRedo, "Tool switching committed an active resize or cleared redo")
    selectObject(document, at: grab)
    document.beginInteraction(at: grab)
    document.updateInteraction(at: CGPoint(x: grab.x + 33, y: grab.y + 21))
    document.undo()
    try expect(document.annotations == [original] && document.canRedo, "Undo of active move consumed a committed entry")
    document.activateTool(.pen)
    document.beginInteraction(at: CGPoint(x: 400, y: 50))
    document.updateInteraction(at: CGPoint(x: 450, y: 90))
    try expect(document.handleEscape(), "Escape did not cancel new pen input")
    document.activateTool(.eraser)
    document.beginInteraction(at: grab)
    document.updateInteraction(at: CGPoint(x: 250, y: 160))
    document.activateTool(.move)
    try expect(
        document.annotations == [original] && document.canRedo && document.redoActionName == redoName,
        "Cancelling uncommitted drawing/erasing consumed the redo branch"
    )
    document.redo()
    try expect(document.annotations == styled, "Redo after no-op/cancel did not restore the original branch")
    document.undo()
    selectObject(document, at: grab)
    drag(document, from: grab, to: CGPoint(x: grab.x + 10, y: grab.y + 10))
    let moved = document.annotations
    try expect(document.canRedo == false && document.redoActionName.isEmpty, "A real mutation did not truncate redo")
    document.redo()
    try expect(document.annotations == moved, "Truncated redo resurrected an obsolete style branch")
    document.undo()
    try expect(document.annotations == [original], "No-op/cancel input produced hidden history entries")
    document.undo()
    try expect(document.annotations.isEmpty && document.canUndo == false, "No-op/cancel input fragmented creation history")

    let text = EditorDocument(baseImage: makeTextImage())
    let inserted = try addText(text, "Unchanged\ntext session", at: CGPoint(x: 70, y: 50), size: 24)
    text.setTextFont(.serif)
    let textStyled = text.annotations
    text.undo()
    try expect(text.beginEditingSelectedText(), "Could not reopen text with a redo branch")
    text.setPendingText(inserted.text)
    text.setTextFont(inserted.font)
    text.setTextSizeControlValue(Double(inserted.fontSize))
    text.applySelectedColor(inserted.color)
    text.commitPendingTextInsertion()
    try expect(text.canRedo, "An unchanged native session cleared redo")
    text.redo()
    try expect(text.annotations == textStyled, "Redo after unchanged native input lost the style edit")

    let other = EditorDocument(baseImage: makeImage())
    try createVisual(other, kind: "ellipse-filled")
    let otherObjects = other.annotations
    let otherPixels = try pixels(other)
    let otherUndoName = other.undoActionName
    text.undo()
    text.undo()
    try expect(
        other.annotations == otherObjects && other.canUndo && other.canRedo == false
            && other.undoActionName == otherUndoName,
        "Undo in one editor changed another editor's document or history"
    )
    try expectSamePixels(pixels(other), otherPixels, "Another document's undo changed independent export")
    other.undo()
    try expect(text.annotations.isEmpty && text.canRedo, "Undo in another editor changed the first editor's redo branch")
    text.redo()
    try expect(other.annotations.isEmpty && other.canRedo, "Redo in one editor affected another editor")
}

@MainActor
private func fileExport() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let document = EditorDocument(baseImage: makeImage())
    rectangle(document)
    erase(document, from: CGPoint(x: 100, y: 160), to: CGPoint(x: 380, y: 160))
    guard let image = document.renderCompositeImage() else {
        throw Failure.check("Could not render export fixture")
    }
    let original = try pixels(document)
    let pngURL = directory.appendingPathComponent("image.png")
    try ScreenshotExportFormat.png.write(image, to: pngURL, jpegQuality: 0.9)
    guard let png = NSBitmapImageRep(data: try Data(contentsOf: pngURL)),
          let pngSource = CGImageSourceCreateWithURL(pngURL as CFURL, nil) else {
        throw Failure.check("Saved PNG could not be decoded")
    }
    try expect(CGImageSourceGetType(pngSource) as String? == "public.png", "PNG contains the wrong format")
    try expect(png.pixelsWide == 640 && png.pixelsHigh == 400, "PNG lost Retina resolution")
    for y in 0..<400 {
        for x in 0..<640 {
            try same(png, original, at: CGPoint(x: x, y: y), "PNG changed annotation pixels or alpha")
        }
    }

    func jpeg(_ quality: Double, name: String) throws -> NSBitmapImageRep {
        let url = directory.appendingPathComponent(name)
        try ScreenshotExportFormat.jpeg.write(image, to: url, jpegQuality: quality)
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.check("Saved JPEG could not be decoded")
        }
        try expect(CGImageSourceGetType(source) as String? == "public.jpeg", "JPEG contains the wrong format")
        try expect(bitmap.pixelsWide == 640 && bitmap.pixelsHigh == 400, "JPEG lost Retina resolution")
        try expect(
            distance(color(bitmap, CGPoint(x: 560, y: 360)), NSColor.white.usingColorSpace(.sRGB)!) < 0.03,
            "JPEG did not flatten transparent pixels over white"
        )
        return bitmap
    }
    let low = try jpeg(0.05, name: "low.jpg")
    let high = try jpeg(1, name: "high.jpg")
    var lowError: CGFloat = 0
    var highError: CGFloat = 0
    for y in stride(from: 0, to: 300, by: 7) {
        for x in stride(from: 0, to: 640, by: 7) {
            let point = CGPoint(x: x, y: y)
            let expected = color(original, point)
            lowError += distance(color(low, point), expected)
            highError += distance(color(high, point), expected)
        }
    }
    try expect(highError < lowError, "JPEG quality did not improve fidelity to the composite")

    let invalidURL = directory.appendingPathComponent("missing/image.png")
    var writeFailed = false
    do {
        try ScreenshotExportFormat.png.write(image, to: invalidURL, jpegQuality: 0.9)
    } catch {
        writeFailed = true
    }
    try expect(writeFailed, "Export silently succeeded when the destination directory was missing")
    try expectSamePixels(pixels(document), original, "Failed export changed the document")
    let savedPNG = NSBitmapImageRep(data: try Data(contentsOf: pngURL))!
    try expectSamePixels(savedPNG, png, "Failed export damaged the previously saved file")
}

@MainActor
private func decodedPixels(_ image: NSImage) throws -> NSBitmapImageRep {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw Failure.check("Could not decode the image's native pixels")
    }
    return NSBitmapImageRep(cgImage: cgImage)
}

@MainActor
private func expectPixelRegion(
    _ actual: NSBitmapImageRep, from original: NSBitmapImageRep, rect: CGRect, _ message: String
) throws {
    try expect(
        actual.pixelsWide == Int(rect.width) && actual.pixelsHigh == Int(rect.height),
        "\(message): wrong pixel dimensions"
    )
    try expect(
        rect.minX >= 0 && rect.minY >= 0
            && rect.maxX <= CGFloat(original.pixelsWide) && rect.maxY <= CGFloat(original.pixelsHigh),
        "\(message): comparison region escaped the original image"
    )
    // Native CGImage crops and composite/PNG decodes need not share a bitmap layout or ICC profile.
    for y in 0..<actual.pixelsHigh {
        for x in 0..<actual.pixelsWide {
            let actualPoint = CGPoint(x: x, y: y)
            let originalPoint = CGPoint(x: x + Int(rect.minX), y: y + Int(rect.minY))
            try expect(
                distance(color(actual, actualPoint), color(original, originalPoint)) < 0.015,
                "\(message): normalized color differs at \(actualPoint)"
            )
        }
    }
}

@MainActor
private func expectRetinaSize(_ document: EditorDocument, _ size: CGSize) throws {
    try expect(document.pixelSize == size, "Crop reported the wrong image-pixel size")
    try expect(
        document.baseImage.size == CGSize(width: size.width / 2, height: size.height / 2),
        "Crop changed the source's two-pixels-per-point scale"
    )
    let native = try decodedPixels(document.baseImage)
    try expect(
        native.pixelsWide == Int(size.width) && native.pixelsHigh == Int(size.height),
        "Crop resized image metadata without cropping its native pixels"
    )
}

@MainActor
private func cropRetinaPixels() throws {
    let document = EditorDocument(baseImage: makeImage())
    let originalBase = try decodedPixels(document.baseImage)
    let originalExport = try pixels(document)
    let rect = CGRect(x: 73, y: 41, width: 491, height: 307)
    document.beginCrop()
    try expect(
        document.cropRect == CGRect(x: 0, y: 0, width: 640, height: 400),
        "Crop did not start with the complete current image"
    )
    document.updateCropRect(rect)
    try expect(document.cropRect == rect, "Crop draft did not use top-left native image pixels")
    try expectRetinaSize(document, CGSize(width: 640, height: 400))
    try expectPixelRegion(
        pixels(document), from: originalExport, rect: CGRect(x: 0, y: 0, width: 640, height: 400),
        "An unapplied draft changed export"
    )
    try expect(document.applyCrop(), "A nonzero-origin crop was not applied")
    try expect(document.cropRect == nil && document.undoActionName == "Crop", "Applying crop left a draft or the wrong history action")
    try expectRetinaSize(document, rect.size)
    try expectPixelRegion(decodedPixels(document.baseImage), from: originalBase, rect: rect, "Retina base crop")
    try expectPixelRegion(pixels(document), from: originalExport, rect: rect, "Retina exported crop")
}

@MainActor
private func cropAnnotationsAndMasks() throws {
    let rect = CGRect(x: 137, y: 87, width: 217, height: 173)
    let translation = CGSize(width: -rect.minX, height: -rect.minY)
    for kind in visualKinds {
        let document = EditorDocument(baseImage: makeImage())
        if kind == "text" {
            try addText(
                document, "Wrapped text remains unchanged after cropping. Привет мир! Another sentence wraps too.",
                at: CGPoint(x: 100, y: 100), size: 24
            )
            try setTextWidth(document, to: 220)
            try expect(
                inkLineRects(EditorTextLayout(annotation: textAnnotation(document))).count >= 3,
                "Crop text fixture did not contain wrapped lines"
            )
        } else {
            try createVisual(document, kind: kind)
        }
        let original = document.annotations[0]
        _ = document.handleEscape()
        document.activateTool(.rectangle)
        document.setShapeStyle(.filled)
        document.applySelectedColor(.blue)
        document.beginInteraction(at: CGPoint(x: 530, y: 310))
        document.endInteraction(at: CGPoint(x: 620, y: 380))
        erase(document, from: CGPoint(x: 540, y: 340), to: CGPoint(x: 610, y: 340), width: 18)
        erase(document, from: CGPoint(x: 110, y: 175), to: CGPoint(x: 330, y: 175), width: 18)
        let retainedMask = document.annotations.last!
        document.activateTool(.rectangle)
        document.setShapeStyle(.filled)
        document.applySelectedColor(.green)
        document.beginInteraction(at: CGPoint(x: 205, y: 168))
        document.endInteraction(at: CGPoint(x: 225, y: 182))
        let laterDrawing = document.annotations.last!
        let before = document.annotations
        let beforePixels = try pixels(document)
        let beforeBase = try decodedPixels(document.baseImage)

        document.beginCrop()
        document.updateCropRect(rect)
        try expect(document.applyCrop(), "Could not crop partially clipped \(kind)")
        try expect(
            document.annotations.map(\.id) == [original.id, retainedMask.id, laterDrawing.id],
            "Crop flattened/reordered \(kind) or retained wholly outside objects/masks"
        )
        for (actual, expected) in zip(document.annotations, [original, retainedMask, laterDrawing]) {
            try expectTranslated(actual, from: expected, by: translation)
        }
        try expectPixelRegion(pixels(document), from: beforePixels, rect: rect, "Crop changed clipped \(kind), erasure, or later ink")
        try expectPixelRegion(decodedPixels(document.baseImage), from: beforeBase, rect: rect, "Crop flattened \(kind) into the base")
        if kind == "text" {
            let croppedText = try textAnnotation(document, id: original.id)
            guard case let .text(originalText) = original else { throw Failure.check("Missing wrapped text fixture") }
            try expect(
                inkLineRects(EditorTextLayout(annotation: croppedText))
                    == inkLineRects(EditorTextLayout(annotation: originalText)),
                "Crop reflowed partially clipped text instead of retaining its wrap width"
            )
        }
        document.undo()
        try expect(document.annotations == before, "One crop undo did not restore \(kind) IDs, geometry, and mask order")
        try expectRetinaSize(document, CGSize(width: 640, height: 400))
        try expectPixelRegion(
            pixels(document), from: beforePixels, rect: CGRect(x: 0, y: 0, width: 640, height: 400),
            "Crop undo changed \(kind) pixels"
        )
        document.redo()
        try expect(
            document.annotations.map(\.id) == [original.id, retainedMask.id, laterDrawing.id],
            "Crop redo changed retained IDs/order"
        )
        try expectPixelRegion(pixels(document), from: beforePixels, rect: rect, "Crop redo changed clipped \(kind)")
    }
}

@MainActor
private func cropInterleavedHistory() throws {
    let document = EditorDocument(baseImage: makeImage())
    let reference = EditorDocument(baseImage: makeImage())
    for fixture in [document, reference] {
        try createVisual(fixture, kind: "rectangle-filled")
        try createVisual(fixture, kind: "blur")
        erase(fixture, from: CGPoint(x: 110, y: 165), to: CGPoint(x: 330, y: 165), width: 18)
    }
    let original = document.annotations
    let originalPixels = try pixels(document)
    let originalBase = try decodedPixels(document.baseImage)
    let full = CGRect(x: 0, y: 0, width: 640, height: 400)
    let firstRect = CGRect(x: 117, y: 83, width: 333, height: 211)
    document.beginCrop()
    document.updateCropRect(firstRect)
    try expect(document.applyCrop(), "First history crop failed")
    let first = document.annotations
    let firstPixels = try pixels(document)
    try expect(document.undoActionName == "Crop", "Crop was not exposed as one named undo operation")
    document.undo()
    try expect(document.annotations == original && document.redoActionName == "Crop", "One undo did not restore all pre-crop objects")
    try expectRetinaSize(document, full.size)
    try expectPixelRegion(decodedPixels(document.baseImage), from: originalBase, rect: full, "Crop undo changed original source pixels")
    try expectPixelRegion(pixels(document), from: originalPixels, rect: full, "Crop undo changed the original composite")
    document.redo()
    try expect(document.annotations == first, "Crop redo changed translated IDs/order")
    try expectPixelRegion(pixels(document), from: firstPixels, rect: CGRect(origin: .zero, size: firstRect.size), "Crop redo changed blur-edge pixels")

    for (fixture, grab) in [
        (document, CGPoint(x: 113, y: 47)), (reference, CGPoint(x: 230, y: 130)),
    ] {
        selectObject(fixture, at: grab)
        try expect(fixture.selectedAnnotation?.kind == .blur, "Could not select the retained partial blur")
        fixture.setBlurControlValue(22)
    }
    let styled = document.annotations
    let styledPixels = try pixels(document)
    try expect(try changedPixels(styledPixels, from: firstPixels).isEmpty == false, "Post-crop blur styling did not affect visible pixels")
    try expectPixelRegion(
        styledPixels, from: pixels(reference), rect: firstRect,
        "Editing blur after crop sampled the new edge instead of the original source"
    )
    document.undo()
    try expect(document.annotations == first, "Undo of a post-crop edit consumed the crop or changed other objects")
    try expectPixelRegion(pixels(document), from: firstPixels, rect: CGRect(origin: .zero, size: firstRect.size), "Blur edit undo changed crop pixels")
    document.redo()
    try expect(document.annotations == styled, "Redo of post-crop styling changed IDs/order")
    for (fixture, grab) in [
        (document, CGPoint(x: 113, y: 47)), (reference, CGPoint(x: 230, y: 130)),
    ] {
        drag(fixture, from: grab, to: CGPoint(x: grab.x + 9, y: grab.y + 13))
    }
    let moved = document.annotations
    let movedPixels = try pixels(document)
    try expectTranslated(moved[1], from: styled[1], by: CGSize(width: 9, height: 13))
    try expectPixelRegion(movedPixels, from: pixels(reference), rect: firstRect, "Moving a cropped blur lost its original source coordinates")

    let secondRect = CGRect(x: 21, y: 17, width: 191, height: 127)
    document.beginCrop()
    document.updateCropRect(secondRect)
    try expect(document.applyCrop(), "Repeated crop failed")
    let second = document.annotations
    try expectRetinaSize(document, secondRect.size)
    try expectPixelRegion(pixels(document), from: movedPixels, rect: secondRect, "Repeated crop changed partial blur/eraser pixels")
    try expectPixelRegion(
        pixels(document), from: pixels(reference),
        rect: CGRect(x: firstRect.minX + secondRect.minX, y: firstRect.minY + secondRect.minY, width: 191, height: 127),
        "Repeated crop did not accumulate original blur-source coordinates"
    )
    for (expected, expectedPixels, size) in [
        (moved, movedPixels, firstRect.size),
        (styled, styledPixels, firstRect.size),
        (first, firstPixels, firstRect.size),
        (original, originalPixels, full.size),
    ] {
        document.undo()
        try expect(document.annotations == expected, "Interleaved crop/edit undo changed IDs, geometry, or order")
        try expectRetinaSize(document, size)
        try expectPixelRegion(pixels(document), from: expectedPixels, rect: CGRect(origin: .zero, size: size), "Interleaved crop/edit undo changed pixels")
    }
    document.undo()
    try expect(document.annotations == Array(original.dropLast()), "History before the crop stopped being a per-annotation erase operation")
    try expectRetinaSize(document, full.size)
    for (expected, expectedPixels, size) in [
        (original, originalPixels, full.size),
        (first, firstPixels, firstRect.size),
        (styled, styledPixels, firstRect.size),
        (moved, movedPixels, firstRect.size),
    ] {
        document.redo()
        try expect(document.annotations == expected, "Interleaved crop/edit redo changed IDs, geometry, or order")
        try expectRetinaSize(document, size)
        try expectPixelRegion(pixels(document), from: expectedPixels, rect: CGRect(origin: .zero, size: size), "Interleaved crop/edit redo changed pixels")
    }
    document.redo()
    try expect(document.annotations == second && document.canRedo == false, "Repeated crop redo lost state or added extra history")
    try expectRetinaSize(document, secondRect.size)
    try expectPixelRegion(pixels(document), from: movedPixels, rect: secondRect, "Repeated crop redo changed blur-source offset")
}

@MainActor
private func cropDraftBoundaries() throws {
    let document = EditorDocument(baseImage: makeImage())
    let original = try createVisual(document, kind: "rectangle-filled")
    selectObject(document, at: objectGrab("rectangle-filled"))
    document.applySelectedColor(.blue)
    let styled = document.annotations
    document.undo()
    let redoName = document.redoActionName
    let originalPixels = try pixels(document)
    let draft = CGRect(x: 137, y: 87, width: 217, height: 173)
    func expectUnchanged(_ message: String) throws {
        try expect(
            document.cropRect == nil && document.annotations == [original]
                && document.canRedo && document.redoActionName == redoName,
            "\(message): changed committed objects or consumed Redo"
        )
        try expectRetinaSize(document, CGSize(width: 640, height: 400))
    }
    document.beginCrop()
    document.updateCropRect(draft)
    document.cancelCrop()
    try expectUnchanged("Cancel crop")
    document.beginCrop()
    try expect(document.applyCrop() == false, "Full-image crop was treated as an applied edit")
    try expectUnchanged("Full-image no-op")
    document.beginCrop()
    document.updateCropRect(draft)
    try expect(document.handleEscape(), "Escape did not consume/cancel the crop draft")
    try expectUnchanged("Escape crop")
    document.beginCrop()
    document.updateCropRect(draft)
    document.undo()
    try expectUnchanged("Undo active crop")
    document.beginCrop()
    document.updateCropRect(draft)
    document.redo()
    try expectUnchanged("Redo active crop")
    document.beginCrop()
    document.updateCropRect(draft)
    document.activateTool(document.selectedTool)
    try expectUnchanged("Reactivating a tool")
    document.beginCrop()
    document.updateCropRect(draft)
    document.activateTool(.pen)
    try expectUnchanged("Switching tools")
    try expect(document.applyCrop() == false, "Apply without a draft changed the document")
    try expectPixelRegion(
        pixels(document), from: originalPixels, rect: CGRect(x: 0, y: 0, width: 640, height: 400),
        "Cancelled/no-op crops changed pixels"
    )
    document.redo()
    try expect(document.annotations == styled, "Redo after crop cancellation did not restore its original edit")

    let pending = EditorDocument(baseImage: makeImage())
    pending.activateTool(.text)
    pending.beginInteraction(at: CGPoint(x: 80, y: 60))
    pending.setPendingText("Commit before crop")
    pending.beginCrop()
    try expect(pending.pendingTextInsertion == nil && pending.annotations.count == 1, "Beginning crop lost or left pending text")
    pending.cancelCrop()
    pending.undo()
    try expect(pending.annotations.isEmpty && pending.canRedo, "Crop failed to finish pending text as its own history entry")

    let styling = EditorDocument(baseImage: makeImage())
    let stroke = try createVisual(styling, kind: "stroke")
    selectObject(styling, at: objectGrab("stroke"))
    styling.beginStyleEditing()
    styling.setLineWidthControlValue(20)
    styling.setLineWidthControlValue(26)
    let restyled = styling.annotations
    styling.beginCrop()
    styling.cancelCrop()
    styling.undo()
    try expect(styling.annotations == [stroke], "Beginning crop did not finish the grouped style edit")
    styling.redo()
    try expect(styling.annotations == restyled, "Style redo after cancelling crop lost the finished edit")

    for tool in [EditorTool.pen, .eraser, .move] {
        let gesture = EditorDocument(baseImage: makeImage())
        try createVisual(gesture, kind: "rectangle-filled")
        let committed = gesture.annotations
        let committedPixels = try pixels(gesture)
        if tool == .move {
            selectObject(gesture, at: objectGrab("rectangle-filled"))
        } else {
            gesture.activateTool(tool)
        }
        gesture.beginInteraction(at: CGPoint(x: 200, y: 160))
        gesture.updateInteraction(at: CGPoint(x: 260, y: 190))
        gesture.beginCrop()
        try expect(gesture.annotations == committed, "Beginning crop committed unfinished \(tool) input")
        try expectPixelRegion(
            pixels(gesture), from: committedPixels, rect: CGRect(x: 0, y: 0, width: 640, height: 400),
            "Beginning crop retained unfinished \(tool) pixels"
        )
        gesture.cancelCrop()
        gesture.undo()
        try expect(gesture.annotations.isEmpty, "Cancelling unfinished \(tool) while beginning crop created extra history")
    }
}

@MainActor
private func cropDraftBounds() throws {
    let document = EditorDocument(baseImage: makeImage())
    try createVisual(document, kind: "rectangle-filled")
    document.undo()
    let redoName = document.redoActionName
    let originalPixels = try pixels(document)
    let full = CGRect(x: 0, y: 0, width: 640, height: 400)
    let invalid = [
        CGRect.zero, CGRect(x: 10, y: 10, width: 0, height: 12),
        CGRect(x: 10, y: 10, width: 12, height: 0),
        CGRect(x: 700, y: 20, width: 30, height: 30),
        CGRect(x: -40, y: -40, width: 20, height: 20),
        CGRect(x: CGFloat.nan, y: 0, width: 30, height: 30),
        CGRect(x: 0, y: CGFloat.infinity, width: 30, height: 30),
        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 30),
        CGRect(x: 0, y: 0, width: 30, height: CGFloat.nan),
        CGRect.null, CGRect.infinite,
    ]
    for rect in invalid {
        document.beginCrop()
        document.updateCropRect(rect)
        try expect(document.cropRect == full, "Invalid crop bounds replaced the full-image draft")
        try expect(document.applyCrop() == false && document.cropRect == nil, "Invalid crop bounds produced an edit")
        try expect(
            document.annotations.isEmpty && document.canRedo && document.redoActionName == redoName,
            "Invalid crop bounds damaged committed annotations or Redo"
        )
        try expectRetinaSize(document, full.size)
    }
    let validDraft = CGRect(x: 63, y: 51, width: 211, height: 137)
    document.beginCrop()
    document.updateCropRect(validDraft)
    for rect in invalid {
        document.updateCropRect(rect)
        try expect(document.cropRect == validDraft, "Invalid crop bounds damaged an existing valid draft")
    }
    document.cancelCrop()
    try expectPixelRegion(pixels(document), from: originalPixels, rect: full, "Invalid crop bounds changed source pixels")
    document.redo()
    try expect(document.annotations.count == 1, "Invalid crop attempts consumed the prior redo operation")

    for (input, expected) in [
        (CGRect(x: 237.4, y: 180.8, width: -200.2, height: -119.1), CGRect(x: 37, y: 61, width: 201, height: 120)),
        (CGRect(x: -12.4, y: 377.3, width: 61.6, height: 44.1), CGRect(x: 0, y: 377, width: 50, height: 23)),
        (CGRect(x: 639.8, y: 399.6, width: 0.1, height: 0.2), CGRect(x: 639, y: 399, width: 1, height: 1)),
        (CGRect(x: 319, y: 199, width: 1, height: 1), CGRect(x: 319, y: 199, width: 1, height: 1)),
        (CGRect(x: 11.2, y: 17.4, width: 0.15, height: 1.2), CGRect(x: 11, y: 17, width: 1, height: 2)),
    ] {
        let bounded = EditorDocument(baseImage: makeImage())
        let sourceBase = try decodedPixels(bounded.baseImage)
        let sourceExport = try pixels(bounded)
        bounded.beginCrop()
        bounded.updateCropRect(input)
        try expect(bounded.cropRect == expected, "Crop did not standardize, clamp, and snap outwards to whole pixels")
        try expect(bounded.applyCrop(), "A valid tiny/fractional crop was rejected")
        try expectRetinaSize(bounded, expected.size)
        try expectPixelRegion(decodedPixels(bounded.baseImage), from: sourceBase, rect: expected, "Tiny/fractional base crop")
        try expectPixelRegion(pixels(bounded), from: sourceExport, rect: expected, "Tiny/fractional exported crop")
        bounded.undo()
        try expectRetinaSize(bounded, full.size)
        try expect(bounded.canUndo == false && bounded.redoActionName == "Crop", "Tiny crop did not create exactly one history entry")
        bounded.redo()
        try expectPixelRegion(pixels(bounded), from: sourceExport, rect: expected, "Tiny/fractional crop redo")
    }
}

@MainActor
private func cropNativeGraphicsContexts() throws {
    let document = EditorDocument(baseImage: makeImage())
    let originalBase = try pixels(document)

    func checkImage(
        _ image: NSImage, source: NSBitmapImageRep, region: CGRect,
        in context: NSGraphicsContext, label: String
    ) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: context, hints: nil) else {
            throw Failure.check("\(label): could not obtain raster pixels")
        }
        try expectPixelRegion(
            NSBitmapImageRep(cgImage: cgImage), from: source, rect: region, label
        )
    }

    let contexts = [CGFloat(1), CGFloat(2)].map { scale -> (NSBitmapImageRep, NSGraphicsContext) in
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(64 * scale), pixelsHigh: Int(64 * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        bitmap.size = CGSize(width: 64, height: 64)
        return (bitmap, NSGraphicsContext(bitmapImageRep: bitmap)!)
    }
    let full = CGRect(x: 0, y: 0, width: 640, height: 400)
    for (index, (_, context)) in contexts.enumerated() {
        try checkImage(
            document.baseImage, source: originalBase, region: full,
            in: context, label: "Initial Retina image in \(index + 1)x context"
        )
    }

    rectangle(document)
    let originalComposite = try pixels(document)
    let crop = CGRect(x: 73, y: 41, width: 491, height: 307)
    document.beginCrop()
    document.updateCropRect(crop)
    try expect(document.applyCrop(), "Could not apply the odd-pixel Retina crop")
    guard let composite = document.renderCompositeImage() else {
        throw Failure.check("Could not render the odd-pixel crop")
    }
    for (index, (_, context)) in contexts.enumerated() {
        try checkImage(
            document.baseImage, source: originalBase, region: crop,
            in: context, label: "Cropped base in \(index + 1)x context"
        )
        try checkImage(
            composite, source: originalComposite, region: crop,
            in: context, label: "Cropped composite in \(index + 1)x context"
        )
    }
    document.undo()
    for (index, (_, context)) in contexts.enumerated() {
        try checkImage(
            document.baseImage, source: originalBase, region: full,
            in: context, label: "Restored base in \(index + 1)x context"
        )
    }
    document.redo()
    try expectRetinaSize(document, crop.size)
}

@main
private struct EditorAnnotationTests {
    @MainActor
    static func main() {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "background": try background()
            case "partial": try partial()
            case "outside-path": try outsidePath()
            case "ordering": try ordering()
            case "cancellation": try cancellation()
            case "annotation-types": try annotationTypes()
            case "text-editing": try textEditingLifecycle()
            case "text-layout-export": try textLayoutAndExport()
            case "text-move-resize": try textMoveAndWidthResize()
            case "text-retina-edges": try textRetinaAndImageEdges()
            case "creation-history": try creationHistory()
            case "object-move-resize-history": try objectMoveResizeHistory()
            case "arrow-endpoints-degenerate": try arrowEndpointsAndDegenerateGeometry()
            case "ink-hit-mask-order": try inkHitTestingAndMaskOrdering()
            case "selected-style-history": try selectedStyleHistory()
            case "duplicate-delete-history": try duplicateDeleteHistory()
            case "redo-boundaries-isolation": try redoBoundariesAndIsolation()
            case "file-export": try fileExport()
            case "crop-retina-pixels": try cropRetinaPixels()
            case "crop-annotations-masks": try cropAnnotationsAndMasks()
            case "crop-interleaved-history": try cropInterleavedHistory()
            case "crop-draft-boundaries": try cropDraftBoundaries()
            case "crop-draft-bounds": try cropDraftBounds()
            case "crop-native-contexts": try cropNativeGraphicsContexts()
            default: throw Failure.check("Unknown test scenario")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
