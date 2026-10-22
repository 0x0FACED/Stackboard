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
            default: throw Failure.check("Unknown test scenario")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
