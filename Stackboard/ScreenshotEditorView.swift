import AppKit
import SwiftUI

private enum EditorToolbarContextMode {
    case none
    case lineWidth
    case eraser
    case shape
    case blur
    case text
}

struct ScreenshotEditorView: View {
    static let minimumContentSize = CGSize(width: 900, height: 620)
    static let sidebarWidth: CGFloat = 176

    @ObservedObject var document: EditorDocument
    var minimumSize: CGSize = Self.minimumContentSize
    let onCopy: () -> Void

    private let palette: [EditorColor] = [.yellow, .red, .blue, .green, .white]

    var body: some View {
        HStack(spacing: 0) {
            toolbar
            Divider()
                .frame(width: 1)
            EditorCanvasView(document: document)
        }
        .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 4) {
                        ForEach(EditorTool.allCases) { tool in
                            EditorToolbarIconButton(
                                systemImage: tool.iconName,
                                isSelected: document.selectedTool == tool,
                                accessibilityLabel: tool.title
                            ) {
                                document.activateTool(tool)
                            }
                            .help(toolHelp(for: tool))
                        }
                    }

                    Divider()

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(30)), count: 3),
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                            Button {
                                document.applySelectedColor(color)
                            } label: {
                                Circle()
                                    .fill(Color(nsColor: color.nsColor))
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                document.selectedColor == color ? Color.primary : Color.clear,
                                                lineWidth: 2
                                            )
                                    )
                                    .frame(width: 20, height: 20)
                                    .frame(width: 30, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        ColorPicker(
                            "Custom color",
                            selection: Binding(
                                get: { Color(nsColor: document.selectedColor.nsColor) },
                                set: { newColor in
                                    guard let color = NSColor(newColor).usingColorSpace(.sRGB) else {
                                        return
                                    }
                                    document.applySelectedColor(
                                        EditorColor(
                                            red: Double(color.redComponent),
                                            green: Double(color.greenComponent),
                                            blue: Double(color.blueComponent),
                                            alpha: Double(color.alphaComponent)
                                        )
                                    )
                                }
                            ),
                            supportsOpacity: true
                        )
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                        .accessibilityLabel("Custom color")
                        .help("Choose a custom color and opacity")
                    }

                    if contextMode != .none {
                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            contextControl
                            if contextMode == .text {
                                textControls
                            }
                        }
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.never)

            Divider()

            VStack(spacing: 8) {
                Button {
                    document.undoLastAnnotation()
                } label: {
                    Text("Undo")
                        .frame(maxWidth: .infinity)
                }
                .help("Undo the last annotation or erase stroke")

                Button(action: onCopy) {
                    Text("Copy to Clipboard")
                        .frame(maxWidth: .infinity)
                }
                .help("Copy to Clipboard. Esc clears selection first, then copies and closes.")
            }
            .padding(12)
        }
        .frame(width: Self.sidebarWidth - 1)
    }

    @ViewBuilder
    private var contextControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch contextMode {
            case .lineWidth:
                lineWidthControl
            case .eraser:
                HStack {
                    Text("Eraser size")
                    Spacer()
                    Text("\(Int(document.eraserWidth.rounded()))")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                Slider(value: $document.eraserWidth, in: 8 ... 128)
                    .accessibilityLabel("Eraser size")
                    .help("Eraser diameter in image pixels")
            case .shape:
                Text("Shape style")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Shape style", selection: $document.shapeStyle) {
                    ForEach(EditorShapeStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if document.shapeStyle == .outline {
                    lineWidthControl
                }
                Text(document.selectedTool == .rectangle ? "Hold Shift for a square" : "Hold Shift for a circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .blur:
                HStack {
                    Text("Blur radius")
                    Spacer()
                    Text("\(Int(document.currentBlurControlValue.rounded()))")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { document.currentBlurControlValue },
                        set: { document.setBlurControlValue($0) }
                    ),
                    in: 4 ... 28
                )
                .accessibilityLabel("Blur radius")
                .help("Blur radius in image pixels")
            case .text:
                HStack {
                    Text("Text size")
                    Spacer()
                    TextField(
                        "Text size",
                        value: Binding(
                            get: { document.currentTextSizeControlValue },
                            set: { document.setTextSizeControlValue($0) }
                        ),
                        format: .number.precision(.fractionLength(0 ... 1))
                    )
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 58)
                    .accessibilityLabel("Text size in image pixels")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { document.currentTextSizeControlValue },
                        set: { document.setTextSizeControlValue($0) }
                    ),
                    in: 8 ... 256
                )
                .accessibilityLabel("Text size")
                .help("Text size in image pixels")
            case .none:
                EmptyView()
            }
        }
    }

    private var lineWidthControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Line width")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Slider(value: $document.lineWidth, in: 2 ... 16)
                .accessibilityLabel("Line width")
                .help("Line width in image pixels")
        }
    }

    @ViewBuilder
    private var textControls: some View {
        Picker(
            "Font",
            selection: Binding(
                get: { document.currentTextFont },
                set: { document.setTextFont($0) }
            )
        ) {
            ForEach(EditorTextFont.allCases) { font in
                Text(font.title).tag(font)
            }
        }
        .pickerStyle(.menu)
        .help(document.selectedTool == .text ? "Click the image to type" : "Selected text font")

        if document.pendingTextInsertion != nil {
            Button("Done") {
                document.commitPendingTextInsertion()
            }
            .help("Finish editing text (⌘Enter or Esc)")
        } else if document.selectedAnnotation?.kind == .text {
            HStack {
                Button("Edit") {
                    document.beginEditingSelectedText()
                }
                .help("Edit selected text (Enter)")
                Button("Delete") {
                    document.deleteSelectedText()
                }
                .help("Delete selected text")
            }
        }

        Text("Enter: new line · ⌘Enter: done\nMove: double-click to edit\nDrag the handle to change width")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toolHelp(for tool: EditorTool) -> String {
        switch tool {
        case .move:
            return "Select blur or text to move. Drag the handle to resize; double-click text to edit."
        case .text:
            return "Click the image to type, or click existing text to edit"
        case .eraser:
            return "Erase annotations without changing the screenshot. Undo restores erased marks."
        case .rectangle:
            return "Draw a rectangle. Hold Shift for a square."
        case .ellipse:
            return "Draw an ellipse. Hold Shift for a circle."
        case .pen, .arrow, .blur:
            return tool.title
        }
    }

    private var contextMode: EditorToolbarContextMode {
        switch document.selectedTool {
        case .move:
            switch document.selectedAnnotation?.kind {
            case .blur?:
                return .blur
            case .text?:
                return .text
            case nil:
                return .none
            }
        case .pen, .arrow:
            return .lineWidth
        case .eraser:
            return .eraser
        case .rectangle, .ellipse:
            return .shape
        case .blur:
            return .blur
        case .text:
            return .text
        }
    }
}

