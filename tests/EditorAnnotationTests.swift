import AppKit

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
    document.activateTool(.rectangle)
    document.shapeStyle = .filled
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
    document.shapeStyle = .filled
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
    document.undoLastAnnotation()
    try same(try pixels(document), erased, at: point, "Undo of later drawing changed the erasure")
    document.undoLastAnnotation()
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
    document.undoLastAnnotation()
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
    document.undoLastAnnotation()
    try same(try pixels(document), before, at: center, "Undo did not restore a click erasure")
}

@MainActor
private func annotationTypes() throws {
    for kind in ["pen", "arrow", "rectangle-outline", "rectangle-filled", "ellipse-outline", "ellipse-filled", "blur", "text"] {
        let document = EditorDocument(baseImage: makeImage())
        let original = try pixels(document)
        document.lineWidth = 16
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
            document.shapeStyle = kind.hasSuffix("filled") ? .filled : .outline
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
        document.undoLastAnnotation()
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
    let hit = CGPoint(x: origin.x + 20, y: origin.y + 14)
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
    document.undoLastAnnotation()
    let restored = try textAnnotation(document, id: original.id)
    try expect(document.pendingTextInsertion == nil, "Undo did not cancel text editing")
    try expect(document.annotations.map(\.id) == originalOrder, "Cancelling text editing removed or reordered an object")
    try expect(
        restored.text == originalText && restored.color == original.color
            && restored.font == original.font && restored.fontSize == original.fontSize,
        "Cancelling text editing leaked uncommitted content or typography into the object"
    )
    try expect(try changedPixels(pixels(document), from: beforeEditing).isEmpty, "Cancelling editing changed exported pixels")

    document.activateTool(.move)
    document.beginInteraction(at: hit)
    document.endInteraction(at: hit)
    try expect(document.beginEditingSelectedText(), "Selected text could not be reopened")
    try expect(document.deleteSelectedText() == false, "Object deletion consumed a native text-editing session")
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
            default: throw Failure.check("Unknown test scenario")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
