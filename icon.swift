// Draws the 1024 px app icon. Run once: swift icon.swift AppIcon-1024.png
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// Apple's macOS icon grid: an 824 px body inside the 1024 px canvas.
let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1),
           ending: NSColor(srgbRed: 1.0, green: 0.22, blue: 0.37, alpha: 1))!.draw(in: body, angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold).applying(.init(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
symbol.draw(in: NSRect(x: (1024 - symbol.size.width) / 2, y: (1024 - symbol.size.height) / 2,
                       width: symbol.size.width, height: symbol.size.height))
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
