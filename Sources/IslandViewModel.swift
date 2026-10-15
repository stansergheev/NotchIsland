import SwiftUI
import Combine

@MainActor
final class IslandViewModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case home, reminders, shelf, clipboard, timer, agents

        var icon: String {
            switch self {
            case .home: return "music.note"
            case .reminders: return "checklist"
            case .shelf: return "tray.full"
            case .clipboard: return "doc.on.clipboard"
            case .timer: return "timer"
            case .agents: return "sparkles"
            }
        }

        var title: String {
            switch self {
            case .home: return "Home"
            case .reminders: return "Reminders"
            case .shelf: return "Shelf"
            case .clipboard: return "Clipboard"
            case .timer: return "Focus timer"
            case .agents: return "Claude Code"
            }
        }
    }

    /// A short pop-out beside the notch (charging, volume, screenshot…).
    struct Flash: Equatable {
        let icon: String
        let text: String
        let tint: Color
        var level: Double? = nil // shown as a bar (volume, brightness)

        var isWide: Bool { level != nil || text.count > 5 }
    }

    /// What the "ears" beside the notch show while collapsed, highest priority first.
    enum Ears: Equatable {
        case flash(Flash)
        case agentWaiting(String)
        case call
        case timer
        case agentWorking(Date)
        case music
    }

    /// How the collapsed island is drawn.
    enum Presentation: Equatable {
        case idle, ears, lyricLine, dictation, notification
    }

    @Published var isExpanded = false
    @Published var isPinned = false          // stays open while you type a reminder
    @Published var tab: Tab = .home
    @Published var showLyrics = false
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var hasPhysicalNotch = true
    @Published var flash: Flash?
    @Published var contentHeight: CGFloat = 150

    let settings = AppSettings()
    let nowPlaying = NowPlayingManager()
    let lyrics = LyricsManager()
    let reminders = RemindersManager()
    let battery = BatteryManager()
    let focusTimer = FocusTimer()
    let shelf = ShelfManager()
    let clipboard = ClipboardManager()
    let calls = CallMonitor()
    let agents = AgentMonitor()
    let notifications = NotificationMonitor()
    let dictation = DictationManager()
    let keyboard = KeyboardTap()

    let expandedWidth: CGFloat = 620
    private var flashWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var tapRetry: Timer?

    init() {
        wireUp()
        forwardChanges()
        startKeyboard()
        lyrics.load(nowPlaying.currentTrack)
    }

    // MARK: Layout

    var expandedSize: CGSize {
        let maxHeight = IslandController.canvas.height - 20
        return CGSize(width: expandedWidth, height: min(notchSize.height + contentHeight, maxHeight))
    }

    var ears: Ears? {
        if let flash { return .flash(flash) }
        if let waiting = agents.waitingSession { return .agentWaiting(waiting.project) }
        if calls.active != nil { return .call }
        if focusTimer.isRunning { return .timer }
        if let since = agents.workingSince { return .agentWorking(since) }
        if nowPlaying.isPlaying { return .music }
        return nil
    }

    var presentation: Presentation {
        if dictation.phase != .idle { return .dictation }
        if notifications.current != nil { return .notification }
        if settings.lyricsUnderNotch, nowPlaying.isPlaying, lyrics.hasSynced { return .lyricLine }
        if ears != nil { return .ears }
        return .idle
    }

    var earWidth: CGFloat {
        switch ears {
        case .flash(let f)?: return f.isWide ? 104 : 56
        case .agentWaiting?: return 96
        default: return 56
        }
    }

    var collapsedSize: CGSize {
        let n = notchSize
        let withEars = n.width + earWidth * 2
        switch presentation {
        case .idle: return n
        case .ears: return CGSize(width: withEars, height: n.height)
        case .lyricLine: return CGSize(width: max(withEars, 400), height: n.height + 28)
        case .dictation: return CGSize(width: max(n.width + 150, 460), height: n.height + 52)
        case .notification: return CGSize(width: max(n.width + 150, 460), height: n.height + 62)
        }
    }

    // MARK: Flash

    func showFlash(_ newFlash: Flash, seconds: Double = 3) {
        flashWork?.cancel()
        if flash != newFlash {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { flash = newFlash }
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self?.flash = nil }
            }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func didExpand() {
        reminders.refresh()
        // Resync the song after the open animation so it doesn't stutter.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                self?.nowPlaying.syncPosition()
                self?.nowPlaying.refreshModes()
            }
        }
    }

    // MARK: Wiring

    private func wireUp() {
        battery.onPowerSourceChange = { [weak self] pluggedIn, percent in
            self?.showFlash(Flash(icon: pluggedIn ? "bolt.fill" : "powerplug",
                                  text: "\(percent)%",
                                  tint: pluggedIn ? .green : .white))
        }
        battery.onLowBattery = { [weak self] percent in
            self?.showFlash(Flash(icon: "battery.25percent", text: "\(percent)%", tint: .red), seconds: 6)
        }
        focusTimer.onFinish = { [weak self] in
            self?.showFlash(Flash(icon: "bell.fill", text: "Done", tint: .orange), seconds: 6)
        }
        reminders.onUpcomingEvent = { [weak self] event in
            let mins = max(1, Int((event.start.timeIntervalSinceNow / 60).rounded(.up)))
            self?.showFlash(Flash(icon: "calendar", text: "\(mins)m", tint: event.color), seconds: 8)
        }
        nowPlaying.onTrackChange = { [weak self] track in
            self?.lyrics.load(track)
        }
        shelf.onNewFile = { [weak self] kind, url in
            let icon = kind == "Screenshot" ? "camera.viewfinder" : "arrow.down.circle.fill"
            self?.showFlash(Flash(icon: icon, text: url.lastPathComponent, tint: .white), seconds: 4)
        }
        agents.onNeedsYou = { _ in
            NSSound(named: "Ping")?.play()
        }
        agents.onDone = { [weak self] session in
            NSSound(named: "Pop")?.play()
            self?.showFlash(Flash(icon: "checkmark.circle.fill", text: session.project, tint: .green), seconds: 5)
        }
        notifications.isEnabled = { [weak self] in
            self?.settings.notificationsEnabled ?? false
        }
        dictation.onMessage = { [weak self] message in
            self?.showFlash(Flash(icon: "mic.fill", text: message, tint: .orange), seconds: 3)
        }
        keyboard.onMediaKey = { [weak self] key in
            self?.handleMediaKey(key) ?? false
        }
        keyboard.onFlagsChanged = { [weak self] event in
            self?.handleFlags(event)
        }
        keyboard.onKeyDown = { [weak self] in
            self?.dictation.otherKeyPressed()
        }
    }

    /// Re-render the island whenever any feature changes.
    private func forwardChanges() {
        let publishers: [AnyPublisher<Void, Never>] = [
            settings.objectWillChange.eraseToAnyPublisher(),
            nowPlaying.objectWillChange.eraseToAnyPublisher(),
            lyrics.objectWillChange.eraseToAnyPublisher(),
            reminders.objectWillChange.eraseToAnyPublisher(),
            battery.objectWillChange.eraseToAnyPublisher(),
            focusTimer.objectWillChange.eraseToAnyPublisher(),
            shelf.objectWillChange.eraseToAnyPublisher(),
            clipboard.objectWillChange.eraseToAnyPublisher(),
            calls.objectWillChange.eraseToAnyPublisher(),
            agents.objectWillChange.eraseToAnyPublisher(),
            notifications.objectWillChange.eraseToAnyPublisher(),
            dictation.objectWillChange.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(publishers)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
    }

    // MARK: Keyboard

    /// The event tap needs Accessibility access. Ask once, then keep retrying quietly.
    private func startKeyboard() {
        if keyboard.start() { return }
        if settings.needsAccessibility { Permissions.promptForAccessibility() }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if self.keyboard.start() {
                    timer.invalidate()
                    self.tapRetry = nil
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tapRetry = t
    }

    private func handleMediaKey(_ key: MediaKey) -> Bool {
        guard settings.hudEnabled else { return false }
        let step: Float = 1 / 16

        switch key {
        case .volumeUp, .volumeDown:
            guard let current = SystemAudio.volume() else { return false }
            if SystemAudio.isMuted() { SystemAudio.setMuted(false) }
            let delta: Float = key == .volumeUp ? step : -step
            let newValue = max(0, min(1, (current / step).rounded() * step + delta))
            guard SystemAudio.setVolume(newValue) else { return false }
            showVolume(newValue, muted: false)
            return true
        case .mute:
            let muted = !SystemAudio.isMuted()
            guard SystemAudio.setMuted(muted) else { return false }
            showVolume(SystemAudio.volume() ?? 0, muted: muted)
            return true
        case .brightnessUp, .brightnessDown:
            guard let current = DisplayBrightness.get() else { return false }
            let delta: Float = key == .brightnessUp ? step : -step
            let newValue = max(0, min(1, (current / step).rounded() * step + delta))
            guard DisplayBrightness.set(newValue) else { return false }
            showFlash(Flash(icon: newValue < 0.5 ? "sun.min.fill" : "sun.max.fill",
                            text: "", tint: .yellow, level: Double(newValue)), seconds: 1.5)
            return true
        }
    }

    private func showVolume(_ value: Float, muted: Bool) {
        let icon: String
        if muted || value == 0 { icon = "speaker.slash.fill" }
        else if value < 0.34 { icon = "speaker.wave.1.fill" }
        else if value < 0.67 { icon = "speaker.wave.2.fill" }
        else { icon = "speaker.wave.3.fill" }
        showFlash(Flash(icon: icon, text: "", tint: .white, level: muted ? 0 : Double(value)), seconds: 1.5)
    }

    private func handleFlags(_ event: CGEvent) {
        switch settings.dictationKey {
        case .off:
            return
        case .fn:
            dictation.keyChanged(down: event.flags.contains(.maskSecondaryFn))
        case .rightOption:
            guard event.getIntegerValueField(.keyboardEventKeycode) == 61 else { return }
            dictation.keyChanged(down: event.flags.contains(.maskAlternate))
        }
    }
}
