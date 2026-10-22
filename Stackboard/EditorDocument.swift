import AppKit
import Combine
import CoreImage

enum EditorTool: String, CaseIterable, Identifiable {
    case move
    case pen
    case eraser
    case arrow
    case rectangle
    case ellipse
    case blur
    case text

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .move: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .eraser: return "eraser"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .blur: return "drop.fill"
        case .text: return "textformat"
        }
    }

    var title: String {
        rawValue.capitalized
    }
}

enum EditorTextFont: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case monospaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .rounded:
            return "Rounded"
        case .serif:
            return "Serif"
        case .monospaced:
            return "Mono"
        }
    }

    func nsFont(size: CGFloat) -> NSFont {
        switch self {
        case .system:
            return .systemFont(ofSize: size, weight: .bold)
        case .rounded:
            if let descriptor = NSFont.systemFont(ofSize: size, weight: .bold)
                .fontDescriptor
                .withDesign(.rounded) {
                return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: .bold)
            }
            return .systemFont(ofSize: size, weight: .bold)
        case .serif:
            return NSFont(name: "Georgia-Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold)
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: .bold)
        }
    }
}

struct EditorColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var nsColor: NSColor {
        NSColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    static let yellow = EditorColor(red: 1, green: 0.84, blue: 0.18, alpha: 1)
    static let red = EditorColor(red: 1, green: 0.31, blue: 0.26, alpha: 1)
    static let blue = EditorColor(red: 0.19, green: 0.53, blue: 1, alpha: 1)
    static let green = EditorColor(red: 0.16, green: 0.72, blue: 0.39, alpha: 1)
    static let white = EditorColor(red: 1, green: 1, blue: 1, alpha: 1)
}

struct EditorStroke {
    let id = UUID()
    var points: [CGPoint]
    var color: EditorColor
    var lineWidth: CGFloat
}

struct EditorEraserStroke {
    let id = UUID()
    var points: [CGPoint]
    var lineWidth: CGFloat

    /// Filled brush footprint in image-pixel coordinates with a top-left origin.
    var path: CGPath {
        guard let first = points.first else {
            return CGMutablePath()
        }

        if points.count == 1 {
            let radius = lineWidth / 2
            return CGPath(
                ellipseIn: CGRect(
                    x: first.x - radius,
                    y: first.y - radius,
                    width: lineWidth,
                    height: lineWidth
                ),
                transform: nil
            )
        }

        let centerline = CGMutablePath()
        centerline.move(to: first)
        for point in points.dropFirst() {
            centerline.addLine(to: point)
        }
        return centerline.copy(
            strokingWithWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
    }
}

struct EditorArrow {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var color: EditorColor
    var lineWidth: CGFloat
}

enum EditorShapeKind {
    case rectangle
    case ellipse
}

enum EditorShapeStyle: String, CaseIterable, Identifiable {
    case outline
    case filled

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

struct EditorShape {
    let id = UUID()
    var kind: EditorShapeKind
    var rect: CGRect
    var color: EditorColor
    var lineWidth: CGFloat
    var style: EditorShapeStyle

    var path: CGPath {
        switch kind {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        }
    }
}

struct EditorBlur {
    let id = UUID()
    var rect: CGRect
    var radius: Double
}

struct EditorTextAnnotation: Equatable {
    let id = UUID()
    var text: String
    var origin: CGPoint
    var color: EditorColor
    var fontSize: CGFloat
    var font: EditorTextFont
    var width: CGFloat = 480
}

enum EditorAnnotation: Identifiable {
    case stroke(EditorStroke)
    case eraser(EditorEraserStroke)
    case arrow(EditorArrow)
    case shape(EditorShape)
    case blur(EditorBlur)
    case text(EditorTextAnnotation)

