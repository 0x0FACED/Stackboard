import AppKit

/// Geometry uses top-left source-image pixels, including hit-test tolerance and stroke widths.
@MainActor
enum EditorAnnotationGeometry {
    static func bounds(of annotation: EditorAnnotation, textSize: CGSize? = nil) -> CGRect {
        switch annotation {
        case let .stroke(stroke):
            return roundStrokeBounds(points: stroke.points, lineWidth: stroke.lineWidth)
        case let .eraser(eraser):
            return nonemptyBounds(of: eraser.path)
        case let .arrow(arrow):
            let head = arrowHead(arrow)
            let radius = max(arrow.lineWidth, 0) / 2
            let minX = min(arrow.start.x, arrow.end.x, head.left.x, head.right.x)
            let minY = min(arrow.start.y, arrow.end.y, head.left.y, head.right.y)
            let maxX = max(arrow.start.x, arrow.end.x, head.left.x, head.right.x)
            let maxY = max(arrow.start.y, arrow.end.y, head.left.y, head.right.y)
            return CGRect(
                x: minX - radius, y: minY - radius,
                width: maxX - minX + radius * 2, height: maxY - minY + radius * 2
            )
        case let .shape(shape):
            switch shape.style {
            case .filled:
                return shape.rect.standardized
            case .outline:
                guard shape.lineWidth > 0 else { return shape.rect.standardized }
                return nonemptyBounds(of: shape.path.copy(
                    strokingWithWidth: shape.lineWidth,
                    lineCap: .butt, lineJoin: .miter, miterLimit: 10
                ))
            }
        case let .blur(blur):
            return blur.rect.standardized
        case let .text(text):
            let size = textSize ?? EditorTextLayout(annotation: text).size
            return CGRect(origin: text.origin, size: size)
        }
    }