private struct EditorToolbarIconButton: View {
    let systemImage: String
    let isSelected: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)

                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 20)
                    Text(accessibilityLabel)
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
            }
            .frame(height: 36)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct EditorCanvasView: View {
    @ObservedObject var document: EditorDocument
    @State private var didBeginInteraction = false
    @State private var baseZoomScale: CGFloat = 1
    @State private var isEditingDoubleClick = false
    @State private var liveMagnification: CGFloat = 1
    @State private var eraserCursorLocation: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            let imageSize = document.baseImage.size
            // A minimum-size editor must not stretch a small capture beyond its native point size.
            let fitScale = min(
                1,
                viewportSize.width / max(imageSize.width, 1),
                viewportSize.height / max(imageSize.height, 1)
            )
            let baseCanvasSize = CGSize(
                width: imageSize.width * fitScale,
                height: imageSize.height * fitScale
            )
            let zoomScale = min(max(baseZoomScale * liveMagnification, 1), 5)
            let canvasSize = CGSize(
                width: baseCanvasSize.width * zoomScale,
                height: baseCanvasSize.height * zoomScale
            )
            let scrollContentSize = CGSize(
                width: max(canvasSize.width, viewportSize.width),
                height: max(canvasSize.height, viewportSize.height)
            )

            ZStack {
                Color.black.opacity(0.92)
                    .ignoresSafeArea()

                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        Color.clear
                            .frame(width: scrollContentSize.width, height: scrollContentSize.height)

                        editorSurface(canvasSize: canvasSize)
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .position(
                                x: scrollContentSize.width * 0.5,
                                y: scrollContentSize.height * 0.5
                            )
                    }
                }
                .scrollIndicators(.never)
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            liveMagnification = value
                        }
                        .onEnded { value in
                            baseZoomScale = min(max(baseZoomScale * value, 1), 5)
                            liveMagnification = 1
                        }
                )

                zoomBadge(zoomScale)
            }
        }
    }

    private func editorSurface(canvasSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: document.baseImage)
                .resizable()
                .frame(width: canvasSize.width, height: canvasSize.height)

            AnnotationLayersView(document: document)
                .allowsHitTesting(false)

            if let activeBlur = document.activeBlur {
                BlurOutlineView(blur: activeBlur, pixelSize: document.pixelSize)
                    .allowsHitTesting(false)
            }

            if let selectionOverlay = document.selectionOverlay {
                AnnotationSelectionOverlayView(
                    overlay: selectionOverlay,
                    pixelSize: document.pixelSize
                )
                .allowsHitTesting(false)
            }

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(dragGesture(for: canvasSize))
                .onContinuousHover { phase in
                    guard document.selectedTool == .eraser else {
                        return
                    }
                    switch phase {
                    case let .active(location):
                        eraserCursorLocation = location
                    case .ended:
                        eraserCursorLocation = nil
                    }
                }

            if document.selectedTool == .eraser, let eraserCursorLocation {
                let diameter = document.activeEraser?.lineWidth ?? CGFloat(document.eraserWidth)
                Ellipse()
                    .stroke(.black.opacity(0.8), lineWidth: 3)
                    .overlay(
                        Ellipse()
                            .stroke(.white, lineWidth: 1)
                    )
                    .frame(
                        width: diameter / max(document.pixelSize.width, 1) * canvasSize.width,
                        height: diameter / max(document.pixelSize.height, 1) * canvasSize.height
                    )
                    .position(eraserCursorLocation)
                    .allowsHitTesting(false)
            }

            if let pendingTextInsertion = document.pendingTextInsertion,
               let textBounds = document.pendingTextBounds {
                PendingTextInsertionOverlay(
                    pendingTextInsertion: pendingTextInsertion,
                    textBounds: textBounds,
                    pixelSize: document.pixelSize,
                    onTextChange: document.setPendingText,
                    onCommit: {
                        document.commitPendingTextInsertion()
                    }
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 24, y: 14)
        .help("Pinch to zoom")
    }

    private func zoomBadge(_ zoomScale: CGFloat) -> some View {
        VStack {
            HStack {
                Spacer()

                Text("\(Int((zoomScale * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    )
            }

            Spacer()
        }
        .padding(18)
        .allowsHitTesting(false)
    }

    private func dragGesture(for canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Coalesced drag events must not lose the start of an eraser stroke.
                let startsErasing = didBeginInteraction == false && document.selectedTool == .eraser
                let eraserStart = startsErasing ? mapToImageSpace(
                    location: value.startLocation,
                    canvasSize: canvasSize,
                    clamp: false
                ) : nil
                guard startsErasing == false || eraserStart != nil else {
                    return
                }
                let allowsRawEndpoint = (didBeginInteraction || startsErasing) &&
                    (document.selectedTool == .rectangle || document.selectedTool == .ellipse ||
                        document.selectedTool == .eraser)
                guard let point = mapToImageSpace(
                    location: value.location,
                    canvasSize: canvasSize,
                    clamp: false,
                    allowOutsideBounds: allowsRawEndpoint
                ) else {
                    return
                }
                if document.selectedTool == .eraser {
                    eraserCursorLocation = value.location
                }

                if didBeginInteraction == false {
                    didBeginInteraction = true
                    if document.selectedTool == .move,
                       (NSApp.currentEvent?.clickCount ?? 0) == 2,
                       document.beginEditingText(at: point) {
                        isEditingDoubleClick = true
                        return
                    }
                    document.beginInteraction(at: eraserStart ?? point)
                    if startsErasing {
                        document.updateInteraction(at: point)
                    }
                } else if isEditingDoubleClick == false {
                    document.updateInteraction(
                        at: point,
                        constrainProportions: (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift)
                    )
                }
            }
            .onEnded { value in
                defer {
                    didBeginInteraction = false
                    isEditingDoubleClick = false
                }
                guard isEditingDoubleClick == false else {
                    return
                }

                let startsErasing = didBeginInteraction == false && document.selectedTool == .eraser
                let eraserStart = startsErasing ? mapToImageSpace(
                    location: value.startLocation,
                    canvasSize: canvasSize,
                    clamp: false
                ) : nil
                guard startsErasing == false || eraserStart != nil else {
                    return
                }
                let allowsRawEndpoint = (didBeginInteraction || startsErasing) &&
                    (document.selectedTool == .rectangle || document.selectedTool == .ellipse ||
                        document.selectedTool == .eraser)

                guard let point = mapToImageSpace(
                    location: value.location,
                    canvasSize: canvasSize,
                    clamp: didBeginInteraction && allowsRawEndpoint == false,
                    allowOutsideBounds: allowsRawEndpoint
                ) else {
                    return
                }
                if document.selectedTool == .eraser {
                    eraserCursorLocation = value.location
                }

                if didBeginInteraction == false {
                    document.beginInteraction(at: eraserStart ?? point)
                }
                document.endInteraction(
                    at: point,
                    constrainProportions: (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift)
                )
            }
    }

    private func mapToImageSpace(
        location: CGPoint,
        canvasSize: CGSize,
        clamp: Bool,
        allowOutsideBounds: Bool = false
    ) -> CGPoint? {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return nil
        }

        let localBounds = CGRect(origin: .zero, size: canvasSize)

        if clamp == false, allowOutsideBounds == false, localBounds.contains(location) == false {
            return nil
        }

        let x = clamp ? min(max(location.x, localBounds.minX), localBounds.maxX) : location.x
        let y = clamp ? min(max(location.y, localBounds.minY), localBounds.maxY) : location.y
        let localX = x / canvasSize.width
        let localY = y / canvasSize.height

        return CGPoint(
            x: localX * document.pixelSize.width,
            y: localY * document.pixelSize.height
        )
    }
}

