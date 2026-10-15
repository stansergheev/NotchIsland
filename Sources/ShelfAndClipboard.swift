import AppKit
import SwiftUI
import QuickLookThumbnailing

// MARK: - File shelf

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// Holds files you drop on the notch, plus new screenshots and finished downloads.
/// Files are never copied or moved; the shelf only remembers where they are.
@MainActor
final class ShelfManager: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []

    /// Fired for screenshots ("Screenshot") and downloads ("Downloaded").
    var onNewFile: (@MainActor (String, URL) -> Void)?

    private let maxItems = 20
    private var screenshotQuery: NSMetadataQuery?
    private var seenScreenshots = Set<String>()
    private var downloadsSource: DispatchSourceFileSystemObject?
    private var downloadNames = Set<String>()
    private var downloadsWork: DispatchWorkItem?
    private let downloadsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

    init() {
        load()
        startScreenshotWatcher()
        startDownloadsWatcher()
    }

    // MARK: Items

    func add(_ url: URL) {
        guard !items.contains(where: { $0.url == url }) else { return }
        withAnimation(.snappy) {
            items.insert(ShelfItem(url: url), at: 0)
            if items.count > maxItems { items.removeLast(items.count - maxItems) }
        }
        save()
    }

    /// Handles files dropped onto the island.
    func accept(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor [weak self] in self?.add(url) }
            }
        }
    }

    func remove(_ item: ShelfItem) {
        withAnimation(.snappy) { items.removeAll { $0.id == item.id } }
        save()
    }

    func clear() {
        withAnimation(.snappy) { items.removeAll() }
        save()
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }

    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func airDrop(_ selection: [ShelfItem]) {
        let urls = selection.map(\.url)
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { return }
        NSApp.activate(ignoringOtherApps: true) // the AirDrop sheet needs the app in front
        service.perform(withItems: urls)
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: "shelfPaths")
    }

    private func load() {
        let paths = UserDefaults.standard.stringArray(forKey: "shelfPaths") ?? []
        items = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { ShelfItem(url: URL(fileURLWithPath: $0)) }
    }

    // MARK: Screenshots (via Spotlight, so no folder permission is needed)

    private func startScreenshotWatcher() {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture = 1")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let paths = added.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            MainActor.assumeIsolated { self?.handleScreenshots(paths) }
        }
        query.start()
        screenshotQuery = query
    }

    private func handleScreenshots(_ paths: [String]) {
        for path in paths where !seenScreenshots.contains(path) {
            seenScreenshots.insert(path)
            let url = URL(fileURLWithPath: path)
            add(url)
            onNewFile?("Screenshot", url)
        }
    }

    // MARK: Downloads (macOS asks once for access to the Downloads folder)

    private func startDownloadsWatcher() {
        let fd = Darwin.open(downloadsURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        downloadNames = currentDownloadNames()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleDownloadsCheck() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        downloadsSource = source
    }

    private func scheduleDownloadsCheck() {
        downloadsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkDownloads() }
        }
        downloadsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func checkDownloads() {
        let current = currentDownloadNames()
        let fresh = current.subtracting(downloadNames)
        downloadNames = current
        let partial: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]
        for name in fresh.sorted() {
            let url = downloadsURL.appendingPathComponent(name)
            guard !name.hasPrefix("."), !partial.contains(url.pathExtension.lowercased()) else { continue }
            add(url)
            onNewFile?("Downloaded", url)
        }
    }

    private func currentDownloadNames() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: downloadsURL.path)) ?? [])
    }
}

enum Thumbnails {
    static func image(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: 104, height: 104),
                                                   scale: 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

// MARK: - Clipboard history

struct ClipItem: Identifiable {
    enum Kind {
        case text(String)
        case image(NSImage)
        case files([URL])
    }

    let id = UUID()
    let kind: Kind
    let date: Date

    var preview: String {
        switch kind {
        case .text(let s):
            let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? ""
            return String(line.prefix(120))
        case .image:
            return "Image"
        case .files(let urls):
            return urls.map(\.lastPathComponent).joined(separator: ", ")
        }
    }

    var icon: String {
        switch kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "doc"
        }
    }
}

/// Keeps your last 30 copies in memory only (cleared when the app quits).
/// Copies from password managers are skipped: they mark them as concealed.
@MainActor
final class ClipboardManager: ObservableObject {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    @Published private(set) var items: [ClipItem] = []

    private let maxItems = 30
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text(let s): pb.setString(s, forType: .string)
        case .image(let image): pb.writeObjects([image])
        case .files(let urls): pb.writeObjects(urls.map { $0 as NSURL })
        }
        lastChange = pb.changeCount
        withAnimation(.snappy) {
            items.removeAll { $0.id == item.id }
            items.insert(ClipItem(kind: item.kind, date: Date()), at: 0)
        }
    }

    func clear() {
        withAnimation(.snappy) { items.removeAll() }
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount

        let types = pb.types ?? []
        if types.contains(Self.transientType) || types.contains(Self.concealedType)
            || types.contains(Self.autoGeneratedType) { return }

        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insert(.files(urls))
        } else if let text = pb.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if case .text(let latest)? = items.first?.kind, latest == text { return }
            items.removeAll { if case .text(let t) = $0.kind { return t == text }; return false }
            insert(.text(text))
        } else if let image = NSImage(pasteboard: pb) {
            insert(.image(image))
        }
    }

    private func insert(_ kind: ClipItem.Kind) {
        withAnimation(.snappy) {
            items.insert(ClipItem(kind: kind, date: Date()), at: 0)
            if items.count > maxItems { items.removeLast(items.count - maxItems) }
        }
    }
}