    var id: UUID {
        switch self {
        case let .stroke(stroke): return stroke.id
        case let .eraser(eraser): return eraser.id
        case let .arrow(arrow): return arrow.id
        case let .shape(shape): return shape.id
        case let .blur(blur): return blur.id
        case let .text(text): return text.id
        }
    }
}

enum EditableAnnotationKind: Equatable {
    case blur
    case text
}

struct EditorSelection: Equatable {
    let id: UUID
    let kind: EditableAnnotationKind
}

struct EditorSelectionOverlay: Equatable {
    let kind: EditableAnnotationKind
    let rect: CGRect
    let handleRect: CGRect
}

struct PendingTextInsertion: Identifiable, Equatable {
    var annotationID: UUID? = nil
    let id = UUID()
    var origin: CGPoint
    var text: String
    var color: EditorColor
    var fontSize: CGFloat
    var font: EditorTextFont
    var width: CGFloat = 480
}

private enum EditorCanvasInteractionState {
    case none
    case drawing
    case erasing
    case drawingShape(anchor: CGPoint)
    case movingBlur(id: UUID, pointerOffset: CGSize, size: CGSize)
    case resizingBlur(id: UUID, anchor: CGPoint)
    case movingText(id: UUID, pointerOffset: CGSize, size: CGSize)
    case resizingText(id: UUID, origin: CGPoint, pointerOffset: CGFloat)
}

/// TextKit supplies the same wrapping, line metrics and glyph positions for input and output.
@MainActor
final class EditorTextLayout {
    let textStorage: NSTextStorage
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer
    let size: CGSize

    init(text: String, width: CGFloat, font: EditorTextFont, fontSize: CGFloat, color: EditorColor) {
        textStorage = NSTextStorage(
            string: text,
            attributes: Self.attributes(font: font, fontSize: fontSize, color: color)
        )
        layoutManager = NSLayoutManager()
        textContainer = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let lineHeight = layoutManager.defaultLineHeight(for: font.nsFont(size: fontSize))
        size = CGSize(
            width: max(width, 1),
            height: ceil(max(lineHeight, usedRect.maxY, layoutManager.extraLineFragmentRect.maxY))
        )
    }

    convenience init(annotation: EditorTextAnnotation) {
        self.init(
            text: annotation.text, width: annotation.width,
            font: annotation.font, fontSize: annotation.fontSize, color: annotation.color
        )
    }

    static func attributes(font: EditorTextFont, fontSize: CGFloat, color: EditorColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: font.nsFont(size: fontSize),
            .foregroundColor: color.nsColor,
            .paragraphStyle: paragraph
        ]
    }

    /// The caller provides a top-left, flipped graphics context in source-image pixels.
    func draw(at origin: CGPoint) {
        let range = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: range, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
    }
}

@MainActor
final class EditorDocument: ObservableObject {
    let baseImage: NSImage
    let pixelSize: CGSize

    @Published var selectedTool: EditorTool = .pen
    @Published private(set) var selectedColor: EditorColor = .red
    /// Stored in image pixels; preview scales this width with the canvas, just like export.
    @Published var lineWidth: Double = 6
    @Published var eraserWidth: Double = 32
    @Published var shapeStyle: EditorShapeStyle = .outline
    @Published private(set) var blurRadius: Double = 14
    @Published private(set) var textFont: EditorTextFont = .system
    @Published private(set) var textFontSize: Double = 24
    @Published private(set) var annotations: [EditorAnnotation] = []
    @Published private(set) var activeStroke: EditorStroke?
    @Published private(set) var activeEraser: EditorEraserStroke?
    @Published private(set) var activeArrow: EditorArrow?
    @Published private(set) var activeShape: EditorShape?
    @Published private(set) var activeBlur: EditorBlur? {
        didSet {
            if let oldValue,
               oldValue.id != activeBlur?.id,
               annotations.contains(where: { $0.id == oldValue.id }) == false {
                blurImageCache.removeValue(forKey: oldValue.id)
            }
        }
    }
    @Published private(set) var selectedAnnotation: EditorSelection?
    @Published private(set) var pendingTextInsertion: PendingTextInsertion?

    private var interactionState: EditorCanvasInteractionState = .none
    private let baseCIImage: CIImage?
    private static let ciContext = CIContext()
    private var blurImageCache: [UUID: CachedBlurImage] = [:]
    private var textLayoutCache: [UUID: (annotation: EditorTextAnnotation, layout: EditorTextLayout)] = [:]
    private var pendingLayoutCache: (session: PendingTextInsertion, layout: EditorTextLayout)?

    private struct CachedBlurImage {
        let rect: CGRect
        let radius: Double
        let image: NSImage
    }

    init(baseImage: NSImage) {
        self.baseImage = baseImage
        let cgImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        pixelSize = cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? baseImage.size
        baseCIImage = cgImage.map { CIImage(cgImage: $0) }
        textFontSize = 24 * max(pixelSize.width / max(baseImage.size.width, 1), 1)
    }

