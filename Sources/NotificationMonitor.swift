import AppKit
import ApplicationServices

struct IslandBanner: Identifiable, Equatable {
    let id: String
    let appName: String
    let title: String
    let body: String
}

/// Mirrors macOS notification banners into the notch.
///
/// There's no public API for other apps' notifications, so this reads the banners
/// macOS is showing through the Accessibility API (the same way screen readers do).
/// Needs Accessibility access. The normal macOS banner still appears too.
@MainActor
final class NotificationMonitor: ObservableObject {
    @Published private(set) var current: IslandBanner?

    var isEnabled: @MainActor () -> Bool = { true }

    private var elements: [String: AXUIElement] = [:]
    private var visible = Set<String>()
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private static let bannerSubroles: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]

    init() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func open(_ banner: IslandBanner) {
        if let element = elements[banner.id],
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            // macOS opens the right conversation for us.
        } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == banner.appName }) {
            app.activate()
        } else if let url = Self.appURL(named: banner.appName) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        dismiss()
    }

    func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        current = nil
    }

    static func icon(for appName: String) -> NSImage? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
            return app.icon
        }
        return appURL(named: appName).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private static func appURL(named name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        for folder in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
            let path = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    // MARK: Polling the Notification Center process

    private func poll() {
        guard isEnabled(), AXIsProcessTrusted(),
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }

        var found: [(key: String, element: AXUIElement, texts: [String], description: String)] = []
        collect(AXUIElementCreateApplication(nc.processIdentifier), depth: 0, into: &found)

        let fresh = found.filter { !visible.contains($0.key) }
        visible = Set(found.map { $0.key })
        elements = Dictionary(found.map { ($0.key, $0.element) }, uniquingKeysWith: { first, _ in first })

        // More than two new at once means Notification Center itself was opened. Ignore that.
        guard (1...2).contains(fresh.count), let newest = fresh.last else { return }
        show(makeBanner(key: newest.key, texts: newest.texts, description: newest.description))
    }

    private func show(_ banner: IslandBanner) {
        current = banner
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.current = nil }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func makeBanner(key: String, texts: [String], description: String) -> IslandBanner {
        let parts = description.components(separatedBy: ", ")
        let appName = parts.first ?? ""
        var lines = texts
        if lines.first == appName { lines.removeFirst() }
        var title = appName
        if let first = lines.first {
            title = first
        } else if parts.count > 1 {
            title = parts[1]
        }
        var body = ""
        if lines.count > 1 {
            body = lines.dropFirst().joined(separator: " ")
        } else if lines.isEmpty && parts.count > 2 {
            body = parts.dropFirst(2).joined(separator: ", ")
        }
        return IslandBanner(id: key, appName: appName, title: title, body: body)
    }

    private func collect(_ element: AXUIElement, depth: Int,
                         into out: inout [(key: String, element: AXUIElement, texts: [String], description: String)]) {
        guard depth < 10 else { return }
        if let subrole: String = attribute(element, kAXSubroleAttribute), Self.bannerSubroles.contains(subrole) {
            var texts: [String] = []
            gatherTexts(element, depth: 0, into: &texts)
            let description: String = attribute(element, kAXDescriptionAttribute) ?? ""
            let key = ([description] + texts).joined(separator: "|")
            if !(description.isEmpty && texts.isEmpty) {
                out.append((key: key, element: element, texts: texts, description: description))
            }
            return
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for child in children { collect(child, depth: depth + 1, into: &out) }
    }

    private func gatherTexts(_ element: AXUIElement, depth: Int, into texts: inout [String]) {
        guard depth < 6 else { return }
        if let role: String = attribute(element, kAXRoleAttribute), role == kAXStaticTextRole,
           let value: String = attribute(element, kAXValueAttribute),
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            texts.append(value)
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for child in children { gatherTexts(child, depth: depth + 1, into: &texts) }
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
