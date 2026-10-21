import AppKit
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    rect.fill()
    let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
        .applying(.init(paletteColors: [.white, NSColor(red: 1, green: 0.62, blue: 0.04, alpha: 1)]))
    guard let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return false }
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