    func activateTool(_ tool: EditorTool) {
        guard selectedTool != tool else {
            return
        }

        if tool != .text {
            _ = commitPendingTextInsertion()
        }

        if case .erasing = interactionState {
            activeEraser = nil
            interactionState = .none
        }

        if case .drawingShape = interactionState {
            activeShape = nil
            interactionState = .none
        }

        if tool == .move {
            activeStroke = nil
            activeArrow = nil
            activeBlur = nil
            interactionState = .none
        }

        selectedTool = tool
    }

    func beginInteraction(at point: CGPoint) {
        if selectedTool == .eraser,
           CGRect(origin: .zero, size: pixelSize).contains(point) == false {
            return
        }

        commitPendingTextInsertion()

        if selectedTool == .move {
            if let selection = selectedAnnotation,
               resizeHandleContains(point, for: selection) {
                beginResizeInteraction(for: selection, at: point)
                return
            }

            if let hitSelection = annotationSelection(at: point) {
                select(hitSelection)
                beginMoveInteraction(for: hitSelection, at: point)
                return
            }

            selectedAnnotation = nil
            interactionState = .none
            return
        }

        selectedAnnotation = nil

        switch selectedTool {
        case .move:
            break
        case .pen:
            activeStroke = EditorStroke(
                points: [point],
                color: selectedColor,
                lineWidth: lineWidth
            )
            interactionState = .drawing
        case .eraser:
            activeEraser = EditorEraserStroke(points: [point], lineWidth: CGFloat(eraserWidth))
            interactionState = .erasing
        case .arrow:
            activeArrow = EditorArrow(
                start: point,
                end: point,
                color: selectedColor,
                lineWidth: lineWidth
            )
            interactionState = .drawing
        case .rectangle, .ellipse:
            let anchor = clamped(point: point)
            activeShape = EditorShape(
                kind: selectedTool == .rectangle ? .rectangle : .ellipse,
                rect: CGRect(origin: anchor, size: .zero),
                color: selectedColor,
                lineWidth: lineWidth,
                style: shapeStyle
            )
            interactionState = .drawingShape(anchor: anchor)
        case .blur:
            activeBlur = EditorBlur(rect: CGRect(origin: point, size: .zero), radius: blurRadius)
            interactionState = .drawing
        case .text:
            if beginEditingText(at: point) == false {
                startPendingTextInsertion(at: point)
            }
            interactionState = .none
        }
    }

    func updateInteraction(at point: CGPoint, constrainProportions: Bool = false) {
        switch interactionState {
        case .drawing:
            updateDrawingInteraction(at: point)
        case .erasing:
            updateErasingInteraction(at: point)
        case let .drawingShape(anchor):
            updateShapeInteraction(from: anchor, to: point, constrainProportions: constrainProportions)
        case let .movingBlur(id, pointerOffset, size):
            updateBlurPosition(id: id, origin: CGPoint(x: point.x - pointerOffset.width, y: point.y - pointerOffset.height), size: size)
        case let .resizingBlur(id, anchor):
            updateBlurRect(id: id, rect: clampedRect(normalizedRect(from: anchor, to: clamped(point: point))))
        case let .movingText(id, pointerOffset, size):
            updateTextOrigin(id: id, origin: CGPoint(x: point.x - pointerOffset.width, y: point.y - pointerOffset.height), size: size)
        case let .resizingText(id, origin, pointerOffset):
            updateText(id) { text in
                text.width = min(max(point.x - origin.x - pointerOffset, min(48, pixelSize.width)), pixelSize.width - origin.x)
            }
        case .none:
            break
        }
    }

    func endInteraction(at point: CGPoint, constrainProportions: Bool = false) {
        defer {
            interactionState = .none
        }

        switch interactionState {
        case .drawing:
            finalizeDrawingInteraction(at: point)
        case .erasing:
            updateErasingInteraction(at: point)
            if let activeEraser {
                annotations.append(.eraser(activeEraser))
            }
            activeEraser = nil
        case let .drawingShape(anchor):
            updateShapeInteraction(from: anchor, to: point, constrainProportions: constrainProportions)
            if let activeShape, activeShape.rect.width > 1, activeShape.rect.height > 1 {
                annotations.append(.shape(activeShape))
            }
            activeShape = nil
        case .movingText, .resizingText:
            updateInteraction(at: point)
        case .movingBlur, .resizingBlur, .none:
            break
        }
    }

