// Usage: swift make_icon.swift out.png  — draws a 1024px placeholder app icon.
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 52, y: 52, width: 920, height: 920)
let bg = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(red: 0.45, green: 0.30, blue: 0.75, alpha: 1),
           ending: NSColor(red: 0.25, green: 0.12, blue: 0.50, alpha: 1))!.draw(in: bg, angle: -90)

// globe: circle + meridians
NSColor.white.setStroke()
let c = NSPoint(x: 512, y: 512)
func stroke(_ p: NSBezierPath) { p.lineWidth = 34; p.stroke() }
stroke(NSBezierPath(ovalIn: NSRect(x: c.x - 300, y: c.y - 300, width: 600, height: 600)))
stroke(NSBezierPath(ovalIn: NSRect(x: c.x - 130, y: c.y - 300, width: 260, height: 600)))
let eq = NSBezierPath(); eq.move(to: NSPoint(x: c.x - 300, y: c.y)); eq.line(to: NSPoint(x: c.x + 300, y: c.y)); stroke(eq)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
