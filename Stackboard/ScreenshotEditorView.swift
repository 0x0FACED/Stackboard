import SwiftUI

private enum EditorToolbarContextMode {
    case none
    case lineWidth
    case blur
    case text
}

struct ScreenshotEditorView: View {
    static let minimumContentSize = CGSize(width: 900, height: 620)
    static let chromeHeight: CGFloat = 65

    @ObservedObject var document: EditorDocument
    var minimumSize: CGSize = Self.minimumContentSize
    let onCopy: () -> Void

    private let palette: [EditorColor] = [.yellow, .red, .blue, .green, .white]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
                .frame(height: 1)
            EditorCanvasView(document: document)
        }
        .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
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
            .fixedSize()

            Divider()
                .frame(height: 20)

            HStack(spacing: 4) {
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
            }
            .fixedSize()

            if contextMode != .none {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        contextControl
                        if contextMode == .text {
                            textControls
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
            } else {
                Spacer(minLength: 0)
            }

            Button("Undo") {
                document.undoLastAnnotation()
            }
            .fixedSize()
            .help("Undo the last annotation")

            Button("Copy to Clipboard") {
                onCopy()
            }
            .keyboardShortcut(.defaultAction)
            .fixedSize()
            .help("Copy to Clipboard. Esc clears selection first, then copies and closes.")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.chromeHeight - 1)
    }

    @ViewBuilder
    private var contextControl: some View {
        switch contextMode {
        case .lineWidth:
            Slider(value: $document.lineWidth, in: 2 ... 16)
                .frame(width: 120)
                .accessibilityLabel("Line width")
                .help("Line width in image pixels")
        case .blur:
            Slider(
                value: Binding(
                    get: { document.currentBlurControlValue },
                    set: { document.setBlurControlValue($0) }
                ),
                in: 4 ... 28
            )
            .frame(width: 120)
            .accessibilityLabel("Blur radius")
            .help("Blur radius in image pixels")
            Text("\(Int(document.currentBlurControlValue.rounded()))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
        case .text:
            Slider(
                value: Binding(
                    get: { document.currentTextSizeControlValue },
                    set: { document.setTextSizeControlValue($0) }
                ),
                in: 14 ... 48
            )
            .frame(width: 120)
            .accessibilityLabel("Text size")
            .help("Text size in image pixels")
            Text("\(Int(document.currentTextSizeControlValue.rounded()))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
        case .none:
            EmptyView()
        }
    }

    private var textControls: some View {
        HStack(spacing: 8) {
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
            .frame(width: 120)
            .help(document.selectedTool == .text ? "Click the image to type" : "Selected text font")
        }
    }

    private func toolHelp(for tool: EditorTool) -> String {
        switch tool {
        case .move:
            return "Select blur or text to move and resize"
        case .text:
            return "Click the image to type"
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

                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 36, height: 36)
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
    @State private var liveMagnification: CGFloat = 1

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

            if let pendingTextInsertion = document.pendingTextInsertion {
                PendingTextInsertionOverlay(
                    pendingTextInsertion: pendingTextInsertion,
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
                guard let point = mapToImageSpace(location: value.location, canvasSize: canvasSize, clamp: false) else {
                    return
                }

                if didBeginInteraction == false {
                    didBeginInteraction = true
                    document.beginInteraction(at: point)
                } else {
                    document.updateInteraction(at: point)
                }
            }
            .onEnded { value in
                defer {
                    didBeginInteraction = false
                }

                guard let point = mapToImageSpace(location: value.location, canvasSize: canvasSize, clamp: true) else {
                    return
                }

                if didBeginInteraction == false {
                    document.beginInteraction(at: point)
                }
                document.endInteraction(at: point)
            }
    }

    private func mapToImageSpace(location: CGPoint, canvasSize: CGSize, clamp: Bool) -> CGPoint? {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return nil
        }

        let localBounds = CGRect(origin: .zero, size: canvasSize)

        if clamp == false, localBounds.contains(location) == false {
            return nil
        }

        let x = clamp ? min(max(location.x, localBounds.minX), localBounds.maxX) : location.x
        let y = clamp ? min(max(location.y, localBounds.minY), localBounds.maxY) : location.y
        let localX = x / canvasSize.width
        let localY = y / canvasSize.height

        return CGPoint(
            x: max(0, min(document.pixelSize.width, localX * document.pixelSize.width)),
            y: max(0, min(document.pixelSize.height, localY * document.pixelSize.height))
        )
    }
}

private struct AnnotationLayersView: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        GeometryReader { proxy in
            // Keep the same stacking order as export: blur patches replace earlier marks,
            // while annotations added after a blur remain above it.
            ZStack(alignment: .topLeading) {
                ForEach(document.committedAndActiveAnnotations) { annotation in
                    switch annotation {
                    case .stroke, .arrow:
                        AnnotationCanvasView(annotation: annotation, pixelSize: document.pixelSize)
                    case let .blur(blur):
                        if let image = document.blurImage(for: blur) {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .frame(
                                    width: blur.rect.width / document.pixelSize.width * proxy.size.width,
                                    height: blur.rect.height / document.pixelSize.height * proxy.size.height
                                )
                                .offset(
                                    x: blur.rect.minX / document.pixelSize.width * proxy.size.width,
                                    y: blur.rect.minY / document.pixelSize.height * proxy.size.height
                                )
                        }
                    case let .text(text):
                        AnnotationTextLayer(annotation: text, pixelSize: document.pixelSize)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
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
            // Transform pixel-space geometry and stroke widths together, including arrow heads.
            context.scaleBy(
                x: size.width / max(pixelSize.width, 1),
                y: size.height / max(pixelSize.height, 1)
            )
            switch annotation {
            case let .stroke(stroke):
                drawStroke(stroke, in: &context)
            case let .arrow(arrow):
                drawArrow(arrow, in: &context)
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

}

private struct AnnotationTextLayer: View {
    let annotation: EditorTextAnnotation
    let pixelSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let scale = min(
                proxy.size.width / max(pixelSize.width, 1),
                proxy.size.height / max(pixelSize.height, 1)
            )

            ZStack(alignment: .topLeading) {
                Text(annotation.text)
                    .font(annotation.font.swiftUIFont(size: annotation.fontSize * scale))
                    .foregroundStyle(Color(nsColor: annotation.color.nsColor))
                    .offset(
                        x: annotation.origin.x / pixelSize.width * proxy.size.width,
                        y: annotation.origin.y / pixelSize.height * proxy.size.height
                    )
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
    let pixelSize: CGSize
    let onTextChange: (String) -> Void
    let onCommit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let scale = min(
                proxy.size.width / max(pixelSize.width, 1),
                proxy.size.height / max(pixelSize.height, 1)
            )
            let x = pendingTextInsertion.origin.x / pixelSize.width * proxy.size.width
            let y = pendingTextInsertion.origin.y / pixelSize.height * proxy.size.height
            let availableWidth = max(proxy.size.width - x - 16, 180)
            let overlayWidth = min(max(CGFloat(220) * scale, 180), min(availableWidth, 360))

            TextField(
                "Type here",
                text: Binding(
                    get: { pendingTextInsertion.text },
                    set: onTextChange
                )
            )
            .textFieldStyle(.plain)
            .font(pendingTextInsertion.font.swiftUIFont(size: max(pendingTextInsertion.fontSize * scale, 14)))
            .foregroundStyle(Color(nsColor: pendingTextInsertion.color.nsColor))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: overlayWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.95), lineWidth: 1.5)
            )
            .offset(x: x, y: y)
            .focused($isFocused)
            .onAppear {
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
            .onSubmit(onCommit)
        }
    }
}
