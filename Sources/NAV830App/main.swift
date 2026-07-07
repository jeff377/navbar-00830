import AppKit

// AppKit entry point (not SwiftUI `App`/MenuBarExtra): a plain NSStatusItem is the reliable
// way to get a coloured, always-visible menu-bar label. MenuBarExtra from an SPM executable
// did not register a status item on this macOS; NSStatusItem.attributedTitle also honours the
// discount/premium colour that MenuBarExtra renders as a monochrome template.
// Diagnostic one-shot: render the label colours to a PNG and exit (see RenderProbe).
if let renderPath = ProcessInfo.processInfo.environment["NAV830_RENDER"] {
    RenderProbe.write(to: renderPath)
    exit(0)
}

let controller = AppController()
let app = NSApplication.shared
app.delegate = controller
app.setActivationPolicy(.accessory)   // menu-bar-only agent: no Dock icon, no main window
app.run()