    func undoLastAnnotation() {
        if activeEraser != nil {
            activeEraser = nil
            interactionState = .none
            return
        }

        if pendingTextInsertion != nil {
            pendingTextInsertion = nil
            pendingLayoutCache = nil
            if let selectedAnnotation {
                select(selectedAnnotation)
            }
            return
        }

        if let removed = annotations.popLast() {
            blurImageCache.removeValue(forKey: removed.id)
            textLayoutCache.removeValue(forKey: removed.id)
            if removed.id == selectedAnnotation?.id {
                selectedAnnotation = nil
            }
        }
    }

    func applySelectedColor(_ color: EditorColor) {
        selectedColor = color

        if var pendingTextInsertion {
            pendingTextInsertion.color = color
            self.pendingTextInsertion = pendingTextInsertion
            return
        }

        guard let selectedAnnotation else {
            return
        }

        updateText(selectedAnnotation.id) { annotation in
            annotation.color = color
        }
    }

    func setBlurControlValue(_ value: Double) {
        blurRadius = value

        guard let selectedAnnotation, selectedAnnotation.kind == .blur else {
            return
        }

        updateBlur(selectedAnnotation.id) { blur in
            blur.radius = value
        }
    }

    func setTextSizeControlValue(_ value: Double) {
        let value = min(max(value, 8), 256)
        textFontSize = value

        if var pendingTextInsertion {
            pendingTextInsertion.fontSize = CGFloat(value)
            self.pendingTextInsertion = pendingTextInsertion
            return
        }

        guard let selectedAnnotation, selectedAnnotation.kind == .text else {
            return
        }

        updateText(selectedAnnotation.id) { annotation in
            annotation.fontSize = CGFloat(value)
        }
    }

    func setTextFont(_ font: EditorTextFont) {
        textFont = font

        if var pendingTextInsertion {
            pendingTextInsertion.font = font
            self.pendingTextInsertion = pendingTextInsertion
            return
        }

        guard let selectedAnnotation, selectedAnnotation.kind == .text else {
            return
        }

        updateText(selectedAnnotation.id) { annotation in
            annotation.font = font
        }
    }

    func setPendingText(_ text: String) {
        guard var pendingTextInsertion else {
            return
        }
        pendingTextInsertion.text = text
        self.pendingTextInsertion = pendingTextInsertion
    }

    @discardableResult
    func commitPendingTextInsertion() -> Bool {
        guard let pending = pendingTextInsertion else {
            return false
        }
        pendingTextInsertion = nil
        pendingLayoutCache = nil
        let isBlank = pending.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if let id = pending.annotationID {
            guard let index = annotations.firstIndex(where: { $0.id == id }),
                  case var .text(annotation) = annotations[index] else {
                return false
            }
            if isBlank {
                annotations.remove(at: index)
                textLayoutCache.removeValue(forKey: id)
                selectedAnnotation = nil
            } else {
                annotation.text = pending.text
                annotation.origin = pending.origin
                annotation.color = pending.color
                annotation.fontSize = pending.fontSize
                annotation.font = pending.font
                annotation.width = pending.width
                annotations[index] = .text(annotation)
                select(EditorSelection(id: id, kind: .text))
            }
            return true
        }

        guard isBlank == false else {
            return false
        }
        let annotation = EditorTextAnnotation(
            text: pending.text, origin: pending.origin, color: pending.color,
            fontSize: pending.fontSize, font: pending.font, width: pending.width
        )
        annotations.append(.text(annotation))
        select(EditorSelection(id: annotation.id, kind: .text))
        return true
    }

    @discardableResult
    func beginEditingText(at point: CGPoint) -> Bool {
        guard let selection = annotationSelection(at: point), selection.kind == .text else {
            return false
        }
        select(selection)
        return beginEditingSelectedText()
    }

    @discardableResult
    func beginEditingSelectedText() -> Bool {
        guard let annotation = selectedText else {
            return false
        }
        if pendingTextInsertion?.annotationID == annotation.id {
            return true
        }
        commitPendingTextInsertion()
        select(EditorSelection(id: annotation.id, kind: .text))
        pendingTextInsertion = PendingTextInsertion(
            annotationID: annotation.id,
            origin: annotation.origin, text: annotation.text, color: annotation.color,
            fontSize: annotation.fontSize, font: annotation.font, width: annotation.width
        )
        interactionState = .none
        return true
    }

    @discardableResult
    func deleteSelectedText() -> Bool {
        guard pendingTextInsertion == nil, let annotation = selectedText else {
            return false
        }
        annotations.removeAll { $0.id == annotation.id }
        textLayoutCache.removeValue(forKey: annotation.id)
        selectedAnnotation = nil
        return true
    }

