import AppKit
import SwiftUI
import CoreImage

struct TrackInfo: Equatable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
}

enum RepeatMode: String {
    case off, all, one
}

/// Tracks what's playing in Spotify or Apple Music.
///
/// Both apps broadcast a distributed notification every time playback changes,
/// so we listen for those (no polling). AppleScript is used for the playback
/// controls, the song position and the album art.
@MainActor
final class NowPlayingManager: NSObject, ObservableObject {
    enum Player: String {
        case spotify = "Spotify"
        case music = "Music"

        var bundleID: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .music: return "com.apple.Music"
            }
        }
    }

    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var player: Player?
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var accent: Color = .white
    @Published var artwork: NSImage? {
        didSet { accent = artwork?.vividAverageColor.map { Color(nsColor: $0) } ?? .white }
    }

    var hasTrack: Bool { !title.isEmpty }

    /// Fired when the song changes (nil when playback stops). Used to load lyrics.
    var onTrackChange: (@MainActor (TrackInfo?) -> Void)?

    var currentTrack: TrackInfo? {
        hasTrack ? TrackInfo(title: title, artist: artist, album: album, duration: duration) : nil
    }

    private var positionAnchor: Double = 0
    private var anchorDate = Date()
    private var lastArtworkKey = ""

    override init() {
        super.init()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(spotifyChanged(_:)),
                        name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
                        object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(musicChanged(_:)),
                        name: NSNotification.Name("com.apple.Music.playerInfo"),
                        object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        refreshFromRunningPlayer()
    }

    // MARK: Notifications

    @objc private func spotifyChanged(_ note: Notification) {
        handle(info: note.userInfo ?? [:], from: .spotify)
    }

    @objc private func musicChanged(_ note: Notification) {
        handle(info: note.userInfo ?? [:], from: .music)
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if let player, app?.bundleIdentifier == player.bundleID { clear() }
    }

    private func handle(info: [AnyHashable: Any], from source: Player) {
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" {
            if player == source { clear() }
            return
        }
        player = source
        title = info["Name"] as? String ?? title
        artist = info["Artist"] as? String ?? artist
        album = info["Album"] as? String ?? album
        isPlaying = (state == "Playing")

        // Spotify sends "Duration", Music sends "Total Time" (both in milliseconds).
        let ms = (info["Duration"] as? NSNumber)?.doubleValue
            ?? (info["Total Time"] as? NSNumber)?.doubleValue
        if let ms, ms > 0 { duration = ms / 1000 }

        if let pos = (info["Playback Position"] as? NSNumber)?.doubleValue {
            setPosition(pos)
        } else {
            syncPosition()
        }
        loadArtworkIfNeeded()
    }

    // MARK: Position

    func position(at date: Date) -> Double {
        let p = positionAnchor + (isPlaying ? date.timeIntervalSince(anchorDate) : 0)
        return duration > 0 ? min(p, duration) : p
    }

    private func setPosition(_ seconds: Double) {
        positionAnchor = seconds
        anchorDate = Date()
    }

    func syncPosition() {
        guard let p = player, isRunning(p) else { return }
        if let v = runScript("tell application \"\(p.rawValue)\" to player position")?.doubleValue {
            setPosition(v)
        }
    }

    // MARK: Controls

    func playPause() {
        setPosition(position(at: Date()))
        send("playpause")
        isPlaying.toggle() // optimistic; the next notification confirms it
    }

    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        send("set player position to \(Int(target))")
        setPosition(target)
    }

    func toggleShuffle() {
        guard let p = player else { return }
        send(p == .spotify ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled")
        shuffle.toggle()
    }

    /// Spotify only has repeat on/off; Music cycles off → all → one.
    func cycleRepeat() {
        guard let p = player else { return }
        switch p {
        case .spotify:
            send("set repeating to not repeating")
            repeatMode = repeatMode == .off ? .all : .off
        case .music:
            let next: RepeatMode = repeatMode == .off ? .all : (repeatMode == .all ? .one : .off)
            send("set song repeat to \(next.rawValue)")
            repeatMode = next
        }
    }

    /// Reads the current shuffle and repeat settings from the player.
    func refreshModes() {
        guard let p = player, isRunning(p) else { return }
        let script = p == .spotify
            ? "tell application \"Spotify\" to return (shuffling as text) & \"||\" & (repeating as text)"
            : "tell application \"Music\" to return (shuffle enabled as text) & \"||\" & (song repeat as text)"
        guard let parts = runScript(script)?.stringValue?.components(separatedBy: "||"),
              parts.count == 2 else { return }
        shuffle = parts[0] == "true"
        if p == .spotify {
            repeatMode = parts[1] == "true" ? .all : .off
        } else {
            repeatMode = RepeatMode(rawValue: parts[1]) ?? .off
        }
    }

    func openPlayer() {
        guard let p = player,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func send(_ command: String) {
        guard let p = player, isRunning(p) else { return }
        runScript("tell application \"\(p.rawValue)\" to \(command)")
    }

    // MARK: Initial state

    /// Called once at launch so the island is correct before the first notification.
    private func refreshFromRunningPlayer() {
        for p in [Player.spotify, .music] where isRunning(p) {
            let script = """
            tell application "\(p.rawValue)"
                if player state is stopped then return "stopped"
                set t to current track
                return (player state as text) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (duration of t as text) & "||" & (player position as text)
            end tell
            """
            guard let result = runScript(script)?.stringValue, result != "stopped" else { continue }
            let parts = result.components(separatedBy: "||")
            guard parts.count == 6 else { continue }

            player = p
            isPlaying = parts[0] == "playing"
            title = parts[1]
            artist = parts[2]
            album = parts[3]
            let d = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
            duration = (p == .spotify) ? d / 1000 : d // Spotify: ms, Music: seconds
            setPosition(Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0)
            loadArtworkIfNeeded()
            if isPlaying { return } // prefer whichever app is actually playing
        }
    }

    // MARK: Artwork

    private func loadArtworkIfNeeded() {
        guard let p = player else { return }
        let key = "\(p.rawValue)|\(title)|\(album)"
        guard key != lastArtworkKey else { return }
        lastArtworkKey = key
        artwork = nil
        onTrackChange?(TrackInfo(title: title, artist: artist, album: album, duration: duration))
        refreshModes()

        switch p {
        case .spotify:
            guard let s = runScript("tell application \"Spotify\" to artwork url of current track")?.stringValue,
                  let url = URL(string: s) else { return }
            Task {
                guard let result = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: result.0) else { return }
                if self.lastArtworkKey == key { self.artwork = image }
            }
        case .music:
            let script = """
            tell application "Music"
                if (count of artworks of current track) > 0 then
                    return raw data of artwork 1 of current track
                end if
            end tell
            """
            if let data = runScript(script)?.data, let image = NSImage(data: data) {
                artwork = image
            }
        }
    }

    // MARK: Helpers

    private func clear() {
        title = ""; artist = ""; album = ""
        isPlaying = false
        duration = 0
        player = nil
        artwork = nil
        lastArtworkKey = ""
        setPosition(0)
        onTrackChange?(nil)
    }

    private func isRunning(_ p: Player) -> Bool {
        // Important: never script an app that isn't open, or AppleScript will launch it.
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == p.bundleID }
    }

    @discardableResult
    private func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { print("AppleScript error:", error) }
        return result
    }
}

extension NSImage {
    /// Average color of the image, brightened so it stays visible on black.
    var vividAverageColor: NSColor? {
        guard let tiff = tiffRepresentation, let input = CIImage(data: tiff) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage",
                              parameters: [kCIInputImageKey: input,
                                           kCIInputExtentKey: CIVector(cgRect: input.extent)])
        guard let output = filter?.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(output, toBitmap: &pixel, rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: nil)

        let base = NSColor(srgbRed: CGFloat(pixel[0]) / 255,
                           green: CGFloat(pixel[1]) / 255,
                           blue: CGFloat(pixel[2]) / 255,
                           alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(s * 1.3, 1), brightness: max(b, 0.8), alpha: 1)
    }
}
