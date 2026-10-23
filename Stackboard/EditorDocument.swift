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

struct EditorStroke: Equatable {
    var id = UUID()
    var points: [CGPoint]
    var color: EditorColor
    var lineWidth: CGFloat
}

struct EditorEraserStroke: Equatable {
    var id = UUID()
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

struct EditorArrow: Equatable {
    var id = UUID()
    var start: CGPoint
    var end: CGPoint
    var color: EditorColor
    var lineWidth: CGFloat
}

enum EditorShapeKind: Equatable {
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

struct EditorShape: Equatable {
    var id = UUID()
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

struct EditorBlur: Equatable {
    var id = UUID()
    var rect: CGRect
    var radius: Double
}

struct EditorTextAnnotation: Equatable {
    var id = UUID()
    var text: String
    var origin: CGPoint
    var color: EditorColor
    var fontSize: CGFloat
    var font: EditorTextFont
    var width: CGFloat = 480
}

enum EditorAnnotation: Identifiable, Equatable {
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
    case stroke
    case arrow
    case shape
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
    var secondaryHandleRect: CGRect? = nil
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
    case drawing(anchor: CGPoint)
    case erasing
    case drawingShape(anchor: CGPoint)
    case moving(original: EditorAnnotation, pointer: CGPoint, bounds: CGRect)
    case resizing(original: EditorAnnotation, bounds: CGRect, pointer: CGPoint)
    case resizingArrow(original: EditorArrow, isStart: Bool, pointer: CGPoint)
}

private struct EditorChangeBaseline {
    let annotation: EditorAnnotation
    let index: Int
    let selection: EditorSelection?
}

/// Ordinary operations retain only the affected object's before/after values.
private struct EditorAnnotationChange {
    let before: EditorAnnotation?
    let after: EditorAnnotation?
    let index: Int
    let selectionBefore: EditorSelection?
    let selectionAfter: EditorSelection?
    let name: String
}

/// Only a crop changes the image coordinate system and needs a canvas-wide history payload.
private struct EditorCropState {
    let baseImage: NSImage
    let pixelSize: CGSize
    let annotations: [EditorAnnotation]
    let selection: EditorSelection?
    let sourceOffset: CGPoint
}

private enum EditorHistoryEntry {
    case annotation(EditorAnnotationChange)
    case crop(before: EditorCropState, after: EditorCropState)

    var name: String {
        switch self {
        case let .annotation(change): return change.name
        case .crop: return "Crop"
        }
    }
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
    @Published private(set) var baseImage: NSImage
    @Published private(set) var pixelSize: CGSize
    /// An uncommitted crop in top-left current-image pixels.
    @Published private(set) var cropRect: CGRect?

    @Published var selectedTool: EditorTool = .pen
    @Published private(set) var selectedColor: EditorColor = .red
    /// Stored in image pixels; preview scales this width with the canvas, just like export.
    @Published private(set) var lineWidth: Double = 6
    @Published var eraserWidth: Double = 32
    @Published private(set) var shapeStyle: EditorShapeStyle = .outline
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
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoActionName = ""
    @Published private(set) var redoActionName = ""

    private var interactionState: EditorCanvasInteractionState = .none
    /// Keep the captured source intact so a crop never changes an existing blur's edge samples.
    private let sourceCGImage: CGImage?
    private let baseCIImage: CIImage?
    private var sourceOffset: CGPoint = .zero
    private static let ciContext = CIContext()
    private var blurImageCache: [UUID: CachedBlurImage] = [:]
    private var textLayoutCache: [UUID: (annotation: EditorTextAnnotation, layout: EditorTextLayout)] = [:]
    private var pendingLayoutCache: (session: PendingTextInsertion, layout: EditorTextLayout)?
    private var history: [EditorHistoryEntry] = []
    private var historyPosition = 0
    private var interactionBaseline: EditorChangeBaseline?
    private var styleBaseline: EditorChangeBaseline?

    private struct CachedBlurImage {
        let rect: CGRect
        let radius: Double
        let image: NSImage
    }

    init(baseImage: NSImage) {
        self.baseImage = baseImage
        let cgImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        pixelSize = cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? baseImage.size
        sourceCGImage = cgImage
        baseCIImage = cgImage.map { CIImage(cgImage: $0) }
        textFontSize = 24 * max(pixelSize.width / max(baseImage.size.width, 1), 1)
    }