    func textLayout(for annotation: EditorTextAnnotation) -> EditorTextLayout {
        if let cached = textLayoutCache[annotation.id],
           cached.annotation.text == annotation.text, cached.annotation.width == annotation.width,
           cached.annotation.font == annotation.font, cached.annotation.fontSize == annotation.fontSize,
           cached.annotation.color == annotation.color {
            return cached.layout
        }
        let layout = EditorTextLayout(annotation: annotation)
        textLayoutCache[annotation.id] = (annotation, layout)
        return layout
    }

    var pendingTextBounds: CGRect? {
        guard let pending = pendingTextInsertion else {
            return nil
        }
        let layout: EditorTextLayout
        if let cached = pendingLayoutCache, cached.session == pending {
            layout = cached.layout
        } else {
            layout = EditorTextLayout(
                text: pending.text, width: pending.width, font: pending.font,
                fontSize: pending.fontSize, color: pending.color
            )
            pendingLayoutCache = (pending, layout)
        }
        return CGRect(origin: pending.origin, size: layout.size)
    }

    func renderCompositeImage() -> NSImage? {
        commitPendingTextInsertion()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(pixelSize.width.rounded()), 1),
            pixelsHigh: max(Int(pixelSize.height.rounded()), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = baseImage.size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high

        let scaleX = baseImage.size.width / max(pixelSize.width, 1)
        let scaleY = baseImage.size.height / max(pixelSize.height, 1)

        graphicsContext.cgContext.saveGState()
        graphicsContext.cgContext.scaleBy(x: scaleX, y: scaleY)
        baseImage.draw(in: CGRect(origin: .zero, size: pixelSize))

        let isolateAnnotations = hasEraser
        if isolateAnnotations {
            graphicsContext.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        }

        for annotation in annotations {
            switch annotation {
            case let .stroke(stroke):
                drawStroke(stroke)
            case let .eraser(eraser):
                drawEraser(eraser)
            case let .arrow(arrow):
                drawArrow(arrow)
            case let .shape(shape):
                drawShape(shape)
            case let .blur(blur):
                drawBlur(blur)
            case let .text(text):
                drawText(text)
            }
        }
        if let activeEraser {
            drawEraser(activeEraser)
        }
        if isolateAnnotations {
            graphicsContext.cgContext.endTransparencyLayer()
        }
        graphicsContext.cgContext.restoreGState()

        let image = NSImage(size: baseImage.size)
        image.addRepresentation(bitmap)
        return image
    }

    var committedAndActiveAnnotations: [EditorAnnotation] {
        var result = annotations
        if let editingID = pendingTextInsertion?.annotationID {
            result.removeAll { $0.id == editingID }
        }
        if let activeStroke {
            result.append(.stroke(activeStroke))
        }
        if let activeArrow {
            result.append(.arrow(activeArrow))
        }
        if let activeShape {
            result.append(.shape(activeShape))
        }
        if let activeBlur {
            result.append(.blur(activeBlur))
        }
        return result
    }

    var hasEraser: Bool {
        activeEraser != nil || annotations.contains {
            if case .eraser = $0 {
                return true
            }
            return false
        }
    }

    var currentBlurControlValue: Double {
        if let selectedBlur = selectedBlur {
            return selectedBlur.radius
        }
        return blurRadius
    }

    var currentTextSizeControlValue: Double {
        if let pendingTextInsertion {
            return Double(pendingTextInsertion.fontSize)
        }
        if let selectedText = selectedText {
            return Double(selectedText.fontSize)
        }
        return textFontSize
    }

    var currentTextFont: EditorTextFont {
        if let pendingTextInsertion {
            return pendingTextInsertion.font
        }
        if let selectedText = selectedText {
            return selectedText.font
        }
        return textFont
    }

    var selectionOverlay: EditorSelectionOverlay? {
        guard pendingTextInsertion == nil, let selectedAnnotation else {
            return nil
        }

        switch selectedAnnotation.kind {
        case .blur:
            guard let blur = selectedBlur else {
                return nil
            }
            return EditorSelectionOverlay(
                kind: .blur,
                rect: blur.rect,
                handleRect: resizeHandleRect(for: blur.rect)
            )
        case .text:
            guard let text = selectedText else {
                return nil
            }
            let rect = textBounds(for: text)
            return EditorSelectionOverlay(
                kind: .text,
                rect: rect,
                handleRect: textResizeHandleRect(for: rect)
            )
        }
    }

