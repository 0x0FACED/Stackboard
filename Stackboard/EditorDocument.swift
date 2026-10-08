import AppKit
import Combine
import CoreImage
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case move
    case pen
    case arrow
    case blur
    case text

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .move: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .arrow: return "arrow.up.right"
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

    func swiftUIFont(size: CGFloat) -> Font {
        switch self {
        case .system:
            return .system(size: size, weight: .bold, design: .default)
        case .rounded:
            return .system(size: size, weight: .bold, design: .rounded)
        case .serif:
            return .custom("Georgia-Bold", size: size)
        case .monospaced:
            return .system(size: size, weight: .bold, design: .monospaced)
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

struct EditorArrow {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var color: EditorColor
    var lineWidth: CGFloat
}

struct EditorBlur {
    let id = UUID()
    var rect: CGRect
    var radius: Double
}

struct EditorTextAnnotation {
    let id = UUID()
    var text: String
    var origin: CGPoint
    var color: EditorColor
    var fontSize: CGFloat
    var font: EditorTextFont
}

enum EditorAnnotation: Identifiable {
    case stroke(EditorStroke)
    case arrow(EditorArrow)
    case blur(EditorBlur)
    case text(EditorTextAnnotation)

    var id: UUID {
        switch self {
        case let .stroke(stroke): return stroke.id
        case let .arrow(arrow): return arrow.id
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
    let id = UUID()
    var origin: CGPoint
    var text: String
    var color: EditorColor
    var fontSize: CGFloat
    var font: EditorTextFont
}

private enum EditorCanvasInteractionState {
    case none
    case drawing
    case movingBlur(id: UUID, pointerOffset: CGSize, size: CGSize)
    case resizingBlur(id: UUID, anchor: CGPoint)
    case movingText(id: UUID, pointerOffset: CGSize, size: CGSize)
    case resizingText(id: UUID, origin: CGPoint, initialFontSize: CGFloat, initialSize: CGSize)
}

@MainActor
final class EditorDocument: ObservableObject {
    let baseImage: NSImage
    let pixelSize: CGSize

    @Published var selectedTool: EditorTool = .pen
    @Published private(set) var selectedColor: EditorColor = .yellow
    /// Stored in image pixels; preview scales this width with the canvas, just like export.
    @Published var lineWidth: Double = 6
    @Published private(set) var blurRadius: Double = 14
    @Published private(set) var textFont: EditorTextFont = .system
    @Published private(set) var textFontSize: Double = 24
    @Published private(set) var annotations: [EditorAnnotation] = []
    @Published private(set) var activeStroke: EditorStroke?
    @Published private(set) var activeArrow: EditorArrow?
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
    }

    func activateTool(_ tool: EditorTool) {
        guard selectedTool != tool else {
            return
        }

        if tool != .text {
            _ = commitPendingTextInsertion()
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
        if selectedTool == .move {
            if let selection = selectedAnnotation,
               resizeHandleContains(point, for: selection) {
                beginResizeInteraction(for: selection)
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

        commitPendingTextInsertion()
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
        case .arrow:
            activeArrow = EditorArrow(
                start: point,
                end: point,
                color: selectedColor,
                lineWidth: lineWidth
            )
            interactionState = .drawing
        case .blur:
            activeBlur = EditorBlur(rect: CGRect(origin: point, size: .zero), radius: blurRadius)
            interactionState = .drawing
        case .text:
            startPendingTextInsertion(at: point)
            interactionState = .none
        }
    }

    func updateInteraction(at point: CGPoint) {
        switch interactionState {
        case .drawing:
            updateDrawingInteraction(at: point)
        case let .movingBlur(id, pointerOffset, size):
            updateBlurPosition(id: id, origin: CGPoint(x: point.x - pointerOffset.width, y: point.y - pointerOffset.height), size: size)
        case let .resizingBlur(id, anchor):
            updateBlurRect(id: id, rect: clampedRect(normalizedRect(from: anchor, to: clamped(point: point))))
        case let .movingText(id, pointerOffset, size):
            updateTextOrigin(id: id, origin: CGPoint(x: point.x - pointerOffset.width, y: point.y - pointerOffset.height), size: size)
        case let .resizingText(id, origin, initialFontSize, initialSize):
            let widthRatio = max((point.x - origin.x) / max(initialSize.width, 1), 0.45)
            let heightRatio = max((point.y - origin.y) / max(initialSize.height, 1), 0.45)
            let scale = max(widthRatio, heightRatio)
            updateTextFontSize(id: id, fontSize: min(max(initialFontSize * scale, 12), 96))
        case .none:
            break
        }
    }

    func endInteraction(at point: CGPoint) {
        defer {
            interactionState = .none
        }

        switch interactionState {
        case .drawing:
            finalizeDrawingInteraction(at: point)
        case .movingBlur, .resizingBlur, .movingText, .resizingText, .none:
            break
        }
    }

    func undoLastAnnotation() {
        if pendingTextInsertion != nil {
            pendingTextInsertion = nil
            return
        }

        if let removed = annotations.popLast() {
            blurImageCache.removeValue(forKey: removed.id)
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
        textFontSize = value

        if var pendingTextInsertion {
            pendingTextInsertion.fontSize = CGFloat(value)
            self.pendingTextInsertion = pendingTextInsertion
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
        guard var pendingTextInsertion else {
            return false
        }

        pendingTextInsertion.text = pendingTextInsertion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pendingTextInsertion = nil

        guard pendingTextInsertion.text.isEmpty == false else {
            return false
        }

        let annotation = EditorTextAnnotation(
            text: pendingTextInsertion.text,
            origin: pendingTextInsertion.origin,
            color: pendingTextInsertion.color,
            fontSize: pendingTextInsertion.fontSize,
            font: pendingTextInsertion.font
        )
        annotations.append(.text(annotation))
        select(EditorSelection(id: annotation.id, kind: .text))
        return true
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

        for annotation in annotations {
            switch annotation {
            case let .stroke(stroke):
                drawStroke(stroke)
            case let .arrow(arrow):
                drawArrow(arrow)
            case let .blur(blur):
                drawBlur(blur)
            case let .text(text):
                drawText(text)
            }
        }
        graphicsContext.cgContext.restoreGState()

        let image = NSImage(size: baseImage.size)
        image.addRepresentation(bitmap)
        return image
    }

    var committedAndActiveAnnotations: [EditorAnnotation] {
        var result = annotations
        if let activeStroke {
            result.append(.stroke(activeStroke))
        }
        if let activeArrow {
            result.append(.arrow(activeArrow))
        }
        if let activeBlur {
            result.append(.blur(activeBlur))
        }
        return result
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
        guard let selectedAnnotation else {
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
                handleRect: resizeHandleRect(for: rect)
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
        case .text:
            break
        }
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
        case .text:
            break
        }
    }

    private func startPendingTextInsertion(at point: CGPoint) {
        pendingTextInsertion = PendingTextInsertion(
            origin: clamped(origin: point, size: CGSize(width: 260, height: CGFloat(textFontSize) * 1.4)),
            text: "",
            color: selectedColor,
            fontSize: CGFloat(textFontSize),
            font: textFont
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
        if let pendingTextInsertion {
            if pendingTextInsertion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.pendingTextInsertion = nil
            } else {
                _ = commitPendingTextInsertion()
            }
            return true
        }

        if activeStroke != nil || activeArrow != nil || activeBlur != nil {
            activeStroke = nil
            activeArrow = nil
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

    private func beginResizeInteraction(for selection: EditorSelection) {
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
                initialFontSize: text.fontSize,
                initialSize: textBounds(for: text).size
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
            case .stroke, .arrow:
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: annotation.font.nsFont(size: annotation.fontSize)
        ]
        let measured = NSString(string: annotation.text).size(withAttributes: attributes)
        let width = max(measured.width, 48)
        let height = max(measured.height, annotation.fontSize * 1.2)
        return CGRect(origin: annotation.origin, size: CGSize(width: width, height: height))
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
        let point = CGPoint(
            x: text.origin.x,
            y: pixelSize.height - text.origin.y - text.fontSize
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .font: text.font.nsFont(size: text.fontSize),
            .foregroundColor: text.color.nsColor
        ]
        NSString(string: text.text).draw(at: point, withAttributes: attributes)
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
