// Places raw window captures on a soft backdrop with a natural shadow for the README.
// Usage: swift Scripts/frame-screenshots.swift <captures-dir> <out-dir>
import AppKit

let src = URL(fileURLWithPath: CommandLine.arguments[1])
let dst = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

func backdrop(_ rect: NSRect) {
    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.52, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.78, green: 0.33, blue: 0.55, alpha: 1),
    ])!.draw(in: rect, angle: -35)
    // Soft light pools for depth.
    for (x, y, r, a) in [(0.18, 0.85, 0.55, 0.22), (0.9, 0.15, 0.5, 0.18)] {
        let c = NSPoint(x: rect.width * x, y: rect.height * y)
        NSGradient(colors: [NSColor.white.withAlphaComponent(a), NSColor.white.withAlphaComponent(0)])!
            .draw(fromCenter: c, radius: 0, toCenter: c, radius: rect.width * r, options: [])
    }
}

func render(_ size: NSSize, _ draw: (NSRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func shadowed(_ image: NSImage, in rect: NSRect, blur: CGFloat, alpha: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: -blur * 0.35)
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.set()
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

let files = (try FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))
    .filter { $0.pathExtension == "png" && !$0.lastPathComponent.hasPrefix("hud") }
for file in files {
    guard let img = NSImage(contentsOf: file), let rep = img.representations.first else { continue }
    let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
    let pad = w * 0.07
    let canvas = NSSize(width: w + pad * 2, height: h + pad * 2)
    let data = render(canvas) { r in
        backdrop(r)
        shadowed(img, in: NSRect(x: pad, y: pad, width: w, height: h), blur: pad * 0.55, alpha: 0.5)
    }
    try data.write(to: dst.appending(path: file.lastPathComponent))
}

// The dictation pill: hold and locked states stacked on one backdrop.
let huds = ["hud-hold", "hud-locked"].compactMap { NSImage(contentsOf: src.appending(path: "\($0).png")) }
if huds.count == 2 {
    let sizes = huds.map { NSSize(width: $0.representations[0].pixelsWide, height: $0.representations[0].pixelsHigh) }
    let canvas = NSSize(width: 1600, height: sizes[0].height + sizes[1].height + 120)
    let data = render(canvas) { r in
        backdrop(r)
        var y = r.height - 40 - sizes[0].height
        for (img, s) in zip(huds, sizes) {
            shadowed(img, in: NSRect(x: (r.width - s.width) / 2, y: y, width: s.width, height: s.height), blur: 30, alpha: 0.35)
            y -= s.height + 40
        }
    }
    try data.write(to: dst.appending(path: "hud.png"))
}
print("Framed \(files.count) screenshots → \(dst.path)")