    private var selectedBlur: EditorBlur? {
        guard let selectedAnnotation, selectedAnnotation.kind == .blur else {
            return nil
        }
        return blurAnnotation(for: selectedAnnotation.id)
    }

    private var selectedText: EditorTextAnnotation? {
        guard let selectedAnnotation, selectedAnnotation.kind == .text else {
            return nil
        }
        return textAnnotation(for: selectedAnnotation.id)
    }

    private func updateErasingInteraction(at point: CGPoint) {
        guard var activeEraser, activeEraser.points.last != point else {
            return
        }

        activeEraser.points.append(point)
        self.activeEraser = activeEraser
    }

    private func updateDrawingInteraction(at point: CGPoint) {
        switch selectedTool {
        case .move:
            break
        case .pen:
            guard var activeStroke else {
                return
            }
            activeStroke.points.append(point)
            self.activeStroke = activeStroke
        case .arrow:
            guard var activeArrow else {
                return
            }
            activeArrow.end = point
            self.activeArrow = activeArrow
        case .blur:
            guard let startPoint = activeBlur?.rect.origin else {
                return
            }
            activeBlur = EditorBlur(
                rect: normalizedRect(from: startPoint, to: point),
                radius: blurRadius
            )
        case .eraser, .rectangle, .ellipse, .text:
            break
        }
    }

    private func updateShapeInteraction(from anchor: CGPoint, to point: CGPoint, constrainProportions: Bool) {
        guard var activeShape else {
            return
        }

        if constrainProportions {
            let deltaX = point.x - anchor.x
            let deltaY = point.y - anchor.y
            let directionX: CGFloat = deltaX < 0 ? -1 : 1
            let directionY: CGFloat = deltaY < 0 ? -1 : 1
            let availableWidth = directionX < 0 ? anchor.x : pixelSize.width - anchor.x
            let availableHeight = directionY < 0 ? anchor.y : pixelSize.height - anchor.y
            let side = min(max(abs(deltaX), abs(deltaY)), availableWidth, availableHeight)
            let end = CGPoint(x: anchor.x + directionX * side, y: anchor.y + directionY * side)
            activeShape.rect = normalizedRect(from: anchor, to: end)
        } else {
            activeShape.rect = normalizedRect(from: anchor, to: clamped(point: point))
        }

        self.activeShape = activeShape
    }

    private func finalizeDrawingInteraction(at point: CGPoint) {
        switch selectedTool {
        case .move:
            break
        case .pen:
            guard var activeStroke else {
                return
            }

            activeStroke.points.append(point)
            if activeStroke.points.count > 1 {
                annotations.append(.stroke(activeStroke))
            }
            self.activeStroke = nil
        case .arrow:
            guard var activeArrow else {
                return
            }

            activeArrow.end = point
            if hypot(activeArrow.end.x - activeArrow.start.x, activeArrow.end.y - activeArrow.start.y) > 6 {
                annotations.append(.arrow(activeArrow))
            }
            self.activeArrow = nil
        case .blur:
            guard let activeBlur else {
                return
            }

            if activeBlur.rect.width > 10, activeBlur.rect.height > 10 {
                annotations.append(.blur(activeBlur))
                select(EditorSelection(id: activeBlur.id, kind: .blur))
            }
            self.activeBlur = nil
        case .eraser, .rectangle, .ellipse, .text:
            break
        }
    }

    private func startPendingTextInsertion(at point: CGPoint) {
        let minimumWidth = min(CGFloat(48), pixelSize.width)
        let font = textFont.nsFont(size: CGFloat(textFontSize))
        let lineHeight = font.ascender - font.descender + font.leading
        let origin = clamped(origin: point, size: CGSize(width: minimumWidth, height: ceil(lineHeight)))
        pendingTextInsertion = PendingTextInsertion(
            origin: origin, text: "", color: selectedColor,
            fontSize: CGFloat(textFontSize), font: textFont,
            width: min(480, pixelSize.width - origin.x)
        )
    }

    private func select(_ selection: EditorSelection) {
        selectedAnnotation = selection

        switch selection.kind {
        case .blur:
            if let blur = blurAnnotation(for: selection.id) {
                blurRadius = blur.radius
            }
        case .text:
            if let text = textAnnotation(for: selection.id) {
                selectedColor = text.color
                textFont = text.font
                textFontSize = Double(text.fontSize)
            }
        }
    }

