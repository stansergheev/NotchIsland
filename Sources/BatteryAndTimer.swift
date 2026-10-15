import AppKit
import IOKit.ps

// MARK: - Battery

/// C callback for IOKit power-source changes. Registered on the main run loop.
private func powerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let manager = Unmanaged<BatteryManager>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { manager.refresh(notify: true) }
}

@MainActor
final class BatteryManager: ObservableObject {
    @Published var percent = 100
    @Published var isCharging = false
    @Published var isPluggedIn = false
    @Published var hasBattery = true

    /// Fired when the charger is plugged in or pulled out.
    var onPowerSourceChange: (@MainActor (Bool, Int) -> Void)?
    /// Fired once at 20% and again at 10% while on battery.
    var onLowBattery: (@MainActor (Int) -> Void)?

    private var warnedAt = 101

    private var runLoopSource: CFRunLoopSource?

    init() {
        refresh(notify: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(powerSourceChanged, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    var symbolName: String {
        if isCharging || isPluggedIn { return "battery.100percent.bolt" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    func refresh(notify: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            hasBattery = false
            return
        }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = info[kIOPSMaxCapacityKey] as? Int ?? 100
            let pct = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let plugged = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let wasPlugged = isPluggedIn

            percent = pct
            isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            isPluggedIn = plugged
            hasBattery = true

            if notify && plugged != wasPlugged { onPowerSourceChange?(plugged, pct) }
            if plugged {
                warnedAt = 101
            } else if notify {
                for threshold in [10, 20] where pct <= threshold && threshold < warnedAt {
                    warnedAt = threshold
                    onLowBattery?(pct)
                    break
                }
            }
            return
        }
        hasBattery = false
    }
}

// MARK: - Focus timer

@MainActor
final class FocusTimer: ObservableObject {
    @Published var total: TimeInterval = 25 * 60
    @Published var remaining: TimeInterval = 25 * 60
    @Published var isRunning = false

    var onFinish: (@MainActor () -> Void)?

    private var endDate: Date?
    private var ticker: Timer?

    var progress: Double { total > 0 ? 1 - remaining / total : 0 }
    var totalMinutes: Int { Int(total / 60) }

    func set(minutes: Int) {
        reset()
        total = TimeInterval(minutes * 60)
        remaining = total
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard remaining > 0 else { return }
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func pause() {
        tick()
        stopTicking()
    }

    func reset() {
        stopTicking()
        remaining = total
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining == 0 { finish() }
    }

    private func finish() {
        stopTicking()
        remaining = total
        NSSound(named: "Glass")?.play()
        onFinish?()
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
        isRunning = false
    }
}

/// 83 -> "1:23", 3723 -> "1:02:03"
func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t)
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
