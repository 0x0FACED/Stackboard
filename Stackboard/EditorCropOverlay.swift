import AppKit
import SwiftUI

/// The draft stays in source pixels; only the handles and guides use display points.
struct EditorCropOverlay: View {
    @ObservedObject var document: EditorDocument
    let canvasSize: CGSize
    @State private var dragStartRect: CGRect?
    @State private var isMovingSelection = false

    var body: some View {
        if let crop = document.cropRect {
            let rect = displayRect(crop)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    var mask = Path(CGRect(origin: .zero, size: size))
                    mask.addRect(rect)
                    context.fill(mask, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

                    var guides = Path()
                    for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                        let x = rect.minX + rect.width * fraction
                        let y = rect.minY + rect.height * fraction
                        guides.move(to: CGPoint(x: x, y: rect.minY))
                        guides.addLine(to: CGPoint(x: x, y: rect.maxY))
                        guides.move(to: CGPoint(x: rect.minX, y: y))
                        guides.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                    context.stroke(guides, with: .color(.white.opacity(0.4)), lineWidth: 1)
                    context.stroke(Path(rect), with: .color(.black.opacity(0.7)), lineWidth: 3)
                    context.stroke(Path(rect), with: .color(.white), lineWidth: 1)
                }
                .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(selectionGesture)
                    .accessibilityLabel("Crop selection")
                    .help("Drag inside to move the crop, outside to select a new area")

                ForEach(CropHandle.allCases) { handle in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white)
                        .overlay(RoundedRectangle(cornerRadius: 1).stroke(.black.opacity(0.6), lineWidth: 1))
                        .frame(width: 10, height: 10)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .position(handlePosition(handle, in: rect))
                        .gesture(resizeGesture(handle))
                        .accessibilityLabel(handle.label)
                        .help("Drag to resize the crop")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged(updateSelection)
            .onEnded { value in
                updateSelection(value)
                dragStartRect = nil
            }
    }

    private func updateSelection(_ value: DragGesture.Value) {
        guard let current = document.cropRect else { return }
        if dragStartRect == nil {
            dragStartRect = current
            isMovingSelection = displayRect(current).contains(value.startLocation)
        }
        guard let start = dragStartRect else { return }
        if isMovingSelection {
            let delta = pixelTranslation(value.translation)
            document.updateCropRect(CGRect(
                x: min(max((start.minX + delta.width).rounded(), 0), document.pixelSize.width - start.width),
                y: min(max((start.minY + delta.height).rounded(), 0), document.pixelSize.height - start.height),
                width: start.width, height: start.height
            ))
        } else {
            let start = pixelPoint(value.startLocation)
            let end = pixelPoint(value.location)
            document.updateCropRect(CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            ))
        }
    }

    private func resizeGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { updateResize(handle, value: $0) }
            .onEnded { value in
                updateResize(handle, value: value)
                dragStartRect = nil
            }
    }

    private func updateResize(_ handle: CropHandle, value: DragGesture.Value) {
        guard let current = document.cropRect else { return }
        if dragStartRect == nil { dragStartRect = current }
        guard let start = dragStartRect else { return }
        let delta = pixelTranslation(value.translation)
        var left = start.minX
        var top = start.minY
        var right = start.maxX
        var bottom = start.maxY
        if handle.movesLeft { left = min(max(left + delta.width, 0), right - 1) }
        if handle.movesRight { right = max(min(right + delta.width, document.pixelSize.width), left + 1) }
        if handle.movesTop { top = min(max(top + delta.height, 0), bottom - 1) }
        if handle.movesBottom { bottom = max(min(bottom + delta.height, document.pixelSize.height), top + 1) }
        document.updateCropRect(CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }

    private func displayRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX / max(document.pixelSize.width, 1) * canvasSize.width,
            y: rect.minY / max(document.pixelSize.height, 1) * canvasSize.height,
            width: rect.width / max(document.pixelSize.width, 1) * canvasSize.width,
            height: rect.height / max(document.pixelSize.height, 1) * canvasSize.height
        )
    }

    private func pixelPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x / max(canvasSize.width, .ulpOfOne) * document.pixelSize.width).rounded(),
            y: (point.y / max(canvasSize.height, .ulpOfOne) * document.pixelSize.height).rounded()
        )
    }

    private func pixelTranslation(_ translation: CGSize) -> CGSize {
        CGSize(
            width: (translation.width / max(canvasSize.width, .ulpOfOne) * document.pixelSize.width).rounded(),
            height: (translation.height / max(canvasSize.height, .ulpOfOne) * document.pixelSize.height).rounded()
        )
    }

    private func handlePosition(_ handle: CropHandle, in rect: CGRect) -> CGPoint {
        let x = handle.movesLeft ? rect.minX : (handle.movesRight ? rect.maxX : rect.midX)
        let y = handle.movesTop ? rect.minY : (handle.movesBottom ? rect.maxY : rect.midY)
        // Keep the hit targets usable even when the draft touches the image edges.
        return CGPoint(
            x: min(max(x, 6), max(canvasSize.width - 6, 6)),
            y: min(max(y, 6), max(canvasSize.height - 6, 6))
        )
    }
}

private enum CropHandle: CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var id: Self { self }
    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    var label: String {
        switch self {
        case .topLeft: return "Crop top left"
        case .top: return "Crop top edge"
        case .topRight: return "Crop top right"
        case .right: return "Crop right edge"
        case .bottomRight: return "Crop bottom right"
        case .bottom: return "Crop bottom edge"
        case .bottomLeft: return "Crop bottom left"
        case .left: return "Crop left edge"
        }
    }
}