    func activateTool(_ tool: EditorTool) {
        cancelCrop()
        guard selectedTool != tool else { return }
        endStyleEditing()
        commitPendingTextInsertion()
        cancelInteraction()
        selectedTool = tool
    }

    func beginCrop() {
        endStyleEditing()
        commitPendingTextInsertion()
        cancelInteraction()
        cropRect = CGRect(origin: .zero, size: pixelSize)
        updateHistoryAvailability()
    }

    func updateCropRect(_ rect: CGRect) {
        guard cropRect != nil, let rect = normalizedCropRect(rect) else { return }
        cropRect = rect
    }

    func cancelCrop() {
        guard cropRect != nil else { return }
        cropRect = nil
        updateHistoryAvailability()
    }

    @discardableResult
    func applyCrop() -> Bool {
        guard let draft = cropRect, let rect = normalizedCropRect(draft) else { return false }
        guard rect != CGRect(origin: .zero, size: pixelSize) else {
            cancelCrop()
            return false
        }
        let sourceRect = rect.offsetBy(dx: sourceOffset.x, dy: sourceOffset.y)
        guard let cropped = sourceCGImage?.cropping(to: sourceRect),
              cropped.width == Int(rect.width), cropped.height == Int(rect.height) else {
            return false
        }

        let before = cropState
        let image = NSImage(
            cgImage: cropped,
            size: CGSize(
                width: rect.width * baseImage.size.width / pixelSize.width,
                height: rect.height * baseImage.size.height / pixelSize.height
            )
        )
        let delta = CGSize(width: -rect.minX, height: -rect.minY)
        let retained = annotations.compactMap { annotation -> EditorAnnotation? in
            guard annotationBounds(annotation).intersects(rect) else { return nil }
            return EditorAnnotationGeometry.translated(annotation, by: delta)
        }
        let selection = selectedAnnotation.flatMap { selection in
            retained.contains(where: { $0.id == selection.id }) ? selection : nil
        }
        let after = EditorCropState(
            baseImage: image, pixelSize: rect.size, annotations: retained,
            selection: selection, sourceOffset: sourceRect.origin
        )
        restoreCropState(after)
        cropRect = nil
        appendHistoryEntry(.crop(before: before, after: after))
        return true
    }

    func beginInteraction(at point: CGPoint) {
        guard cropRect == nil else { return }
        if selectedTool == .eraser,
           CGRect(origin: .zero, size: pixelSize).contains(point) == false {
            return
        }
        endStyleEditing()
        commitPendingTextInsertion()
        cancelInteraction()

        if selectedTool == .move {
            if let selection = selectedAnnotation, resizeHandleContains(point, for: selection) {
                beginResizeInteraction(for: selection, at: point)
            } else if let hit = annotationSelection(at: point) {
                select(hit)
                beginMoveInteraction(for: hit, at: point)
            } else {
                selectedAnnotation = nil
            }
            updateHistoryAvailability()
            return
        }

        selectedAnnotation = nil
        switch selectedTool {
        case .move:
            break
        case .pen:
            activeStroke = EditorStroke(points: [point], color: selectedColor, lineWidth: lineWidth)
            interactionState = .drawing(anchor: point)
        case .eraser:
            activeEraser = EditorEraserStroke(points: [point], lineWidth: CGFloat(eraserWidth))
            interactionState = .erasing
        case .arrow:
            activeArrow = EditorArrow(start: point, end: point, color: selectedColor, lineWidth: lineWidth)
            interactionState = .drawing(anchor: point)
        case .rectangle, .ellipse:
            let anchor = clamped(point: point)
            activeShape = EditorShape(
                kind: selectedTool == .rectangle ? .rectangle : .ellipse,
                rect: CGRect(origin: anchor, size: .zero),
                color: selectedColor, lineWidth: lineWidth, style: shapeStyle
            )
            interactionState = .drawingShape(anchor: anchor)
        case .blur:
            activeBlur = EditorBlur(rect: CGRect(origin: point, size: .zero), radius: blurRadius)
            interactionState = .drawing(anchor: point)
        case .text:
            if beginEditingText(at: point) == false {
                startPendingTextInsertion(at: point)
            }
        }
        updateHistoryAvailability()
    }