    static func contains(
        _ point: CGPoint,
        in annotation: EditorAnnotation,
        tolerance: CGFloat = 8,
        textSize: CGSize? = nil
    ) -> Bool {
        let tolerance = max(tolerance, 0)
        switch annotation {
        case let .stroke(stroke):
            guard let first = stroke.points.first else { return false }
            let radius = max(stroke.lineWidth, 0) / 2 + tolerance
            if stroke.points.count == 1 {
                return hypot(point.x - first.x, point.y - first.y) <= radius
            }
            var start = first
            for end in stroke.points.dropFirst() {
                if segmentContains(point, from: start, to: end, radius: radius) {
                    return true
                }
                start = end
            }
            return false
        case .eraser:
            // Masks occlude earlier objects; they are never selectable objects themselves.
            return false
        case let .arrow(arrow):
            let head = arrowHead(arrow)
            let radius = max(arrow.lineWidth, 0) / 2 + tolerance
            return segmentContains(point, from: arrow.start, to: arrow.end, radius: radius)
                || segmentContains(point, from: arrow.end, to: head.left, radius: radius)
                || segmentContains(point, from: arrow.end, to: head.right, radius: radius)
        case let .shape(shape):
            let path = shape.path
            switch shape.style {
            case .filled:
                return filledPathContains(point, path: path, tolerance: tolerance)
            case .outline:
                let width = max(shape.lineWidth, 0) + tolerance * 2
                guard width > 0 else { return false }
                return path.copy(
                    strokingWithWidth: width,
                    lineCap: .butt, lineJoin: .miter, miterLimit: 10
                ).contains(point)
            }
        case let .blur(blur):
            return filledPathContains(
                point, path: CGPath(rect: blur.rect, transform: nil), tolerance: tolerance
            )
        case .text:
            return bounds(of: annotation, textSize: textSize)
                .insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    static func translated(_ annotation: EditorAnnotation, by delta: CGSize) -> EditorAnnotation {
        guard delta != .zero else { return annotation }
        switch annotation {
        case var .stroke(stroke):
            for index in stroke.points.indices {
                stroke.points[index] = translated(stroke.points[index], by: delta)
            }
            return .stroke(stroke)
        case var .eraser(eraser):
            for index in eraser.points.indices {
                eraser.points[index] = translated(eraser.points[index], by: delta)
            }
            return .eraser(eraser)
        case var .arrow(arrow):
            arrow.start = translated(arrow.start, by: delta)
            arrow.end = translated(arrow.end, by: delta)
            return .arrow(arrow)
        case var .shape(shape):
            shape.rect.origin = translated(shape.rect.origin, by: delta)
            return .shape(shape)
        case var .blur(blur):
            blur.rect.origin = translated(blur.rect.origin, by: delta)
            return .blur(blur)
        case var .text(text):
            text.origin = translated(text.origin, by: delta)
            return .text(text)
        }
    }

    static func resized(
        _ annotation: EditorAnnotation,
        from sourceRect: CGRect,
        to targetRect: CGRect
    ) -> EditorAnnotation {
        guard sourceRect != targetRect else { return annotation }
        let source = sourceRect.standardized
        let target = targetRect.standardized
        switch annotation {
        case var .stroke(stroke):
            let radius = max(stroke.lineWidth, 0) / 2
            let sourceCenterline = insetAllowingCollapse(source, by: radius)
            let targetCenterline = insetAllowingCollapse(target, by: radius)
            for index in stroke.points.indices {
                stroke.points[index] = mapped(
                    stroke.points[index], from: sourceCenterline, to: targetCenterline
                )
            }
            return .stroke(stroke)
        case .eraser:
            return annotation
        case var .arrow(arrow):
            // Endpoint handles are the normal arrow resize operation. A rectangular transform
            // moves its endpoints but intentionally does not scale its width or arrowhead.
            let radius = max(arrow.lineWidth, 0) / 2
            let sourceCenterline = insetAllowingCollapse(source, by: radius)
            let targetCenterline = insetAllowingCollapse(target, by: radius)
            arrow.start = mapped(arrow.start, from: sourceCenterline, to: targetCenterline)
            arrow.end = mapped(arrow.end, from: sourceCenterline, to: targetCenterline)
            return .arrow(arrow)
        case var .shape(shape):
            switch shape.style {
            case .filled:
                shape.rect = target
            case .outline:
                shape.rect = insetAllowingCollapse(target, by: max(shape.lineWidth, 0) / 2)
            }
            return .shape(shape)
        case var .blur(blur):
            blur.rect = target
            return .blur(blur)
        case var .text(text):
            text.origin = target.origin
            text.width = max(target.width, 1)
            return .text(text)
        }
    }

    static func duplicate(_ annotation: EditorAnnotation) -> EditorAnnotation {
        let id = UUID()
        switch annotation {
        case var .stroke(stroke):
            stroke.id = id
            return .stroke(stroke)
        case var .eraser(eraser):
            eraser.id = id
            return .eraser(eraser)
        case var .arrow(arrow):
            arrow.id = id
            return .arrow(arrow)
        case var .shape(shape):
            shape.id = id
            return .shape(shape)
        case var .blur(blur):
            blur.id = id
            return .blur(blur)
        case var .text(text):
            text.id = id
            return .text(text)
        }
    }

    static func arrowPath(_ arrow: EditorArrow) -> CGPath {
        let head = arrowHead(arrow)
        let path = CGMutablePath()
        path.move(to: arrow.start)
        path.addLine(to: arrow.end)
        path.move(to: arrow.end)
        path.addLine(to: head.left)
        path.move(to: arrow.end)
        path.addLine(to: head.right)
        return path
    }

    private static func arrowHead(_ arrow: EditorArrow) -> (left: CGPoint, right: CGPoint) {
        let angle = atan2(arrow.end.y - arrow.start.y, arrow.end.x - arrow.start.x)
        let length = max(arrow.lineWidth * 2.6, 18)
        let headAngle = CGFloat.pi / 7
        return (
            CGPoint(
                x: arrow.end.x - length * cos(angle - headAngle),
                y: arrow.end.y - length * sin(angle - headAngle)
            ),
            CGPoint(
                x: arrow.end.x - length * cos(angle + headAngle),
                y: arrow.end.y - length * sin(angle + headAngle)
            )
        )
    }

    private static func roundStrokeBounds(points: [CGPoint], lineWidth: CGFloat) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let radius = max(lineWidth, 0) / 2
        return CGRect(
            x: minX - radius, y: minY - radius,
            width: maxX - minX + radius * 2, height: maxY - minY + radius * 2
        )
    }

    private static func nonemptyBounds(of path: CGPath) -> CGRect {
        let rect = path.boundingBoxOfPath
        return rect.isNull ? .zero : rect
    }

    private static func segmentContains(
        _ point: CGPoint, from start: CGPoint, to end: CGPoint, radius: CGFloat
    ) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else {
            return hypot(point.x - start.x, point.y - start.y) <= radius
        }
        let unitX = dx / length
        let unitY = dy / length
        let distanceAlong = min(max(
            (point.x - start.x) * unitX + (point.y - start.y) * unitY, 0
        ), length)
        return hypot(
            point.x - (start.x + unitX * distanceAlong),
            point.y - (start.y + unitY * distanceAlong)
        ) <= radius
    }

