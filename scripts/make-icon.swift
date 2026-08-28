// Renders the app icon: the menu bar hexagon symbol, black on a white macOS icon plate.
// Usage: swift scripts/make-icon.swift  → Resources/AppIcon.icns
import AppKit
import Foundation

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
let icns = URL(fileURLWithPath: "Resources/AppIcon.icns")
let plateRatio: CGFloat = 824 / 1024
let cornerRatio: CGFloat = 0.2237
let symbolRatio: CGFloat = 0.56

func draw(pixels: Int) {
    let side = CGFloat(pixels)
    let plateSide = side * plateRatio
    let plate = NSRect(x: (side - plateSide) / 2, y: (side - plateSide) / 2, width: plateSide, height: plateSide)
    let path = NSBezierPath(roundedRect: plate, xRadius: plateSide * cornerRatio, yRadius: plateSide * cornerRatio)
    NSColor.white.setFill()
    path.fill()
    NSColor(white: 0, alpha: 0.10).setStroke()
    path.lineWidth = max(1, side / 400)
    path.stroke()

    let config = NSImage.SymbolConfiguration(pointSize: plateSide * symbolRatio, weight: .medium)
        .applying(.init(paletteColors: [.black]))
    let symbol = NSImage(systemSymbolName: "hexagon.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let origin = NSPoint(x: plate.midX - symbol.size.width / 2, y: plate.midY - symbol.size.height / 2)
    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(pixels: pixels)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try png(pixels: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))
print("wrote \(icns.path)")