    func updateInteraction(at point: CGPoint, constrainProportions: Bool = false) {
        guard cropRect == nil else { return }
        switch interactionState {
        case let .drawing(anchor):
            updateDrawingInteraction(at: point, anchor: anchor)
        case .erasing:
            updateErasingInteraction(at: point)
        case let .drawingShape(anchor):
            updateShapeInteraction(from: anchor, to: point, constrainProportions: constrainProportions)
        case let .moving(original, pointer, bounds):
            let delta = CGSize(
                width: min(max(point.x - pointer.x, min(-bounds.minX, 0)), max(pixelSize.width - bounds.maxX, 0)),
                height: min(max(point.y - pointer.y, min(-bounds.minY, 0)), max(pixelSize.height - bounds.maxY, 0))
            )
            replaceLiveAnnotation(EditorAnnotationGeometry.translated(original, by: delta))
        case let .resizing(original, bounds, pointer):
            guard point != pointer else {
                replaceLiveAnnotation(original)
                return
            }
            let isText = original.editableKind == .text
            let minimum = isText ? CGFloat(48) : max((original.lineWidth ?? 0) + 1, 2)
            let availableWidth = max(pixelSize.width - bounds.minX, 1)
            let availableHeight = max(pixelSize.height - bounds.minY, 1)
            var width = min(max(bounds.width + point.x - pointer.x, min(minimum, availableWidth)), availableWidth)
            var height = isText ? bounds.height :
                min(max(bounds.height + point.y - pointer.y, min(minimum, availableHeight)), availableHeight)
            if constrainProportions, isText == false {
                let scale = min(
                    max(width / max(bounds.width, 1), height / max(bounds.height, 1)),
                    availableWidth / max(bounds.width, 1), availableHeight / max(bounds.height, 1)
                )
                width = bounds.width * scale
                height = bounds.height * scale
            }
            replaceLiveAnnotation(EditorAnnotationGeometry.resized(
                original, from: bounds, to: CGRect(origin: bounds.origin, size: CGSize(width: width, height: height))
            ))
        case let .resizingArrow(original, isStart, pointer):
            let initial = isStart ? original.start : original.end
            let destination = point == pointer ? initial :
                clamped(point: CGPoint(x: initial.x + point.x - pointer.x, y: initial.y + point.y - pointer.y))
            var arrow = original
            if isStart { arrow.start = destination } else { arrow.end = destination }
            replaceLiveAnnotation(.arrow(arrow))
        case .none:
            break
        }
    }

    func endInteraction(at point: CGPoint, constrainProportions: Bool = false) {
        guard cropRect == nil else { return }
        defer {
            interactionState = .none
            interactionBaseline = nil
            updateHistoryAvailability()
        }
        switch interactionState {
        case .drawing:
            finalizeDrawingInteraction(at: point)
        case .erasing:
            updateErasingInteraction(at: point)
            if let activeEraser {
                insertAnnotation(.eraser(activeEraser), name: "Erase")
            }
            activeEraser = nil
        case let .drawingShape(anchor):
            updateShapeInteraction(from: anchor, to: point, constrainProportions: constrainProportions)
            if let activeShape, activeShape.rect.width > 1, activeShape.rect.height > 1 {
                insertAnnotation(.shape(activeShape), name: "Shape")
            }
            activeShape = nil
        case .moving, .resizing, .resizingArrow:
            updateInteraction(at: point, constrainProportions: constrainProportions)
            if let baseline = interactionBaseline {
                finishChange(baseline, name: isMovingInteraction ? "Move" : "Resize")
            }
        case .none:
            break
        }
    }

    func undo() {
        if cropRect != nil {
            cancelCrop()
            return
        }
        endStyleEditing()
        if cancelInteraction() { return }
        if pendingTextInsertion != nil {
            let previousPosition = historyPosition
            commitPendingTextInsertion()
            if historyPosition == previousPosition { return }
        }
        guard historyPosition > 0 else { return }
        historyPosition -= 1
        applyHistoryEntry(history[historyPosition], forward: false)
        updateHistoryAvailability()
    }