    private static func filledPathContains(
        _ point: CGPoint, path: CGPath, tolerance: CGFloat
    ) -> Bool {
        if path.contains(point) { return true }
        guard tolerance > 0 else { return false }
        return path.copy(
            strokingWithWidth: tolerance * 2,
            lineCap: .round, lineJoin: .round, miterLimit: 10
        ).contains(point)
    }

    private static func translated(_ point: CGPoint, by delta: CGSize) -> CGPoint {
        CGPoint(x: point.x + delta.width, y: point.y + delta.height)
    }

    /// A target narrower than the unchanged brush cannot contain it. Collapse that centerline
    /// axis at the target midpoint rather than divide by zero or reverse the geometry.
    private static func insetAllowingCollapse(_ rect: CGRect, by inset: CGFloat) -> CGRect {
        let width = max(rect.width - inset * 2, 0)
        let height = max(rect.height - inset * 2, 0)
        return CGRect(
            x: rect.midX - width / 2, y: rect.midY - height / 2,
            width: width, height: height
        )
    }

    private static func mapped(_ point: CGPoint, from source: CGRect, to target: CGRect) -> CGPoint {
        CGPoint(
            x: mapped(point.x, from: source.minX, length: source.width,
                      to: target.minX, length: target.width),
            y: mapped(point.y, from: source.minY, length: source.height,
                      to: target.minY, length: target.height)
        )
    }

    private static func mapped(
        _ value: CGFloat, from sourceOrigin: CGFloat, length sourceLength: CGFloat,
        to targetOrigin: CGFloat, length targetLength: CGFloat
    ) -> CGFloat {
        if sourceLength == targetLength { return value + (targetOrigin - sourceOrigin) }
        // A zero-extent axis cannot be stretched. Keep its leading brush edge anchored.
        guard sourceLength > 0 else { return targetOrigin }
        return targetOrigin + (value - sourceOrigin) / sourceLength * targetLength
    }
}

extension EditorAnnotation {
    var editableKind: EditableAnnotationKind? {
        switch self {
        case .stroke: return .stroke
        case .eraser: return nil
        case .arrow: return .arrow
        case .shape: return .shape
        case .blur: return .blur
        case .text: return .text
        }
    }

    var color: EditorColor? {
        switch self {
        case let .stroke(stroke): return stroke.color
        case let .arrow(arrow): return arrow.color
        case let .shape(shape): return shape.color
        case let .text(text): return text.color
        case .eraser, .blur: return nil
        }
    }

    var lineWidth: CGFloat? {
        switch self {
        case let .stroke(stroke): return stroke.lineWidth
        case let .arrow(arrow): return arrow.lineWidth
        case let .shape(shape): return shape.lineWidth
        case .eraser, .blur, .text: return nil
        }
    }

    func withColor(_ color: EditorColor) -> EditorAnnotation {
        guard self.color != color else { return self }
        switch self {
        case var .stroke(stroke):
            stroke.color = color
            return .stroke(stroke)
        case var .arrow(arrow):
            arrow.color = color
            return .arrow(arrow)
        case var .shape(shape):
            shape.color = color
            return .shape(shape)
        case var .text(text):
            text.color = color
            return .text(text)
        case .eraser, .blur:
            return self
        }
    }

    func withLineWidth(_ width: CGFloat) -> EditorAnnotation {
        guard lineWidth != width else { return self }
        switch self {
        case var .stroke(stroke):
            stroke.lineWidth = width
            return .stroke(stroke)
        case var .arrow(arrow):
            arrow.lineWidth = width
            return .arrow(arrow)
        case var .shape(shape):
            shape.lineWidth = width
            return .shape(shape)
        case .eraser, .blur, .text:
            return self
        }
    }
}