private struct AnnotationLayersView: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        GeometryReader { proxy in
            if document.hasEraser {
                annotationLayers(canvasSize: proxy.size)
                    .drawingGroup(opaque: false, colorMode: .nonLinear)
            } else {
                annotationLayers(canvasSize: proxy.size)
            }
        }
    }

    private func annotationLayers(canvasSize: CGSize) -> some View {
        // Match export ordering, isolating erase masks from the source image.
        ZStack(alignment: .topLeading) {
            ForEach(document.committedAndActiveAnnotations) { annotation in
                switch annotation {
                case .stroke, .arrow, .shape:
                    AnnotationCanvasView(annotation: annotation, pixelSize: document.pixelSize)
                case .eraser:
                    AnnotationCanvasView(annotation: annotation, pixelSize: document.pixelSize)
                        .blendMode(.destinationOut)
                case let .blur(blur):
                    if let image = document.blurImage(for: blur) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(
                                width: blur.rect.width / document.pixelSize.width * canvasSize.width,
                                height: blur.rect.height / document.pixelSize.height * canvasSize.height
                            )
                            .offset(
                                x: blur.rect.minX / document.pixelSize.width * canvasSize.width,
                                y: blur.rect.minY / document.pixelSize.height * canvasSize.height
                            )
                    }
                case let .text(text):
                    AnnotationTextLayer(
                        annotation: text,
                        layout: document.textLayout(for: text),
                        pixelSize: document.pixelSize
                    )
                }
            }
            if let eraser = document.activeEraser {
                AnnotationCanvasView(annotation: .eraser(eraser), pixelSize: document.pixelSize)
                    .blendMode(.destinationOut)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }
}