    func redo() {
        if cropRect != nil {
            cancelCrop()
            return
        }
        guard hasActiveInteraction == false, pendingTextInsertion == nil else { return }
        endStyleEditing()
        guard historyPosition < history.count else { return }
        applyHistoryEntry(history[historyPosition], forward: true)
        historyPosition += 1
        updateHistoryAvailability()
    }

    /// Continuous inspector controls commit their final payload as one operation.
    func beginStyleEditing() {
        guard cropRect == nil, pendingTextInsertion == nil, styleBaseline == nil else { return }
        styleBaseline = selectedChangeBaseline()
        updateHistoryAvailability()
    }

    func endStyleEditing() {
        guard let baseline = styleBaseline else { return }
        styleBaseline = nil
        finishChange(baseline, name: "Style")
        updateHistoryAvailability()
    }

    var currentLineWidthControlValue: Double {
        selectedPayload?.lineWidth.map(Double.init) ?? lineWidth
    }

    var currentShapeStyle: EditorShapeStyle {
        if case let .shape(shape)? = selectedPayload { return shape.style }
        return shapeStyle
    }

    func setLineWidthControlValue(_ value: Double) {
        lineWidth = max(value, 1)
        changeSelected(name: "Line Width") { $0.withLineWidth(CGFloat(lineWidth)) }
    }

    func setShapeStyle(_ style: EditorShapeStyle) {
        shapeStyle = style
        changeSelected(name: "Shape Style") { annotation in
            guard case var .shape(shape) = annotation else { return annotation }
            shape.style = style
            return .shape(shape)
        }
    }

    func applySelectedColor(_ color: EditorColor) {
        selectedColor = color
        if var pendingTextInsertion {
            pendingTextInsertion.color = color
            self.pendingTextInsertion = pendingTextInsertion
            return
        }
        changeSelected(name: "Color") { $0.withColor(color) }
    }

