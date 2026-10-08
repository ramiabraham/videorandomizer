// Draws the app icon — a die whose centre pip is a play button — and writes a 1024px PNG.
// Usage: swift make-icon.swift out.png   (make-icon.sh turns it into AppIcon.icns)
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// Background tile on the standard macOS icon grid (824pt body inside 1024).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(20, 22, 40))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.drawLinearGradient(
    CGGradient(colorsSpace: space, colors: [rgb(58, 64, 120), rgb(16, 18, 36)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// The die, tilted as if mid-roll.
ctx.translateBy(x: 512, y: 512)
ctx.rotate(by: 12 * .pi / 180)
let die = CGRect(x: -270, y: -270, width: 540, height: 540)
let diePath = CGPath(roundedRect: die, cornerWidth: 110, cornerHeight: 110, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0, 0, 0, 0.5))
ctx.addPath(diePath)
ctx.setFillColor(rgb(245, 245, 248))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(diePath)
ctx.clip()
ctx.drawLinearGradient(
    CGGradient(colorsSpace: space, colors: [rgb(255, 255, 255), rgb(214, 217, 230)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: 0, y: 270), end: CGPoint(x: 0, y: -270), options: [])
ctx.restoreGState()

// Four corner pips of a "five"...
ctx.setFillColor(rgb(28, 30, 54))
for (x, y) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
    ctx.fillEllipse(in: CGRect(x: x * 165 - 42, y: y * 165 - 42, width: 84, height: 84))
}
// ...and a play button where the centre pip would be.
let play = CGMutablePath()
play.move(to: CGPoint(x: -72, y: 112))
play.addLine(to: CGPoint(x: -72, y: -112))
play.addLine(to: CGPoint(x: 122, y: 0))
play.closeSubpath()
ctx.addPath(play)
ctx.setFillColor(rgb(232, 60, 60))
ctx.setStrokeColor(rgb(232, 60, 60))
ctx.setLineWidth(36)
ctx.setLineJoin(.round)
ctx.drawPath(using: .fillStroke)

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
