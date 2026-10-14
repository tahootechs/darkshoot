// Generates Icon/AppIcon.icns. Run: swift Icon/make-icon.swift
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt body centered in 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = .black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor.black.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(red: 0.47, green: 0.33, blue: 0.96, alpha: 1),
           ending: NSColor(red: 0.20, green: 0.55, blue: 0.98, alpha: 1))!.draw(in: squircle, angle: -60)

// Selection corner brackets.
let frame = body.insetBy(dx: 170, dy: 170)
let arm: CGFloat = 130
let brackets = NSBezierPath()
brackets.lineWidth = 46
brackets.lineCapStyle = .round
brackets.lineJoinStyle = .round
for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                       (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
    brackets.move(to: NSPoint(x: x, y: y + dy * arm))
    brackets.line(to: NSPoint(x: x, y: y))
    brackets.line(to: NSPoint(x: x + dx * arm, y: y))
}
NSColor.white.setStroke()
brackets.stroke()

// Red annotation arrow.
let start = NSPoint(x: frame.minX + 110, y: frame.minY + 110)
let tip = NSPoint(x: frame.maxX - 120, y: frame.maxY - 120)
let red = NSColor(red: 1, green: 0.27, blue: 0.27, alpha: 1)
red.set()
let shaft = NSBezierPath()
shaft.lineWidth = 48
shaft.lineCapStyle = .round
shaft.move(to: start)
shaft.line(to: NSPoint(x: tip.x - 70, y: tip.y - 70))
shaft.stroke()
let angle = atan2(tip.y - start.y, tip.x - start.x)
let head = NSBezierPath()
head.move(to: tip)
for side in [CGFloat.pi / 6, -CGFloat.pi / 6] {
    head.line(to: NSPoint(x: tip.x - 190 * cos(angle + side), y: tip.y - 190 * sin(angle + side)))
}
head.close()
head.lineJoinStyle = .round
head.lineWidth = 20
head.fill()
head.stroke()

NSGraphicsContext.current = nil

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = NSImage(size: NSSize(width: size, height: size))
master.addRepresentation(rep)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.current = nil
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try out.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Icon/AppIcon.icns" : "iconutil failed")
