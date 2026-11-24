// Renders the DockDesk app icon and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Background tile (macOS icon grid: 824 pt square, 100 pt margin)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.10, green: 0.13, blue: 0.30, alpha: 1).cgColor,
        NSColor(red: 0.16, green: 0.36, blue: 0.78, alpha: 1).cgColor,
        NSColor(red: 0.20, green: 0.72, blue: 0.80, alpha: 1).cgColor] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
    ctx.restoreGState()

    // One cable splitting into two
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    ctx.setLineWidth(26); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 512, y: 215)); ctx.addLine(to: CGPoint(x: 512, y: 300))
    ctx.move(to: CGPoint(x: 512, y: 300)); ctx.addCurve(to: CGPoint(x: 350, y: 480), control1: CGPoint(x: 512, y: 400), control2: CGPoint(x: 350, y: 380))
    ctx.move(to: CGPoint(x: 512, y: 300)); ctx.addCurve(to: CGPoint(x: 674, y: 480), control1: CGPoint(x: 512, y: 400), control2: CGPoint(x: 674, y: 380))
    ctx.strokePath()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: 484, y: 187, width: 56, height: 56))

    // Two screens
    for (x, tint) in [(CGFloat(180), NSColor(red: 1.0, green: 0.80, blue: 0.35, alpha: 1)), (CGFloat(524), NSColor(red: 0.55, green: 0.95, blue: 0.85, alpha: 1))] {
        let frame = CGRect(x: x, y: 480, width: 320, height: 232)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 36, cornerHeight: 36, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        ctx.restoreGState()
        let inner = frame.insetBy(dx: 22, dy: 22)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(red: 0.09, green: 0.12, blue: 0.26, alpha: 1).cgColor, NSColor(red: 0.17, green: 0.24, blue: 0.48, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: inner.minX, y: inner.minY), end: CGPoint(x: inner.maxX, y: inner.maxY), options: [])
        // a small window on each desktop, in its own colour
        ctx.setFillColor(tint.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: inner.minX + 40, y: inner.minY + 34, width: inner.width - 80, height: 96), cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.fillPath()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.fill(CGRect(x: inner.minX, y: inner.maxY - 26, width: inner.width, height: 26)) // menu bar
        ctx.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? fm.removeItem(at: set)
try fm.createDirectory(at: set, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try draw(pt * scale).write(to: set.appendingPathComponent(name))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
try draw(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
try? fm.removeItem(at: set)
print("wrote Resources/AppIcon.icns")
