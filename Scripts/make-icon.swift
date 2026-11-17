// Renders the app icon: a soft gradient squircle with a waveform glyph.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.42, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.62, green: 0.33, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.70, alpha: 1),
])!.draw(in: path, angle: -50)
// Waveform bars
let heights: [CGFloat] = [0.22, 0.42, 0.68, 0.48, 0.82, 0.56, 0.34, 0.6, 0.28]
let barW: CGFloat = 46, gap: CGFloat = 26
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (size - total) / 2
NSColor.white.withAlphaComponent(0.95).setFill()
for h in heights {
    let bh = h * 520
    NSBezierPath(roundedRect: NSRect(x: x, y: (size - bh) / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
    x += barW + gap
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