private struct BlurOutlineView: View {
    let blur: EditorBlur
    let pixelSize: CGSize

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(
                x: blur.rect.minX / pixelSize.width * size.width,
                y: blur.rect.minY / pixelSize.height * size.height,
                width: blur.rect.width / pixelSize.width * size.width,
                height: blur.rect.height / pixelSize.height * size.height
            )
            context.stroke(
                Path(rect),
                with: .color(.white.opacity(0.85)),
                style: StrokeStyle(lineWidth: 2, dash: [6, 4])
            )
        }
    }
}

private struct AnnotationCanvasView: View {
    let annotation: EditorAnnotation
    let pixelSize: CGSize

    var body: some View {
        Canvas { context, size in
            // Transform pixel-space geometry and stroke widths together, including shapes and arrow heads.
            context.scaleBy(
                x: size.width / max(pixelSize.width, 1),
                y: size.height / max(pixelSize.height, 1)
            )
            switch annotation {
            case let .stroke(stroke):
                drawStroke(stroke, in: &context)
            case let .eraser(eraser):
                context.fill(Path(eraser.path), with: .color(.white))
            case let .arrow(arrow):
                drawArrow(arrow, in: &context)
            case let .shape(shape):
                drawShape(shape, in: &context)
            case .blur, .text:
                break
            }
        }
    }

