import AppKit
import Combine
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
    @StateObject private var nativeInput = EditorNativeInputState()
    var minimumSize: CGSize = Self.minimumContentSize
    let onCopy: () -> Void

    private let palette: [EditorColor] = [.yellow, .red, .blue, .green, .white]

    var body: some View {
        HStack(spacing: 0) {
            toolbar
            Divider()
                .frame(width: 1)
            EditorCanvasView(document: document, nativeInput: nativeInput)
        }
        .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            EditorKeyboardMonitorView(
                document: document,
                nativeInput: nativeInput,
                onCopy: copyToClipboard
            )
        )
        .onAppear {
            NSColorPanel.shared.isContinuous = false
        }
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
                                if document.selectedTool != tool {
                                    nativeInput.finishAnnotationEditing()
                                }
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
                                nativeInput.finishNumberEditing()
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
                                    nativeInput.finishNumberEditing()
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

                    if document.selectedAnnotation != nil {
                        Divider()
                        HStack {
                            Button("Duplicate") {
                                document.duplicateSelectedAnnotation()
                            }
                            .help("Duplicate selected object (⌘D)")
                            Button("Delete") {
                                document.deleteSelectedAnnotation()
                            }
                            .help("Delete selected object (Delete)")
                        }
                        .disabled(usesNativeHistory)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.never)

            Divider()

            VStack(spacing: 8) {
                HStack {
                    Button {
                        if usesNativeHistory {
                            nativeInput.undo()
                        } else {
                            document.undo()
                        }
                    } label: {
                        Text("Undo")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(usesNativeHistory ? !nativeInput.canUndo : !document.canUndo)
                    .help(historyHelp(isRedo: false))
                    .focusable(false)

                    Button {
                        if usesNativeHistory {
                            nativeInput.redo()
                        } else {
                            document.redo()
                        }
                    } label: {
                        Text("Redo")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(usesNativeHistory ? !nativeInput.canRedo : !document.canRedo)
                    .help(historyHelp(isRedo: true))
                    .focusable(false)
                }

                Button(action: copyToClipboard) {
                    Text("Copy to Clipboard")
                        .frame(maxWidth: .infinity)
                }
                .help("Copy to Clipboard. Esc clears selection first, then copies and closes.")
            }
            .padding(12)
        }
        .frame(width: Self.sidebarWidth - 1)
    }

    private func copyToClipboard() {
        nativeInput.finishAnnotationEditing()
        onCopy()
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
                Picker(
                    "Shape style",
                    selection: Binding(
                        get: { document.currentShapeStyle },
                        set: {
                            nativeInput.finishNumberEditing()
                            document.setShapeStyle($0)
                        }
                    )
                ) {
                    ForEach(EditorShapeStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if document.currentShapeStyle == .outline {
                    lineWidthControl
                }
                Text(document.selectedTool == .move ? "Hold Shift to keep proportions" :
                    document.selectedTool == .rectangle ? "Hold Shift for a square" : "Hold Shift for a circle")
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
                    in: 4 ... 28,
                    onEditingChanged: editStyle
                )
                .accessibilityLabel("Blur radius")
                .help("Blur radius in image pixels")
            case .text:
                HStack {
                    Text("Text size")
                    Spacer()
                    EditorNumberField(
                        value: document.currentTextSizeControlValue,
                        nativeInput: nativeInput,
                        onChange: document.setTextSizeControlValue,
                        onBeginEditing: document.beginStyleEditing,
                        onEndEditing: document.endStyleEditing
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 58, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                    )
                    .accessibilityLabel("Text size in image pixels")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { document.currentTextSizeControlValue },
                        set: { document.setTextSizeControlValue($0) }
                    ),
                    in: 8 ... 256,
                    onEditingChanged: editStyle
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
            Slider(
                value: Binding(
                    get: { document.currentLineWidthControlValue },
                    set: { document.setLineWidthControlValue($0) }
                ),
                in: 2 ... 16,
                onEditingChanged: editStyle
            )
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
                set: {
                    nativeInput.finishNumberEditing()
                    document.setTextFont($0)
                }
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
                nativeInput.finishAnnotationEditing()
                document.commitPendingTextInsertion()
            }
            .help("Finish editing text (⌘Enter or Esc)")
        } else if document.selectedAnnotation?.kind == .text {
            Button("Edit") {
                document.beginEditingSelectedText()
            }
            .help("Edit selected text (Enter)")
        }

        Text("Enter: new line · ⌘Enter: done\nMove: double-click to edit\nDrag the handle to change width")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toolHelp(for tool: EditorTool) -> String {
        switch tool {
        case .move:
            return "Select any object to move. Drag handles to resize or adjust arrow endpoints; double-click text to edit."
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
            case .stroke?, .arrow?:
                return .lineWidth
            case .shape?:
                return .shape
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

    private var usesNativeHistory: Bool {
        document.pendingTextInsertion != nil || nativeInput.hasActiveInput
    }

    private func editStyle(_ isEditing: Bool) {
        if isEditing {
            nativeInput.finishNumberEditing()
            document.beginStyleEditing()
        } else {
            document.endStyleEditing()
        }
    }

    private func historyHelp(isRedo: Bool) -> String {
        let verb = isRedo ? "Redo" : "Undo"
        let name = usesNativeHistory ?
            (isRedo ? nativeInput.redoActionName : nativeInput.undoActionName) :
            (isRedo ? document.redoActionName : document.undoActionName)
        return "\(verb)\(name.isEmpty ? "" : " \(name)") (\(isRedo ? "⇧⌘Z" : "⌘Z"))"
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
    @ObservedObject var nativeInput: EditorNativeInputState
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
                    nativeInput: nativeInput,
                    onTextChange: document.setPendingText,
                    onCommit: {
                        nativeInput.finishAnnotationEditing()
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
                if didBeginInteraction == false {
                    guard let start = mapToImageSpace(
                        location: value.startLocation, canvasSize: canvasSize, clamp: false
                    ) else { return }
                    beginCanvasInteraction(at: start)
                }
                guard isEditingDoubleClick == false else { return }
                let rawEndpoint = allowsRawDragEndpoint
                guard let point = mapToImageSpace(
                    location: value.location, canvasSize: canvasSize,
                    clamp: rawEndpoint == false, allowOutsideBounds: rawEndpoint
                ) else { return }
                if document.selectedTool == .eraser { eraserCursorLocation = value.location }
                document.updateInteraction(
                    at: point,
                    constrainProportions: (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift)
                )
            }
            .onEnded { value in
                defer {
                    didBeginInteraction = false
                    isEditingDoubleClick = false
                }
                if didBeginInteraction == false {
                    guard let start = mapToImageSpace(
                        location: value.startLocation, canvasSize: canvasSize, clamp: false
                    ) else { return }
                    beginCanvasInteraction(at: start)
                }
                guard isEditingDoubleClick == false else { return }
                let rawEndpoint = allowsRawDragEndpoint
                guard let point = mapToImageSpace(
                    location: value.location, canvasSize: canvasSize,
                    clamp: rawEndpoint == false, allowOutsideBounds: rawEndpoint
                ) else { return }
                if document.selectedTool == .eraser { eraserCursorLocation = value.location }
                document.endInteraction(
                    at: point,
                    constrainProportions: (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift)
                )
            }
    }

    private var allowsRawDragEndpoint: Bool {
        document.selectedTool == .move || document.selectedTool == .eraser ||
            document.selectedTool == .rectangle || document.selectedTool == .ellipse
    }

    private func beginCanvasInteraction(at point: CGPoint) {
        nativeInput.finishNumberEditing()
        didBeginInteraction = true
        // The first delivered drag event may already be far from the original mouse-down.
        if document.selectedTool == .move, (NSApp.currentEvent?.clickCount ?? 0) == 2,
           document.beginEditingText(at: point) {
            isEditingDoubleClick = true
        } else {
            document.beginInteraction(at: point)
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
        guard let first = stroke.points.first else {
            return
        }
        if stroke.points.count == 1 {
            context.fill(
                Path(ellipseIn: CGRect(
                    x: first.x - stroke.lineWidth / 2,
                    y: first.y - stroke.lineWidth / 2,
                    width: stroke.lineWidth,
                    height: stroke.lineWidth
                )),
                with: .color(Color(nsColor: stroke.color.nsColor))
            )
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
        context.stroke(
            Path(EditorAnnotationGeometry.arrowPath(arrow)),
            with: .color(Color(nsColor: arrow.color.nsColor)),
            style: StrokeStyle(lineWidth: arrow.lineWidth, lineCap: .round, lineJoin: .round)
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
            if let secondaryHandleRect = overlay.secondaryHandleRect {
                let secondaryHandle = Path(ellipseIn: scale(rect: secondaryHandleRect, size: size))
                context.fill(secondaryHandle, with: .color(.white))
                context.stroke(
                    secondaryHandle,
                    with: .color(Color.accentColor.opacity(0.95)),
                    lineWidth: 2
                )
            }
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
    let nativeInput: EditorNativeInputState
    let onTextChange: (String) -> Void
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let scaleX = proxy.size.width / max(pixelSize.width, 1)
            let scaleY = proxy.size.height / max(pixelSize.height, 1)

            InlineTextEditor(
                pending: pendingTextInsertion,
                sourceSize: textBounds.size,
                nativeInput: nativeInput,
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
    let nativeInput: EditorNativeInputState
    let onTextChange: (String) -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(nativeInput: nativeInput, sessionID: pending.id, onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> InlineTextEditorHost {
        let host = InlineTextEditorHost(pending: pending, sourceSize: sourceSize)
        host.textView.delegate = context.coordinator
        host.textView.onBeginEditing = { [weak coordinator = context.coordinator, weak textView = host.textView] in
            guard let coordinator, let textView else {
                return
            }
            coordinator.beginSession(in: textView)
        }
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
        host.textView.onBeginEditing = nil
        coordinator.endSession()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: (String) -> Void
        var lastPublishedText = ""
        var pendingStyle: PendingTextInsertion?
        private let nativeInput: EditorNativeInputState
        private let sessionID: UUID
        private var appliedFont: EditorTextFont?
        private var appliedFontSize: CGFloat?
        private var appliedColor: EditorColor?
        private let editingUndoManager = UndoManager()

        init(nativeInput: EditorNativeInputState, sessionID: UUID, onTextChange: @escaping (String) -> Void) {
            self.nativeInput = nativeInput
            self.sessionID = sessionID
            self.onTextChange = onTextChange
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            beginSession(in: textView)
        }

        func beginSession(in textView: NSTextView) {
            nativeInput.beginSession(
                id: sessionID,
                textView: textView,
                undoManager: editingUndoManager,
                isAnnotation: true
            )
        }

        func endSession() {
            DispatchQueue.main.async { [nativeInput, sessionID] in
                nativeInput.endSession(id: sessionID)
            }
            editingUndoManager.removeAllActions()
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
            nativeInput.refreshNextTurn()
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
    var onBeginEditing: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            onBeginEditing?()
        }
        return becameFirstResponder
    }

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

/// Shares only this editor's native input history with its sidebar and shortcut handler.
@MainActor
private final class EditorNativeInputState: ObservableObject {
    @Published private(set) var hasActiveInput = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoActionName = ""
    @Published private(set) var redoActionName = ""

    private final class Session {
        let id: UUID
        weak var textView: NSTextView?
        let undoManager: UndoManager

        init(id: UUID, textView: NSTextView, undoManager: UndoManager) {
            self.id = id
            self.textView = textView
            self.undoManager = undoManager
        }
    }

    private var annotationSession: Session?
    private var numberSession: Session?
    private var observers: [NSObjectProtocol] = []
    private var activeSession: Session? { numberSession ?? annotationSession }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func beginSession(id: UUID, textView: NSTextView, undoManager: UndoManager, isAnnotation: Bool) {
        let session = Session(id: id, textView: textView, undoManager: undoManager)
        if isAnnotation {
            annotationSession = session
        } else {
            numberSession = session
        }
        observeActiveSession()
        refresh()
    }

    func endSession(id: UUID) {
        if annotationSession?.id == id {
            annotationSession = nil
        }
        if numberSession?.id == id {
            numberSession = nil
        }
        observeActiveSession()
        refresh()
    }

    func finishNumberEditing() {
        if let numberView = numberSession?.textView {
            numberView.unmarkText()
            numberView.window?.makeFirstResponder(nil)
        }
    }

    func finishAnnotationEditing() {
        finishNumberEditing()
        if let session = annotationSession {
            session.textView?.unmarkText()
            session.textView?.window?.makeFirstResponder(nil)
            endSession(id: session.id)
        }
    }

    func refreshNextTurn() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    func undo() {
        performHistory(isRedo: false)
    }

    func redo() {
        performHistory(isRedo: true)
    }

    func performHistory(isRedo: Bool, in textView: NSTextView? = nil) {
        guard let view = textView ?? activeSession?.textView, view.window != nil,
              let manager = textView?.undoManager ?? activeSession?.undoManager else {
            refresh()
            return
        }
        view.window?.makeFirstResponder(view)
        view.breakUndoCoalescing()
        if isRedo {
            if manager.canRedo {
                manager.redo()
            }
        } else if manager.canUndo {
            manager.undo()
        }
        refresh()
    }

    private func refresh() {
        let session = activeSession
        let manager = session?.textView?.window == nil ? nil : session?.undoManager
        hasActiveInput = manager != nil
        canUndo = manager?.canUndo == true
        canRedo = manager?.canRedo == true
        undoActionName = canUndo ? manager?.undoActionName ?? "" : ""
        redoActionName = canRedo ? manager?.redoActionName ?? "" : ""
    }

    private func observeActiveSession() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        guard let manager = activeSession?.undoManager else {
            return
        }
        for name in [
            Notification.Name.NSUndoManagerDidCloseUndoGroup,
            Notification.Name.NSUndoManagerDidUndoChange,
            Notification.Name.NSUndoManagerDidRedoChange,
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: manager,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.refresh()
                }
            })
        }
    }
}

/// Attaching this view, not an app controller, installs window-local editor shortcuts.
private struct EditorKeyboardMonitorView: NSViewRepresentable {
    let document: EditorDocument
    let nativeInput: EditorNativeInputState
    let onCopy: () -> Void

    func makeNSView(context: Context) -> EditorKeyboardMonitorHost {
        let host = EditorKeyboardMonitorHost()
        updateNSView(host, context: context)
        return host
    }

    func updateNSView(_ host: EditorKeyboardMonitorHost, context: Context) {
        host.handleKey = { [weak document, weak nativeInput] event, window in
            guard let document, let nativeInput else {
                return event
            }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let nativeTextView = window.firstResponder as? NSTextView
            let hasNativeInput = nativeTextView != nil ||
                window.firstResponder is NSTextField || nativeInput.hasActiveInput ||
                document.pendingTextInsertion != nil

            if modifiers == .command || modifiers == [.command, .shift] {
                if event.keyCode == 6 || event.charactersIgnoringModifiers?.lowercased() == "z" {
                    let isRedo = modifiers.contains(.shift)
                    if hasNativeInput {
                        nativeInput.performHistory(isRedo: isRedo, in: nativeTextView)
                    } else if isRedo {
                        document.redo()
                    } else {
                        document.undo()
                    }
                    return nil
                }
                if modifiers == .command,
                   (event.keyCode == 2 || event.charactersIgnoringModifiers?.lowercased() == "d"),
                   hasNativeInput == false {
                    if event.isARepeat == false {
                        document.duplicateSelectedAnnotation()
                    }
                    return nil
                }
            }

            if event.keyCode == 53, nativeTextView == nil,
               document.pendingTextInsertion != nil,
               modifiers.intersection([.command, .control, .option]).isEmpty {
                nativeInput.finishAnnotationEditing()
                _ = document.handleEscape()
                return nil
            }

            guard modifiers.intersection([.command, .control, .option]).isEmpty,
                  hasNativeInput == false else {
                return event
            }
            switch event.keyCode {
            case 36, 76:
                if document.beginEditingSelectedText() {
                    return nil
                }
            case 51, 117:
                if event.isARepeat == false, document.deleteSelectedAnnotation() {
                    return nil
                }
            case 53:
                if document.handleEscape() == false {
                    onCopy()
                }
                return nil
            default:
                break
            }
            return event
        }
    }

    static func dismantleNSView(_ host: EditorKeyboardMonitorHost, coordinator: ()) {
        host.removeMonitor()
        host.handleKey = nil
    }
}

private final class EditorKeyboardMonitorHost: NSView {
    var handleKey: ((NSEvent, NSWindow) -> NSEvent?)?
    private var keyboardMonitor: Any?
    private var closeObserver: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard let window else {
            return
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else {
                return event
            }
            guard let handleKey = self.handleKey else {
                return event
            }
            return handleKey(event, window)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.removeMonitor()
        }
    }

    func removeMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }

    deinit {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}

/// A single-line native input with a fresh undo manager for each focus session.
private struct EditorNumberField: NSViewRepresentable {
    let value: Double
    let nativeInput: EditorNativeInputState
    let onChange: (Double) -> Void
    let onBeginEditing: () -> Void
    let onEndEditing: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(field: self)
    }

    func makeNSView(context: Context) -> EditorNumberTextView {
        let view = EditorNumberTextView(initialValue: context.coordinator.formatted(value))
        view.delegate = context.coordinator
        view.onBeginEditing = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.beginEditing(view)
        }
        view.onEndEditing = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.endEditing(view)
        }
        view.setAccessibilityLabel("Text size in image pixels")
        return view
    }

    func updateNSView(_ view: EditorNumberTextView, context: Context) {
        context.coordinator.field = self
        if context.coordinator.isEditing == false {
            view.string = context.coordinator.formatted(value)
        }
    }

    static func dismantleNSView(_ view: EditorNumberTextView, coordinator: Coordinator) {
        view.onBeginEditing = nil
        view.onEndEditing = nil
        view.delegate = nil
        DispatchQueue.main.async {
            coordinator.endEditing(view)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var field: EditorNumberField
        private(set) var isEditing = false
        private var sessionID = UUID()
        private let editingUndoManager = UndoManager()
        private let formatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 1
            return formatter
        }()

        init(field: EditorNumberField) {
            self.field = field
        }

        func formatted(_ value: Double) -> String {
            formatter.string(from: NSNumber(value: value)) ?? String(value)
        }

        func beginEditing(_ view: NSTextView) {
            guard isEditing == false else { return }
            isEditing = true
            sessionID = UUID()
            editingUndoManager.removeAllActions()
            field.onBeginEditing()
            field.nativeInput.beginSession(
                id: sessionID,
                textView: view,
                undoManager: editingUndoManager,
                isAnnotation: false
            )
        }

        func endEditing(_ view: NSTextView) {
            guard isEditing else { return }
            isEditing = false
            view.breakUndoCoalescing()
            view.string = formatted(field.value)
            field.onEndEditing()
            field.nativeInput.endSession(id: sessionID)
            editingUndoManager.removeAllActions()
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            editingUndoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if view.hasMarkedText() == false, let number = formatter.number(from: view.string) {
                field.onChange(number.doubleValue)
            }
            field.nativeInput.refreshNextTurn()
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            replacementString?.rangeOfCharacter(from: .newlines) == nil
        }
    }
}

private final class EditorNumberTextView: NSTextView {
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    private let backingTextStorage: NSTextStorage

    init(initialValue: String) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 58, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        backingTextStorage = storage
        super.init(frame: CGRect(x: 0, y: 0, width: 58, height: 24), textContainer: container)
        string = initialValue
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        font = .systemFont(ofSize: 12)
        textColor = .labelColor
        alignment = .right
        textContainerInset = CGSize(width: 3, height: 4)
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.maximumNumberOfLines = 1
        textContainer?.lineBreakMode = .byClipping
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            onBeginEditing?()
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onEndEditing?()
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 || event.keyCode == 48 {
            unmarkText()
            window?.makeFirstResponder(nil)
            return
        }
        super.keyDown(with: event)
    }
}
