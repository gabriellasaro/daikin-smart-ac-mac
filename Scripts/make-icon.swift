// Draws the app icon into an .iconset folder:
//   swift Scripts/make-icon.swift build/AppIcon.iconset
//   iconutil -c icns build/AppIcon.iconset -o Packaging/AppIcon.icns
import AppKit

func drawIcon(side: CGFloat) {
    // macOS icon grid: the rounded square sits inside a ~10% margin.
    let inset = side * 0.098
    let body = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = side * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.01)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.80, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.44, blue: 0.94, alpha: 1),
    ])?.draw(in: path, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: body.width * 0.56, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return }
    let size = symbol.size
    symbol.draw(in: NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2,
                           width: size.width, height: size.height))
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        drawIcon(side: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()

        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
    }
}