    private func drawStroke(_ stroke: EditorStroke, in context: inout GraphicsContext) {
        guard stroke.points.count > 1 else {
            return
        }

        var path = Path()
        path.move(to: stroke.points[0])
        for point in stroke.points.dropFirst() {
            path.addLine(to: point)
        }

        context.stroke(
            path,
            with: .color(Color(nsColor: stroke.color.nsColor)),
            style: StrokeStyle(lineWidth: stroke.lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawArrow(_ arrow: EditorArrow, in context: inout GraphicsContext) {
        let start = arrow.start
        let end = arrow.end
        let width = arrow.lineWidth

        var shaft = Path()
        shaft.move(to: start)
        shaft.addLine(to: end)
        context.stroke(
            shaft,
            with: .color(Color(nsColor: arrow.color.nsColor)),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        )

        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let angle = atan2(deltaY, deltaX)
        let headLength = max(width * 2.6, 18)
        let headAngle = CGFloat.pi / 7

        let left = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        var head = Path()
        head.move(to: end)
        head.addLine(to: left)
        head.move(to: end)
        head.addLine(to: right)

        context.stroke(
            head,
            with: .color(Color(nsColor: arrow.color.nsColor)),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawShape(_ shape: EditorShape, in context: inout GraphicsContext) {
        let path = Path(shape.path)
        let color = GraphicsContext.Shading.color(Color(nsColor: shape.color.nsColor))
        switch shape.style {
        case .outline:
            context.stroke(
                path,
                with: color,
                style: StrokeStyle(lineWidth: shape.lineWidth, lineJoin: .miter)
            )
        case .filled:
            context.fill(path, with: color)
        }
    }

}

private struct AnnotationTextLayer: View {
    let annotation: EditorTextAnnotation
    let layout: EditorTextLayout
    let pixelSize: CGSize

    var body: some View {
        Canvas { context, size in
            // Keep native glyph drawing inside SwiftUI's annotation-only eraser group.
            context.withCGContext { cgContext in
                cgContext.saveGState()
                cgContext.scaleBy(
                    x: size.width / max(pixelSize.width, 1),
                    y: size.height / max(pixelSize.height, 1)
                )
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: true)
                layout.draw(at: annotation.origin)
                NSGraphicsContext.restoreGraphicsState()
                cgContext.restoreGState()
            }
        }
    }
}

private struct AnnotationSelectionOverlayView: View {
    let overlay: EditorSelectionOverlay
    let pixelSize: CGSize

    var body: some View {
        Canvas { context, size in
            let rect = scale(rect: overlay.rect, size: size)
            let handleRect = scale(rect: overlay.handleRect, size: size)

            context.stroke(
                Path(roundedRect: rect, cornerRadius: overlay.kind == .text ? 8 : 6),
                with: .color(Color.accentColor.opacity(0.95)),
                lineWidth: 2
            )

            context.fill(
                Path(ellipseIn: handleRect),
                with: .color(.white)
            )
            context.stroke(
                Path(ellipseIn: handleRect),
                with: .color(Color.accentColor.opacity(0.95)),
                lineWidth: 2
            )
        }
    }

    private func scale(rect: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX / pixelSize.width * size.width,
            y: rect.minY / pixelSize.height * size.height,
            width: rect.width / pixelSize.width * size.width,
            height: rect.height / pixelSize.height * size.height
        )
    }
}

private struct PendingTextInsertionOverlay: View {
    let pendingTextInsertion: PendingTextInsertion
    let textBounds: CGRect
    let pixelSize: CGSize
    let onTextChange: (String) -> Void
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let scaleX = proxy.size.width / max(pixelSize.width, 1)
            let scaleY = proxy.size.height / max(pixelSize.height, 1)

            InlineTextEditor(
                pending: pendingTextInsertion,
                sourceSize: textBounds.size,
                onTextChange: onTextChange,
                onCommit: onCommit
            )
            .id(pendingTextInsertion.id)
            .frame(width: textBounds.width * scaleX, height: textBounds.height * scaleY)
            .overlay {
                Rectangle()
                    .stroke(Color.accentColor.opacity(0.95), lineWidth: 1)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
            .offset(x: textBounds.minX * scaleX, y: textBounds.minY * scaleY)
        }
    }
}

private struct InlineTextEditor: NSViewRepresentable {
    let pending: PendingTextInsertion
    let sourceSize: CGSize
    let onTextChange: (String) -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> InlineTextEditorHost {
        let host = InlineTextEditorHost(pending: pending, sourceSize: sourceSize)
        host.textView.delegate = context.coordinator
        host.textView.onCommit = onCommit
        host.textView.onMarkedTextEnd = { [weak coordinator = context.coordinator, weak textView = host.textView] in
            guard let coordinator, let textView else {
                return
            }
            coordinator.applyStyle(to: textView)
        }
        context.coordinator.lastPublishedText = pending.text
        context.coordinator.pendingStyle = pending
        context.coordinator.applyStyle(to: host.textView)
        return host
    }

    func updateNSView(_ host: InlineTextEditorHost, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTextChange = onTextChange
        host.textView.onCommit = onCommit
        host.sourceSize = sourceSize

        // Model echoes must not replace the text storage, selection, or IME marked range.
        if pending.text != coordinator.lastPublishedText, host.textView.hasMarkedText() == false {
            if host.textView.string != pending.text {
                let selection = host.textView.selectedRange()
                host.textView.string = pending.text
                let length = (pending.text as NSString).length
                let location = min(selection.location, length)
                host.textView.setSelectedRange(
                    NSRange(location: location, length: min(selection.length, length - location))
                )
            }
            coordinator.lastPublishedText = pending.text
        }
        coordinator.pendingStyle = pending
        coordinator.applyStyle(to: host.textView)
    }

    static func dismantleNSView(_ host: InlineTextEditorHost, coordinator: Coordinator) {
        if host.window?.firstResponder === host.textView {
            host.window?.makeFirstResponder(nil)
        }
        host.textView.delegate = nil
        host.textView.onCommit = nil
        host.textView.onMarkedTextEnd = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: (String) -> Void
        var lastPublishedText = ""
        var pendingStyle: PendingTextInsertion?
        private var appliedFont: EditorTextFont?
        private var appliedFontSize: CGFloat?
        private var appliedColor: EditorColor?
        private let editingUndoManager = UndoManager()

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            editingUndoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            lastPublishedText = textView.string
            onTextChange(textView.string)
            applyStyle(
                to: textView,
                force: editingUndoManager.isUndoing || editingUndoManager.isRedoing
            )
        }

        func applyStyle(to textView: NSTextView, force: Bool = false) {
            guard let pendingStyle, textView.hasMarkedText() == false,
                  force || appliedFont != pendingStyle.font ||
                    appliedFontSize != pendingStyle.fontSize ||
                    appliedColor != pendingStyle.color else {
                return
            }
            let attributes = EditorTextLayout.attributes(
                font: pendingStyle.font,
                fontSize: pendingStyle.fontSize,
                color: pendingStyle.color
            )
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            textView.textStorage?.setAttributes(
                attributes,
                range: NSRange(location: 0, length: (textView.string as NSString).length)
            )
            textView.typingAttributes = attributes
            textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
            textView.insertionPointColor = pendingStyle.color.nsColor
            undoManager?.enableUndoRegistration()
            appliedFont = pendingStyle.font
            appliedFontSize = pendingStyle.fontSize
            appliedColor = pendingStyle.color
        }
    }
}

/// The host's bounds stay in source pixels while AppKit scales its frame to canvas points.
private final class InlineTextEditorHost: NSView {
    let textView: InlineAnnotationTextView
    private let textLayout: EditorTextLayout
    private var didFocus = false
    var sourceSize: CGSize {
        didSet { updateGeometry() }
    }