    func handleEscape() -> Bool {
        if pendingTextInsertion != nil {
            _ = commitPendingTextInsertion()
            return true
        }

        if activeStroke != nil || activeEraser != nil || activeArrow != nil || activeShape != nil || activeBlur != nil {
            activeStroke = nil
            activeEraser = nil
            activeArrow = nil
            activeShape = nil
            activeBlur = nil
            interactionState = .none
            return true
        }

        if selectedAnnotation != nil {
            selectedAnnotation = nil
            return true
        }

        return false
    }

    private func beginMoveInteraction(for selection: EditorSelection, at point: CGPoint) {
        switch selection.kind {
        case .blur:
            guard let blur = blurAnnotation(for: selection.id) else {
                return
            }

            interactionState = .movingBlur(
                id: blur.id,
                pointerOffset: CGSize(
                    width: point.x - blur.rect.minX,
                    height: point.y - blur.rect.minY
                ),
                size: blur.rect.size
            )
        case .text:
            guard let text = textAnnotation(for: selection.id) else {
                return
            }

            let bounds = textBounds(for: text)
            interactionState = .movingText(
                id: text.id,
                pointerOffset: CGSize(
                    width: point.x - text.origin.x,
                    height: point.y - text.origin.y
                ),
                size: bounds.size
            )
        }
    }

    private func beginResizeInteraction(for selection: EditorSelection, at point: CGPoint) {
        switch selection.kind {
        case .blur:
            guard let blur = blurAnnotation(for: selection.id) else {
                return
            }
            interactionState = .resizingBlur(id: blur.id, anchor: blur.rect.origin)
        case .text:
            guard let text = textAnnotation(for: selection.id) else {
                return
            }
            interactionState = .resizingText(
                id: text.id,
                origin: text.origin,
                pointerOffset: point.x - text.origin.x - text.width
            )
        }
    }

    private func annotationSelection(at point: CGPoint) -> EditorSelection? {
        for annotation in annotations.reversed() {
            switch annotation {
            case let .blur(blur):
                if blur.rect.insetBy(dx: -14, dy: -14).contains(point) {
                    return EditorSelection(id: blur.id, kind: .blur)
                }
            case let .text(text):
                if textBounds(for: text).insetBy(dx: -12, dy: -12).contains(point) {
                    return EditorSelection(id: text.id, kind: .text)
                }
            case .stroke, .eraser, .arrow, .shape:
                continue
            }
        }

        return nil
    }

    private func resizeHandleContains(_ point: CGPoint, for selection: EditorSelection) -> Bool {
        guard let overlay = selectionOverlay, overlay.kind == selection.kind else {
            return false
        }

        return overlay.handleRect.insetBy(dx: -16, dy: -16).contains(point)
    }

    private func blurAnnotation(for id: UUID) -> EditorBlur? {
        for annotation in annotations {
            if case let .blur(blur) = annotation, blur.id == id {
                return blur
            }
        }
        return nil
    }

    private func textAnnotation(for id: UUID) -> EditorTextAnnotation? {
        for annotation in annotations {
            if case let .text(text) = annotation, text.id == id {
                return text
            }
        }
        return nil
    }

    private func updateBlur(_ id: UUID, mutation: (inout EditorBlur) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }),
              case var .blur(blur) = annotations[index] else {
            return
        }

