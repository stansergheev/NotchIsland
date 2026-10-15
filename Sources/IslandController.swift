import AppKit
import ApplicationServices
import SwiftUI
import Combine

/// Borderless, transparent panel that sits above the menu bar, on every Space,
/// and never steals focus from the app you're using.
final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = true // only takes keyboard focus for the text field
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Let the window sit on top of the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Makes buttons respond on the first click even though the panel isn't key.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandController {
    /// Fixed transparent canvas; the black island is drawn inside it and animates in SwiftUI.
    static let canvas = CGSize(width: 760, height: 360)

    let vm = IslandViewModel()
    private lazy var menu = IslandMenu(vm: vm)
    private let panel: IslandPanel
    private var monitors: [Any] = []
    private var collapseWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var screenFrame = NSRect.zero
    private var dragChangeCount = 0
    private var hiddenForFullscreen = false
    private var fullscreenTimer: Timer?

    init() {
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.canvas))

        let root = IslandRootView()
            .environmentObject(vm)
            .environmentObject(vm.settings)
            .environmentObject(vm.nowPlaying)
            .environmentObject(vm.lyrics)
            .environmentObject(vm.reminders)
            .environmentObject(vm.battery)
            .environmentObject(vm.focusTimer)
            .environmentObject(vm.shelf)
            .environmentObject(vm.clipboard)
            .environmentObject(vm.calls)
            .environmentObject(vm.agents)
            .environmentObject(vm.notifications)
            .environmentObject(vm.dictation)

        let host = IslandHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.canvas)
        panel.contentView = host
        panel.ignoresMouseEvents = true // clicks pass through while collapsed

        layout()
        panel.orderFrontRegardless()
        installMouseMonitors()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }

        // If you click into another app while typing a reminder, unpin the island.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.vm.isPinned = false }
        }

        vm.$isPinned
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.mouseMoved() }
                }
            }
            .store(in: &cancellables)

        // When a notification disappears, make sure clicks pass through again.
        vm.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.refreshInteractivity() }
                }
            }
            .store(in: &cancellables)

        // Hide during fullscreen video and games.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFullscreen() }
            }
        }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFullscreen() }
        }
        RunLoop.main.add(t, forMode: .common)
        fullscreenTimer = t
    }

    func makeMenu() -> NSMenu { menu.makeMenu() }

    // MARK: Positioning

    private func layout() {
        let candidate = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = candidate else { return }
        let f = screen.frame
        screenFrame = f

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            vm.notchSize = CGSize(width: f.width - left.width - right.width,
                                  height: screen.safeAreaInsets.top)
            vm.hasPhysicalNotch = true
        } else {
            // External display without a notch: draw a virtual one.
            vm.notchSize = CGSize(width: 190, height: max(24, f.maxY - screen.visibleFrame.maxY))
            vm.hasPhysicalNotch = false
        }

        let c = Self.canvas
        panel.setFrame(NSRect(x: f.midX - c.width / 2, y: f.maxY - c.height,
                              width: c.width, height: c.height),
                       display: true)
    }

    // MARK: Mouse handling

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouse(type) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouse(type) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handleMouse(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
        case .rightMouseDown:
            rightClicked()
        case .leftMouseDragged:
            checkFileDrag()
            mouseMoved()
        default:
            mouseMoved()
        }
    }

    private func rectAtTop(size: CGSize) -> NSRect {
        let f = panel.frame
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// The strip level with the notch, where hovering opens the island.
    private var hoverBand: NSRect {
        rectAtTop(size: CGSize(width: vm.collapsedSize.width, height: vm.notchSize.height))
            .insetBy(dx: -6, dy: -3)
    }

    private func mouseMoved() {
        guard !hiddenForFullscreen else { return }
        let p = NSEvent.mouseLocation

        if vm.isExpanded {
            let zone = rectAtTop(size: vm.expandedSize).insetBy(dx: -14, dy: -14)
            if zone.contains(p) {
                collapseWork?.cancel()
                collapseWork = nil
            } else if !vm.isPinned {
                scheduleCollapse()
            }
            return
        }

        switch vm.presentation {
        case .notification:
            // Clickable while the pointer is over it; hovering doesn't open the tabs.
            let inside = rectAtTop(size: vm.collapsedSize).insetBy(dx: -4, dy: -4).contains(p)
            panel.ignoresMouseEvents = !inside
        case .dictation:
            break
        default:
            if hoverBand.contains(p) { expand() }
        }
    }

    private func refreshInteractivity() {
        guard !vm.isExpanded, vm.presentation != .notification else { return }
        if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
    }

    private func rightClicked() {
        guard !hiddenForFullscreen else { return }
        let p = NSEvent.mouseLocation
        let band = vm.isExpanded
            ? rectAtTop(size: CGSize(width: vm.expandedSize.width, height: vm.notchSize.height))
            : rectAtTop(size: vm.collapsedSize).insetBy(dx: -6, dy: -3)
        guard band.contains(p) else { return }
        makeMenu().popUp(positioning: nil, at: p, in: nil)
    }

    /// Dragging a file toward the notch opens the shelf so you can drop it there.
    private func checkFileDrag() {
        guard !vm.isExpanded, !hiddenForFullscreen else { return }
        let zone = rectAtTop(size: CGSize(width: vm.expandedWidth, height: vm.notchSize.height + 40))
        guard zone.contains(NSEvent.mouseLocation) else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragChangeCount, pb.types?.contains(.fileURL) == true else { return }
        vm.tab = .shelf
        expand()
    }

    private func expand() {
        collapseWork?.cancel()
        collapseWork = nil
        guard !vm.isExpanded else { return }
        panel.ignoresMouseEvents = false
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            vm.isExpanded = true
        }
        vm.didExpand()
    }

    private func scheduleCollapse() {
        guard collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.collapse() }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func collapse(force: Bool = false) {
        collapseWork = nil
        guard vm.isExpanded, force || !vm.isPinned else { return }
        vm.isPinned = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            vm.isExpanded = false
        }
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow { panel.resignKey() }
    }

    // MARK: Fullscreen

    private func updateFullscreen() {
        let hide = vm.settings.hideInFullscreen && frontmostAppIsFullscreen()
        guard hide != hiddenForFullscreen else { return }
        hiddenForFullscreen = hide
        if hide {
            collapse(force: true)
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// True when the frontmost app's window is in fullscreen.
    private func frontmostAppIsFullscreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return false }

        // Best answer: ask the focused window directly (needs Accessibility access).
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(pid)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window {
                var value: CFTypeRef?
                let element = window as! AXUIElement
                if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success {
                    return (value as? Bool) ?? false
                }
            }
        }

        // Fallback: a window that covers the entire screen.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        let size = screenFrame.size
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if bounds.width >= size.width && bounds.height >= size.height { return true }
        }
        return false
    }
}

