import AppKit

// Run from any directory: xcrun swift /path/to/Stackboard/scripts/generate-icons.swift
// Only the generated PNGs are written; asset-catalog metadata remains versioned separately.

@MainActor
func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

@MainActor
func gradient(_ path: NSBezierPath, bottom: UInt32, top: UInt32) {
    NSGradient(starting: color(bottom), ending: color(top))!.draw(in: path, angle: 90)
}

@MainActor
func shadowedFill(_ path: NSBezierPath, color: NSColor, blur: CGFloat, offset: CGFloat, opacity: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    // NSShadow uses the context's base coordinates, not the scaled artwork coordinates.
    let scale = abs(NSGraphicsContext.current!.cgContext.ctm.a)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
    shadow.shadowBlurRadius = blur * scale
    shadow.shadowOffset = NSSize(width: 0, height: offset * scale)
    shadow.set()
    color.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

@MainActor
func drawAppIcon() {
    let background = NSBezierPath(
        roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200
    )
    shadowedFill(background, color: color(0x142031), blur: 32, offset: -14, opacity: 0.28)
    gradient(background, bottom: 0x101925, top: 0x28394C)

    let back = NSBezierPath(
        roundedRect: CGRect(x: 214, y: 336, width: 460, height: 500), xRadius: 76, yRadius: 76
    )
    shadowedFill(back, color: color(0x29CFB7), blur: 18, offset: -8, opacity: 0.25)
    gradient(back, bottom: 0x16BDA8, top: 0x79F1DA)

    let front = NSBezierPath(
        roundedRect: CGRect(x: 344, y: 208, width: 460, height: 500), xRadius: 76, yRadius: 76
    )
    shadowedFill(front, color: color(0xF2F7FA), blur: 24, offset: -12, opacity: 0.34)
    gradient(front, bottom: 0xDBE7EE, top: 0xFFFFFF)

    let highlight = NSBezierPath(
        roundedRect: CGRect(x: 345, y: 209, width: 458, height: 498), xRadius: 75, yRadius: 75
    )
    highlight.lineWidth = 2
    NSColor.white.withAlphaComponent(0.55).setStroke()
    highlight.stroke()

    let capture = NSBezierPath()
    capture.lineWidth = 30
    capture.lineCapStyle = .round
    capture.lineJoinStyle = .round
    let frame = CGRect(x: 436, y: 330, width: 276, height: 256)
    let leg: CGFloat = 64
    for (x, y, dx, dy) in [
        (frame.minX, frame.maxY, leg, -leg),
        (frame.maxX, frame.maxY, -leg, -leg),
        (frame.minX, frame.minY, leg, leg),
        (frame.maxX, frame.minY, -leg, leg)
    ] {
        capture.move(to: CGPoint(x: x + dx, y: y))
        capture.line(to: CGPoint(x: x, y: y))
        capture.line(to: CGPoint(x: x, y: y + dy))
    }
    color(0x203449).setStroke()
    capture.stroke()
}

@MainActor
func drawMenuBarIcon(_ context: CGContext) {
    let back = NSBezierPath(
        roundedRect: CGRect(x: 1.25, y: 5.25, width: 11.5, height: 11.5), xRadius: 2, yRadius: 2
    )
    back.lineWidth = 1.5
    NSColor.black.setStroke()
    back.stroke()

    let front = NSBezierPath(
        roundedRect: CGRect(x: 5.25, y: 1.25, width: 11.5, height: 12.5), xRadius: 2, yRadius: 2
    )
    // Erase the covered back edge, leaving true alpha for macOS template rendering.
    context.saveGState()
    context.setBlendMode(.clear)
    NSColor.black.setFill()
    front.fill()
    context.restoreGState()
    front.lineWidth = 1.5
    NSColor.black.setStroke()
    front.stroke()
}

@MainActor
func png(pixels: Int, coordinateSize: CGFloat, draw: (CGContext) -> Void) throws -> Data {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    context.scaleBy(x: CGFloat(pixels) / coordinateSize, y: CGFloat(pixels) / coordinateSize)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw(context)
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

@MainActor
func generateIcons() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let assets = root.appendingPathComponent("Stackboard/Assets.xcassets", isDirectory: true)
    let appSet = assets.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
    let menuSet = assets.appendingPathComponent("MenuBarIcon.imageset", isDirectory: true)
    try FileManager.default.createDirectory(at: menuSet, withIntermediateDirectories: true)

    var rendered: [Int: Data] = [:]
    for points in [16, 32, 128, 256, 512] {
        for scale in 1...2 {
            let pixels = points * scale
            let data: Data
            if let existing = rendered[pixels] {
                data = existing
            } else {
                data = try png(pixels: pixels, coordinateSize: 1024) { _ in drawAppIcon() }
                rendered[pixels] = data
            }
            let name = "AppIcon-\(points)\(scale == 2 ? "@2x" : "").png"
            try data.write(to: appSet.appendingPathComponent(name), options: .atomic)
            print("\(name): \(pixels) × \(pixels)")
        }
    }
    for scale in 1...2 {
        let name = "MenuBarIcon\(scale == 2 ? "@2x" : "").png"
        let data = try png(pixels: 18 * scale, coordinateSize: 18, draw: drawMenuBarIcon)
        try data.write(to: menuSet.appendingPathComponent(name), options: .atomic)
        print("\(name): \(18 * scale) × \(18 * scale), template alpha")
    }
}

try MainActor.assumeIsolated {
    try generateIcons()
}
