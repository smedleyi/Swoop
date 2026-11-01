import AppKit

// One-off icon generator: run with `swift GenerateIcon.swift`, then
// `iconutil -c icns AppIcon.iconset -o AppIcon.icns`.

// Two windows, with an arc swooping from the dim one to the highlighted one.
// All measurements are on a 1024pt canvas with y going up, and the plate sits on
// Apple's icon grid, leaving 100pt of margin for its shadow.

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(
        gradient, start: start, end: end,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawPlate(_ context: CGContext) {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let plate = roundedRect(rect, radius: 185)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0, 0, 0, 0.35))
    context.addPath(plate)
    context.setFillColor(color(60, 40, 180))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(plate)
    context.clip()
    fillGradient(context, [color(122, 116, 255), color(58, 32, 186)],
                 from: CGPoint(x: 300, y: 924), to: CGPoint(x: 724, y: 100))
    // A soft sheen across the top.
    fillGradient(context, [color(255, 255, 255, 0.16), color(255, 255, 255, 0)],
                 from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 620))
    context.restoreGState()
}

func drawWindow(
    _ context: CGContext, _ rect: CGRect, fill: CGColor, bar: CGColor, dots: [CGColor], shadow: Bool
) {
    let radius = rect.width * 0.1
    let barHeight = rect.height * 0.2
    let path = roundedRect(rect, radius: radius)

    context.saveGState()
    if shadow {
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(20, 8, 90, 0.5))
    }
    context.addPath(path)
    context.setFillColor(fill)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    context.setFillColor(bar)
    context.fill(CGRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight))
    context.restoreGState()

    // Traffic lights turn to mush when small, so they're only drawn when they'd show.
    let side = barHeight * 0.36
    for (index, dot) in dots.enumerated() {
        let x = rect.minX + radius * 0.8 + CGFloat(index) * side * 1.6
        context.setFillColor(dot)
        context.fillEllipse(in: CGRect(x: x, y: rect.maxY - barHeight / 2 - side / 2, width: side, height: side))
    }
}

func drawArc(_ context: CGContext, lineWidth: CGFloat, shadow: Bool) {
    let start = CGPoint(x: 322, y: 572)
    let control = CGPoint(x: 462, y: 985)
    let tip = CGPoint(x: 660, y: 590)

    // The direction of travel where the arc lands, for lining up the arrowhead.
    let dx = tip.x - control.x
    let dy = tip.y - control.y
    let length = (dx * dx + dy * dy).squareRoot()
    let along = CGPoint(x: dx / length, y: dy / length)
    let across = CGPoint(x: -along.y, y: along.x)
    let headLength = lineWidth * 1.9
    let headWidth = lineWidth * 1.2
    let base = CGPoint(x: tip.x - along.x * headLength, y: tip.y - along.y * headLength)

    let shape = CGMutablePath()
    shape.move(to: start)
    shape.addQuadCurve(to: base, control: control)
    let stroked = shape.copy(
        strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)

    let head = CGMutablePath()
    head.move(to: tip)
    head.addLine(to: CGPoint(x: base.x + across.x * headWidth, y: base.y + across.y * headWidth))
    head.addLine(to: CGPoint(x: base.x - across.x * headWidth, y: base.y - across.y * headWidth))
    head.closeSubpath()

    context.saveGState()
    if shadow {
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(20, 8, 90, 0.45))
    }
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    // Filled one at a time, because where two paths overlap in one clip they can cancel out.
    for part in [stroked, head as CGPath] {
        context.saveGState()
        context.addPath(part)
        context.clip()
        fillGradient(context, [color(255, 208, 92), color(255, 122, 89)],
                     from: CGPoint(x: 322, y: 820), to: CGPoint(x: 660, y: 590))
        context.restoreGState()
    }
    context.endTransparencyLayer()
    context.restoreGState()
}

// Renders directly into a pixel-exact bitmap context so output size never
// depends on the screen's backing scale factor (NSImage.lockFocus does).
func makeIconRep(pixelSize: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(pixelSize) / 1024, y: CGFloat(pixelSize) / 1024)

    drawPlate(context)

    let isSmall = pixelSize < 64
    let trafficLights = isSmall ? [] : [color(255, 95, 87), color(255, 189, 46), color(40, 200, 64)]
    drawWindow(
        context, CGRect(x: 176, y: 262, width: 300, height: 262),
        fill: color(255, 255, 255, 0.34), bar: color(255, 255, 255, 0.22), dots: [], shadow: false)
    drawWindow(
        context, CGRect(x: 396, y: 214, width: 452, height: 346),
        fill: color(255, 255, 255), bar: color(226, 224, 250), dots: trafficLights, shadow: true)
    // Thicker when small, so the arc stays visible at menu and list sizes.
    drawArc(context, lineWidth: isSmall ? 70 : 44, shadow: !isSmall)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func savePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode \(path)")
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let iconsetPath = "AppIcon.iconset"
try? FileManager.default.createDirectory(
    atPath: iconsetPath, withIntermediateDirectories: true)

let specs: [(String, Int, Int)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2),
]

for (name, points, scale) in specs {
    let pixelSize = points * scale
    let rep = makeIconRep(pixelSize: pixelSize)
    try savePNG(rep, to: "\(iconsetPath)/\(name)")
    print("Wrote \(name) (\(pixelSize)x\(pixelSize))")
}