// MARK: - Menu (right-click the notch, or the menu bar icon)

@MainActor
final class IslandMenu: NSObject {
    private let vm: IslandViewModel

    init(vm: IslandViewModel) {
        self.vm = vm
    }

    func makeMenu() -> NSMenu {
        let s = vm.settings
        let menu = NSMenu()
        menu.addItem(item("Show lyrics under the notch", #selector(toggleLyrics), on: s.lyricsUnderNotch))
        menu.addItem(item("Notifications in the notch", #selector(toggleNotifications), on: s.notificationsEnabled))
        menu.addItem(item("Volume and brightness in the notch", #selector(toggleHUD), on: s.hudEnabled))
        menu.addItem(item("Hide in fullscreen apps", #selector(toggleFullscreen), on: s.hideInFullscreen))
        menu.addItem(item("Keep Mac awake", #selector(toggleKeepAwake), on: s.keepAwake))

        let dictation = NSMenuItem(title: "Dictation", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for key in DictationKey.allCases {
            let option = item(key.label, #selector(setDictationKey(_:)), on: s.dictationKey == key)
            option.representedObject = key.rawValue
            sub.addItem(option)
        }
        dictation.submenu = sub
        menu.addItem(dictation)

        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            menu.addItem(item("Allow Accessibility Access…", #selector(grantAccessibility), on: false))
        }
        menu.addItem(item(vm.agents.isConnected ? "Disconnect Claude Code" : "Connect Claude Code",
                          #selector(toggleClaudeCode), on: false))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchIsland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func item(_ title: String, _ action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleLyrics() { vm.settings.lyricsUnderNotch.toggle() }
    @objc private func toggleNotifications() { vm.settings.notificationsEnabled.toggle() }
    @objc private func toggleHUD() { vm.settings.hudEnabled.toggle() }
    @objc private func toggleFullscreen() { vm.settings.hideInFullscreen.toggle() }
    @objc private func toggleKeepAwake() { vm.settings.keepAwake.toggle() }

    @objc private func setDictationKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = DictationKey(rawValue: raw) else { return }
        vm.settings.dictationKey = key
    }

    @objc private func grantAccessibility() {
        Permissions.promptForAccessibility()
        Permissions.openPrivacyPane("Privacy_Accessibility")
    }

    @objc private func toggleClaudeCode() {
        vm.agents.isConnected ? vm.agents.disconnect() : vm.agents.connect()
    }
}
