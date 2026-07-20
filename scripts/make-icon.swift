#!/usr/bin/env swift
import AppKit

// Renders a 1024×1024 app-icon PNG. Usage: swift scripts/make-icon.swift <out.png> [--ios]
// Design: navy squircle, an upward line chart, and the "00830" wordmark.
//
// The default (macOS) form insets the artwork and rounds it itself, which is what `.icns`
// expects. The `--ios` form is full-bleed and opaque instead: iOS applies its own corner
// mask, and an icon carrying an alpha channel is rejected by App Store Connect.

let args = CommandLine.arguments.dropFirst()
let isIOS = args.contains("--ios")
let outPath = args.first(where: { !$0.hasPrefix("--") }) ?? "icon.png"

let side: CGFloat = 1024
let inset: CGFloat = isIOS ? 0 : 74
let rect = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)

func draw() {
    // iOS gets no rounding of its own — the system mask would clip a second time.
    if !isIOS {
        NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205).addClip()
    }

    // Background gradient.
    let top = NSColor(calibratedRed: 0.12, green: 0.29, blue: 0.55, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.04, green: 0.11, blue: 0.23, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)

    // Line chart: dips then rallies, ending green (the "revalue" motif).
    let pts: [NSPoint] = [
        NSPoint(x: 200, y: 560), NSPoint(x: 350, y: 470), NSPoint(x: 500, y: 600),
        NSPoint(x: 650, y: 400), NSPoint(x: 824, y: 700)
    ]
    let line = NSBezierPath()
    line.move(to: pts[0])
    for p in pts.dropFirst() { line.line(to: p) }
    line.lineWidth = 34
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.46, alpha: 1).setStroke()
    line.stroke()
    // End marker.
    let dot = NSBezierPath(ovalIn: NSRect(x: pts.last!.x - 26, y: pts.last!.y - 26, width: 52, height: 52))
    NSColor.white.setFill(); dot.fill()

    // Wordmark.
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 190, weight: .heavy),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para
    ]
    let text = "00830" as NSString
    text.draw(in: NSRect(x: inset, y: 190, width: side - 2 * inset, height: 220), withAttributes: attrs)
}

func render() -> NSBitmapImageRep? {
    guard isIOS else {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        draw()
        image.unlockFocus()
        return image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    }
    // NOTE: A 24bpp (no-alpha) bitmap context cannot be created — Core Graphics rejects it,
    // and `NSGraphicsContext(bitmapImageRep:)` then returns nil, yielding an all-black image.
    // `noneSkipFirst` is 32bpp with the alpha byte ignored, which does produce an opaque PNG.
    guard let ctx = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw()
    NSGraphicsContext.restoreGraphicsState()

    return ctx.makeImage().map(NSBitmapImageRep.init(cgImage:))
}

guard let rep = render(), let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
