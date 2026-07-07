import AppKit
import SwiftUI

/// Owns the menu-bar status item and the click-through popover, and keeps the status item's
/// coloured title in sync with the store.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = MenuBarStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "00830 …"
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store))

        // The store drives the label; refresh the status item every time it publishes.
        store.onPublish = { [weak self] in self?.refreshButton() }
        store.startOnce()
        refreshButton()
    }

    /// Renders the label with its alert colour. NSStatusItem honours `attributedTitle`'s
    /// foreground colour in the menu bar (unlike a SwiftUI template label).
    private func refreshButton() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = NSAttributedString(
            string: store.labelText,
            attributes: [
                .foregroundColor: NSColor(store.labelState.color),
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            ]
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