    func setBlurControlValue(_ value: Double) {
        blurRadius = value
        changeSelected(name: "Blur Radius") { annotation in
            guard case var .blur(blur) = annotation else { return annotation }
            blur.radius = value
            return .blur(blur)
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
        changeSelected(name: "Text Size") { annotation in
            guard case var .text(text) = annotation else { return annotation }
            text.fontSize = CGFloat(value)
            return .text(text)
        }
    }

    func setTextFont(_ font: EditorTextFont) {
        textFont = font
        if var pendingTextInsertion {
            pendingTextInsertion.font = font
            self.pendingTextInsertion = pendingTextInsertion
            return
        }
        changeSelected(name: "Font") { annotation in
            guard case var .text(text) = annotation else { return annotation }
            text.font = font
            return .text(text)
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
        guard let pending = pendingTextInsertion else { return false }
        pendingTextInsertion = nil
        pendingLayoutCache = nil
        defer { updateHistoryAvailability() }
        let isBlank = pending.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if let id = pending.annotationID {
            guard let index = annotations.firstIndex(where: { $0.id == id }),
                  case var .text(annotation) = annotations[index] else { return false }
            let before = annotations[index]
            let selectionBefore = selectedAnnotation
            let after: EditorAnnotation?
            if isBlank {
                annotations.remove(at: index)
                discardCaches(for: id)
                selectedAnnotation = nil
                after = nil
            } else {
                annotation.text = pending.text
                annotation.origin = pending.origin
                annotation.color = pending.color
                annotation.fontSize = pending.fontSize
                annotation.font = pending.font
                annotation.width = pending.width
                after = .text(annotation)
                if before != after { annotations[index] = .text(annotation) }
                select(EditorSelection(id: id, kind: .text))
            }
            return recordChange(
                before: before, after: after, index: index,
                selectionBefore: selectionBefore, name: isBlank ? "Delete Text" : "Edit Text"
            )
        }

        guard isBlank == false else { return false }
        let annotation = EditorTextAnnotation(
            text: pending.text, origin: pending.origin, color: pending.color,
            fontSize: pending.fontSize, font: pending.font, width: pending.width
        )
        insertAnnotation(.text(annotation), name: "Text", selecting: true)
        return true
    }

    @discardableResult
    func beginEditingText(at point: CGPoint) -> Bool {
        guard cropRect == nil else { return false }
        guard let selection = annotationSelection(at: point), selection.kind == .text else {
            return false
        }
        select(selection)
        return beginEditingSelectedText()
    }

    @discardableResult
    func beginEditingSelectedText() -> Bool {
        guard cropRect == nil else { return false }
        endStyleEditing()
        cancelInteraction()
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
        updateHistoryAvailability()
        return true
    }

    @discardableResult
    func deleteSelectedAnnotation() -> Bool {
        guard cropRect == nil, pendingTextInsertion == nil else { return false }
        endStyleEditing()
        cancelInteraction()
        guard let baseline = selectedChangeBaseline() else { return false }
        annotations.remove(at: baseline.index)
        discardCaches(for: baseline.annotation.id)
        selectedAnnotation = nil
        recordChange(
            before: baseline.annotation, after: nil, index: baseline.index,
            selectionBefore: baseline.selection, name: "Delete"
        )
        return true
    }

    @discardableResult
    func duplicateSelectedAnnotation() -> Bool {
        guard cropRect == nil, pendingTextInsertion == nil else { return false }
        endStyleEditing()
        cancelInteraction()
        guard let original = selectedPayload else { return false }
        let bounds = annotationBounds(original)
        func offset(minimum: CGFloat, maximum: CGFloat, limit: CGFloat) -> CGFloat {
            if maximum + 24 <= limit { return 24 }
            if minimum - 24 >= 0 { return -24 }
            return 0
        }
        let delta = CGSize(
            width: offset(minimum: bounds.minX, maximum: bounds.maxX, limit: pixelSize.width),
            height: offset(minimum: bounds.minY, maximum: bounds.maxY, limit: pixelSize.height)
        )
        let copy = EditorAnnotationGeometry.translated(EditorAnnotationGeometry.duplicate(original), by: delta)
        insertAnnotation(copy, name: "Duplicate", selecting: true)
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
        // Keep stroke antialiasing inside the bitmap, then trim the guard pixel.
        // Quartz otherwise clips crossing strokes differently at a newly cropped edge.
        let padding: Int
        if let sourceCGImage,
           pixelSize != CGSize(width: sourceCGImage.width, height: sourceCGImage.height) {
            padding = 1
        } else {
            padding = 0
        }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(pixelSize.width.rounded()), 1) + padding * 2,
            pixelsHigh: max(Int(pixelSize.height.rounded()), 1) + padding * 2,
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

        let scaleX = baseImage.size.width / max(pixelSize.width, 1)
        let scaleY = baseImage.size.height / max(pixelSize.height, 1)
        bitmap.size = CGSize(
            width: baseImage.size.width + CGFloat(padding * 2) * scaleX,
            height: baseImage.size.height + CGFloat(padding * 2) * scaleY
        )

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high

        graphicsContext.cgContext.saveGState()
        graphicsContext.cgContext.scaleBy(x: scaleX, y: scaleY)
        graphicsContext.cgContext.translateBy(x: CGFloat(padding), y: CGFloat(padding))
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
        if padding > 0 {
            guard let cropped = bitmap.cgImage?.cropping(to: CGRect(
                x: padding, y: padding, width: Int(pixelSize.width), height: Int(pixelSize.height)
            )) else { return nil }
            return NSImage(cgImage: cropped, size: baseImage.size)
        }


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
        guard cropRect == nil, pendingTextInsertion == nil, let selection = selectedAnnotation,
              let annotation = selectedPayload else { return nil }
        let rect = annotationBounds(annotation)
        if case let .arrow(arrow) = annotation {
            return EditorSelectionOverlay(
                kind: .arrow, rect: rect,
                handleRect: handleRect(center: arrow.end),
                secondaryHandleRect: handleRect(center: arrow.start)
            )
        }
        return EditorSelectionOverlay(
            kind: selection.kind, rect: rect,
            handleRect: selection.kind == .text ? textResizeHandleRect(for: rect) : resizeHandleRect(for: rect)
        )
    }

    private var selectedPayload: EditorAnnotation? {
        guard let selectedAnnotation else { return nil }
        return annotations.first { $0.id == selectedAnnotation.id }
    }

    private var selectedBlur: EditorBlur? {
        if case let .blur(blur)? = selectedPayload { return blur }
        return nil
    }

    private var selectedText: EditorTextAnnotation? {
        if case let .text(text)? = selectedPayload { return text }
        return nil
    }

    private func updateErasingInteraction(at point: CGPoint) {
        guard var activeEraser, activeEraser.points.last != point else {
            return
        }

        activeEraser.points.append(point)
        self.activeEraser = activeEraser
    }

    private func updateDrawingInteraction(at point: CGPoint, anchor: CGPoint) {
        switch selectedTool {
        case .pen:
            guard var activeStroke, activeStroke.points.last != point else { return }
            activeStroke.points.append(point)
            self.activeStroke = activeStroke
        case .arrow:
            guard var activeArrow else { return }
            activeArrow.end = point
            self.activeArrow = activeArrow
        case .blur:
            guard var activeBlur else { return }
            activeBlur.rect = normalizedRect(from: anchor, to: clamped(point: point))
            self.activeBlur = activeBlur
        case .move, .eraser, .rectangle, .ellipse, .text:
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
        if case let .drawing(anchor) = interactionState {
            updateDrawingInteraction(at: point, anchor: anchor)
        }
        switch selectedTool {
        case .pen:
            if let activeStroke {
                insertAnnotation(.stroke(activeStroke), name: "Draw")
            }
            activeStroke = nil
        case .arrow:
            if let activeArrow, hypot(activeArrow.end.x - activeArrow.start.x, activeArrow.end.y - activeArrow.start.y) > 6 {
                insertAnnotation(.arrow(activeArrow), name: "Arrow")
            }
            activeArrow = nil
        case .blur:
            if let activeBlur, activeBlur.rect.width > 10, activeBlur.rect.height > 10 {
                insertAnnotation(.blur(activeBlur), name: "Blur", selecting: true)
            }
            activeBlur = nil
        case .move, .eraser, .rectangle, .ellipse, .text:
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
        guard let payload = selectedPayload else { return }
        if let color = payload.color { selectedColor = color }
        if let width = payload.lineWidth { lineWidth = Double(width) }
        switch payload {
        case let .shape(shape):
            shapeStyle = shape.style
        case let .blur(blur):
            blurRadius = blur.radius
        case let .text(text):
            textFont = text.font
            textFontSize = Double(text.fontSize)
        case .stroke, .arrow, .eraser:
            break
        }
    }

    func handleEscape() -> Bool {
        if cropRect != nil {
            cancelCrop()
            return true
        }
        endStyleEditing()
        if pendingTextInsertion != nil {
            commitPendingTextInsertion()
            return true
        }
        if cancelInteraction() { return true }
        if selectedAnnotation != nil {
            selectedAnnotation = nil
            return true
        }
        return false
    }

    private func beginMoveInteraction(for selection: EditorSelection, at point: CGPoint) {
        guard let baseline = selectedChangeBaseline() else { return }
        interactionBaseline = baseline
        interactionState = .moving(original: baseline.annotation, pointer: point, bounds: annotationBounds(baseline.annotation))
    }

    private func beginResizeInteraction(for selection: EditorSelection, at point: CGPoint) {
        guard let baseline = selectedChangeBaseline() else { return }
        interactionBaseline = baseline
        if case let .arrow(arrow) = baseline.annotation {
            let startDistance = hypot(point.x - arrow.start.x, point.y - arrow.start.y)
            let endDistance = hypot(point.x - arrow.end.x, point.y - arrow.end.y)
            interactionState = .resizingArrow(original: arrow, isStart: startDistance < endDistance, pointer: point)
        } else {
            interactionState = .resizing(original: baseline.annotation, bounds: annotationBounds(baseline.annotation), pointer: point)
        }
    }

    private func annotationSelection(at point: CGPoint) -> EditorSelection? {
        for annotation in annotations.reversed() {
            if case let .eraser(eraser) = annotation {
                if eraser.path.contains(point) { return nil }
                continue
            }
            guard let kind = annotation.editableKind else { continue }
            let textSize: CGSize?
            if case let .text(text) = annotation {
                textSize = textLayout(for: text).size
            } else {
                textSize = nil
            }
            if EditorAnnotationGeometry.contains(point, in: annotation, textSize: textSize) {
                return EditorSelection(id: annotation.id, kind: kind)
            }
        }
        return nil
    }

    private func annotationBounds(_ annotation: EditorAnnotation) -> CGRect {
        if case let .text(text) = annotation {
            return EditorAnnotationGeometry.bounds(of: annotation, textSize: textLayout(for: text).size)
        }
        return EditorAnnotationGeometry.bounds(of: annotation)
    }

    private func resizeHandleContains(_ point: CGPoint, for selection: EditorSelection) -> Bool {
        guard let overlay = selectionOverlay, overlay.kind == selection.kind else { return false }
        return overlay.handleRect.insetBy(dx: -6, dy: -6).contains(point) ||
            (overlay.secondaryHandleRect?.insetBy(dx: -6, dy: -6).contains(point) ?? false)
    }

    private func handleRect(center: CGPoint) -> CGRect {
        CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)
    }

    private var hasActiveInteraction: Bool {
        if case .none = interactionState { return false }
        return true
    }

    private var isMovingInteraction: Bool {
        if case .moving = interactionState { return true }
        return false
    }

    @discardableResult
    private func cancelInteraction() -> Bool {
        guard hasActiveInteraction else { return false }
        if let baseline = interactionBaseline {
            replaceLiveAnnotation(baseline.annotation)
            if let selection = baseline.selection { select(selection) }
        }
        activeStroke = nil
        activeEraser = nil
        activeArrow = nil
        activeShape = nil
        activeBlur = nil
        interactionBaseline = nil
        interactionState = .none
        updateHistoryAvailability()
        return true
    }

    private func selectedChangeBaseline() -> EditorChangeBaseline? {
        guard let selection = selectedAnnotation,
              let index = annotations.firstIndex(where: { $0.id == selection.id }) else { return nil }
        return EditorChangeBaseline(annotation: annotations[index], index: index, selection: selection)
    }

    private func replaceLiveAnnotation(_ annotation: EditorAnnotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }),
              annotations[index] != annotation else { return }
        annotations[index] = annotation
    }