    override var isFlipped: Bool { true }

    init(pending: PendingTextInsertion, sourceSize: CGSize) {
        self.sourceSize = sourceSize
        let layout = EditorTextLayout(
            text: pending.text,
            width: pending.width,
            font: pending.font,
            fontSize: pending.fontSize,
            color: pending.color
        )
        textLayout = layout
        textView = InlineAnnotationTextView(frame: .zero, textContainer: layout.textContainer)
        super.init(frame: CGRect(origin: .zero, size: sourceSize))
        textView.drawsBackground = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.setSelectedRange(NSRange(location: (pending.text as NSString).length, length: 0))
        textView.setAccessibilityLabel("Annotation text")
        addSubview(textView)
        updateGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, didFocus == false else {
            return
        }
        // Focus once per editing session, never on a SwiftUI text/style/zoom refresh.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.didFocus == false else {
                return
            }
            self.didFocus = window.makeFirstResponder(self.textView)
        }
    }

    private func updateGeometry() {
        bounds = CGRect(origin: .zero, size: sourceSize)
        textView.frame = CGRect(origin: .zero, size: sourceSize)
        if textLayout.textContainer.containerSize.width != sourceSize.width {
            textLayout.textContainer.containerSize = CGSize(
                width: sourceSize.width,
                height: .greatestFiniteMagnitude
            )
        }
    }
}

private final class InlineAnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onMarkedTextEnd: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || isCommitShortcut(event) {
            finishEditing()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isCommitShortcut(event) {
            finishEditing()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func unmarkText() {
        let hadMarkedText = hasMarkedText()
        super.unmarkText()
        if hadMarkedText {
            onMarkedTextEnd?()
        }
    }

    private func isCommitShortcut(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76) &&
            event.modifierFlags.contains(.command) &&
            event.modifierFlags.intersection([.control, .option]).isEmpty
    }

    private func finishEditing() {
        unmarkText()
        onCommit?()
    }
}