        mutation(&blur)
        annotations[index] = .blur(blur)
    }

    private func updateText(_ id: UUID, mutation: (inout EditorTextAnnotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }),
              case var .text(text) = annotations[index] else {
            return
        }

        mutation(&text)
        annotations[index] = .text(text)
    }

    private func updateBlurPosition(id: UUID, origin: CGPoint, size: CGSize) {
        updateBlur(id) { blur in
            blur.rect.origin = clamped(origin: origin, size: size)
        }
    }

    private func updateBlurRect(id: UUID, rect: CGRect) {
        updateBlur(id) { blur in
            blur.rect = rect
        }
    }

    private func updateTextOrigin(id: UUID, origin: CGPoint, size: CGSize) {
        updateText(id) { text in
            text.origin = clamped(origin: origin, size: size)
        }
    }

    private func updateTextFontSize(id: UUID, fontSize: CGFloat) {
        updateText(id) { text in
            text.fontSize = fontSize
        }
        textFontSize = Double(fontSize)
    }

    private func textBounds(for annotation: EditorTextAnnotation) -> CGRect {
        CGRect(origin: annotation.origin, size: textLayout(for: annotation).size)
    }

    private func textResizeHandleRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - 9, y: rect.midY - 9, width: 18, height: 18)
    }

    private func resizeHandleRect(for rect: CGRect) -> CGRect {
        let size: CGFloat = 18
        return CGRect(
            x: rect.maxX - size / 2,
            y: rect.maxY - size / 2,
            width: size,
            height: size
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func clamped(point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), pixelSize.width),
            y: min(max(point.y, 0), pixelSize.height)
        )
    }

    private func clamped(origin: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, 0), max(pixelSize.width - size.width, 0)),
            y: min(max(origin.y, 0), max(pixelSize.height - size.height, 0))
        )
    }

    private func clampedRect(_ rect: CGRect) -> CGRect {
        let limitedWidth = min(max(rect.width, 1), pixelSize.width)
        let limitedHeight = min(max(rect.height, 1), pixelSize.height)
        let origin = clamped(origin: rect.origin, size: CGSize(width: limitedWidth, height: limitedHeight))
        return CGRect(origin: origin, size: CGSize(width: limitedWidth, height: limitedHeight))
    }

    private func drawStroke(_ stroke: EditorStroke) {
        guard stroke.points.count > 1 else {
            return
        }

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = stroke.lineWidth

        let first = flip(point: stroke.points[0])
        path.move(to: first)
        for point in stroke.points.dropFirst() {
            path.line(to: flip(point: point))
        }

        stroke.color.nsColor.setStroke()
        path.stroke()
    }

    private func drawEraser(_ eraser: EditorEraserStroke) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: 1, y: -1)
        context.setBlendMode(.clear)
        context.addPath(eraser.path)
        context.fillPath()
    }

    private func drawArrow(_ arrow: EditorArrow) {
        let start = flip(point: arrow.start)
        let end = flip(point: arrow.end)

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = arrow.lineWidth
        path.move(to: start)
        path.line(to: end)
        arrow.color.nsColor.setStroke()
        path.stroke()

        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let angle = atan2(deltaY, deltaX)
        let headLength = max(arrow.lineWidth * 2.6, 18)
        let headAngle = CGFloat.pi / 7

        let left = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        let headPath = NSBezierPath()
        headPath.lineCapStyle = .round
        headPath.lineJoinStyle = .round
        headPath.lineWidth = arrow.lineWidth
        headPath.move(to: end)
        headPath.line(to: left)
        headPath.move(to: end)
        headPath.line(to: right)
        headPath.stroke()
    }

    private func drawShape(_ shape: EditorShape) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: 1, y: -1)
        context.addPath(shape.path)

        switch shape.style {
        case .outline:
            context.setStrokeColor(shape.color.nsColor.cgColor)
            context.setLineWidth(shape.lineWidth)
            context.setLineCap(.butt)
            context.setLineJoin(.miter)
            context.setMiterLimit(10)
            context.strokePath()
        case .filled:
            context.setFillColor(shape.color.nsColor.cgColor)
            context.fillPath()
        }
    }

    /// Preview and export share the same pixel-resolution patch and radius. As in export's
    /// annotation order, a blur replaces the captured region rather than blurring earlier marks.
    /// Cache each annotation's latest patch so drawing a pen never re-filters existing blurs.
    func blurImage(for blur: EditorBlur) -> NSImage? {
        if let cached = blurImageCache[blur.id],
           cached.rect == blur.rect,
           cached.radius == blur.radius {
            return cached.image
        }

        let ciRect = flip(rect: blur.rect).integral
        guard ciRect.isEmpty == false, let baseCIImage else {
            return nil
        }

        let cropped = baseCIImage
            .cropped(to: ciRect)
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: blur.radius]
            )
            .cropped(to: ciRect)

        guard let cgImage = Self.ciContext.createCGImage(cropped, from: ciRect) else {
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: blur.rect.size)
        blurImageCache[blur.id] = CachedBlurImage(rect: blur.rect, radius: blur.radius, image: image)
        return image
    }

    private func drawBlur(_ blur: EditorBlur) {
        blurImage(for: blur)?.draw(in: flip(rect: blur.rect))
    }

    private func drawText(_ text: EditorTextAnnotation) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        textLayout(for: text).draw(at: text.origin)
    }

    private func flip(point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: pixelSize.height - point.y)
    }

    private func flip(rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: pixelSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