    private func changeSelected(name: String, transform: (EditorAnnotation) -> EditorAnnotation) {
        guard cropRect == nil, pendingTextInsertion == nil,
              let baseline = selectedChangeBaseline() else { return }
        let after = transform(baseline.annotation)
        guard after != baseline.annotation else { return }
        annotations[baseline.index] = after
        if styleBaseline == nil {
            recordChange(
                before: baseline.annotation, after: after, index: baseline.index,
                selectionBefore: baseline.selection, name: name
            )
        }
    }

    private func insertAnnotation(_ annotation: EditorAnnotation, name: String, selecting: Bool = false) {
        let selectionBefore = selectedAnnotation
        let index = annotations.count
        annotations.append(annotation)
        if selecting, let kind = annotation.editableKind {
            select(EditorSelection(id: annotation.id, kind: kind))
        }
        recordChange(before: nil, after: annotation, index: index, selectionBefore: selectionBefore, name: name)
    }

    private func finishChange(_ baseline: EditorChangeBaseline, name: String) {
        recordChange(
            before: baseline.annotation, after: annotations[baseline.index], index: baseline.index,
            selectionBefore: baseline.selection, name: name
        )
    }

    @discardableResult
    private func recordChange(
        before: EditorAnnotation?, after: EditorAnnotation?, index: Int,
        selectionBefore: EditorSelection?, name: String
    ) -> Bool {
        guard before != after else { return false }
        appendHistoryEntry(.annotation(EditorAnnotationChange(
            before: before, after: after, index: index,
            selectionBefore: selectionBefore, selectionAfter: selectedAnnotation, name: name
        )))
        return true
    }

