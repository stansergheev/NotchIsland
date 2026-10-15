import SwiftUI
import AppKit

@main
struct NotchIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The island lives in its own NSPanel, so the app has no regular windows.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var island: IslandController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon
        island = IslandController()
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeepAwake.set(false)
    }

    /// A small menu bar icon with the same menu as right-clicking the notch.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "NotchIsland")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuild the menu each time it opens so the checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let fresh = island?.makeMenu() else { return }
        let items = fresh.items
        fresh.removeAllItems()
        items.forEach { menu.addItem($0) }
    }
}
