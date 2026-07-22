import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
let tileRect = rect.insetBy(dx: 100, dy: 100)
let cornerRadius: CGFloat = 232
let backgroundPath = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)

let bottomLeftColor = NSColor(calibratedRed: 10.0 / 255.0, green: 88.0 / 255.0, blue: 245.0 / 255.0, alpha: 1.0)
let centerColor = NSColor(calibratedRed: 18.0 / 255.0, green: 150.0 / 255.0, blue: 250.0 / 255.0, alpha: 1.0)
let topRightColor = NSColor(calibratedRed: 0.0 / 255.0, green: 205.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
let gradient = NSGradient(colors: [bottomLeftColor, centerColor, topRightColor])

gradient?.draw(in: backgroundPath, angle: 45)

let highlightPath = NSBezierPath(roundedRect: tileRect.insetBy(dx: 16, dy: 16),
                                 xRadius: cornerRadius - 10,
                                 yRadius: cornerRadius - 10)
let highlight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.28),
    NSColor.white.withAlphaComponent(0.04)
])
highlight?.draw(in: highlightPath, angle: -90)

let borderPath = NSBezierPath(roundedRect: tileRect.insetBy(dx: 6, dy: 6),
                              xRadius: cornerRadius - 4,
                              yRadius: cornerRadius - 4)
NSColor.white.withAlphaComponent(0.22).setStroke()
borderPath.lineWidth = 6
borderPath.stroke()

let glyphShadow = NSShadow()
glyphShadow.shadowBlurRadius = 16
glyphShadow.shadowOffset = NSSize(width: 0, height: -3)
glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)

let glyphColor = NSColor(calibratedRed: 0.811, green: 0.911, blue: 0.990, alpha: 1.0)
let symbolConfig = NSImage.SymbolConfiguration(pointSize: 740, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [glyphColor]))
let symbol = NSImage(systemSymbolName: "puzzlepiece.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfig)

if let symbol {
    let targetRect = tileRect.insetBy(dx: 58, dy: 58)
    let symbolSize = symbol.size
    let scale = min(targetRect.width / symbolSize.width, targetRect.height / symbolSize.height)
    let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
    let drawRect = NSRect(
        x: rect.midX - drawSize.width / 2,
        y: rect.midY - drawSize.height / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    NSGraphicsContext.current?.saveGraphicsState()
    glyphShadow.set()
    symbol.draw(in: drawRect)
    NSGraphicsContext.current?.restoreGraphicsState()
}

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)
let pngData = rep?.representation(using: .png, properties: [:])
let outputURL = URL(fileURLWithPath: "Icon.png", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
try pngData?.write(to: outputURL)

print("Wrote \(outputURL.path)")
