import AppKit
import SwiftUI

/// Diagnostic: renders the menu-bar label in each alert colour to a PNG so the colour path can
/// be verified without a visible menu-bar slot. Triggered by NAV830_RENDER=/path; exits after.
enum RenderProbe {
    static func write(to path: String) {
        let states: [(String, LabelState)] = [
            ("00830 -3.6%", .discountAlert),
            ("00830 -1.0%", .normal),
            ("00830 +4.2%", .premiumAlert),
            ("00830 --", .stale)
        ]
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let rowH: CGFloat = 26, width: CGFloat = 160
        let size = NSSize(width: width, height: rowH * CGFloat(states.count))
        let image = NSImage(size: size)
        image.lockFocus()
        // Menu-bar-ish dark background.
        NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (i, state) in states.enumerated() {
            let attr = NSAttributedString(string: state.0, attributes: [
                .foregroundColor: NSColor(state.1.color),
                .font: font
            ])
            let y = size.height - rowH * CGFloat(i + 1) + 4
            attr.draw(at: NSPoint(x: 8, y: y))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