    private func appendHistoryEntry(_ entry: EditorHistoryEntry) {
        if historyPosition < history.count {
            history.removeSubrange(historyPosition...)
        }
        history.append(entry)
        historyPosition += 1
        updateHistoryAvailability()
    }

    private func applyHistoryEntry(_ entry: EditorHistoryEntry, forward: Bool) {
        switch entry {
        case let .crop(before, after):
            restoreCropState(forward ? after : before)
        case let .annotation(change):
            applyAnnotationChange(change, forward: forward)
        }
    }

    private func applyAnnotationChange(_ change: EditorAnnotationChange, forward: Bool) {
        let previous = forward ? change.before : change.after
        let next = forward ? change.after : change.before
        if previous != nil {
            if let next {
                annotations[change.index] = next
            } else {
                let removed = annotations.remove(at: change.index)
                discardCaches(for: removed.id)
            }
        } else if let next {
            annotations.insert(next, at: change.index)
        }
        selectedAnnotation = nil
        if let selection = forward ? change.selectionAfter : change.selectionBefore,
           annotations.contains(where: { $0.id == selection.id }) {
            select(selection)
        }
    }

    private var cropState: EditorCropState {
        EditorCropState(
            baseImage: baseImage, pixelSize: pixelSize, annotations: annotations,
            selection: selectedAnnotation, sourceOffset: sourceOffset
        )
    }

    private func restoreCropState(_ state: EditorCropState) {
        baseImage = state.baseImage
        pixelSize = state.pixelSize
        annotations = state.annotations
        sourceOffset = state.sourceOffset
        blurImageCache.removeAll(keepingCapacity: true)
        textLayoutCache.removeAll(keepingCapacity: true)
        pendingLayoutCache = nil
        selectedAnnotation = nil
        if let selection = state.selection { select(selection) }
    }

    private func normalizedCropRect(_ rect: CGRect) -> CGRect? {
        guard rect.isNull == false, rect.isInfinite == false,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return nil }
        let standardized = rect.standardized
        guard standardized.minX.isFinite, standardized.minY.isFinite,
              standardized.maxX.isFinite, standardized.maxY.isFinite,
              standardized.isEmpty == false else { return nil }
        let bounds = CGRect(origin: .zero, size: pixelSize)
        let intersection = standardized.intersection(bounds)
        guard intersection.isNull == false, intersection.isEmpty == false else { return nil }
        let snapped = intersection.integral.intersection(bounds)
        return snapped.isEmpty ? nil : snapped
    }

    private func discardCaches(for id: UUID) {
        blurImageCache.removeValue(forKey: id)
        textLayoutCache.removeValue(forKey: id)
    }

    private func updateHistoryAvailability() {
        let undoAvailable = cropRect != nil || hasActiveInteraction || historyPosition > 0
        let redoAvailable = cropRect == nil && hasActiveInteraction == false && pendingTextInsertion == nil &&
            styleBaseline == nil && historyPosition < history.count
        let undoName = cropRect != nil ? "Crop" : hasActiveInteraction ? "Current Gesture" :
            (historyPosition > 0 ? history[historyPosition - 1].name : "")
        let redoName = redoAvailable ? history[historyPosition].name : ""
        if canUndo != undoAvailable { canUndo = undoAvailable }
        if canRedo != redoAvailable { canRedo = redoAvailable }
        if undoActionName != undoName { undoActionName = undoName }
        if redoActionName != redoName { redoActionName = redoName }
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


    private func drawStroke(_ stroke: EditorStroke) {
        guard let firstPoint = stroke.points.first else { return }
        if stroke.points.count == 1 {
            let point = flip(point: firstPoint)
            let radius = stroke.lineWidth / 2
            stroke.color.nsColor.setFill()
            NSBezierPath(ovalIn: CGRect(
                x: point.x - radius, y: point.y - radius, width: stroke.lineWidth, height: stroke.lineWidth
            )).fill()
            return
        }

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = stroke.lineWidth

        let first = flip(point: firstPoint)
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
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: 1, y: -1)
        context.addPath(EditorAnnotationGeometry.arrowPath(arrow))
        context.setStrokeColor(arrow.color.nsColor.cgColor)
        context.setLineWidth(arrow.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
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

        guard let baseCIImage else { return nil }
        let sourceRect = blur.rect.offsetBy(dx: sourceOffset.x, dy: sourceOffset.y)
        let ciRect = CGRect(
            x: sourceRect.minX, y: baseCIImage.extent.height - sourceRect.maxY,
            width: sourceRect.width, height: sourceRect.height
        ).integral
        guard ciRect.isEmpty == false else {
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
