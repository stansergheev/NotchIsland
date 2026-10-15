import AppKit
import CoreAudio

/// Notices when an app (Zoom, FaceTime, Discord, Teams…) is using the microphone.
@MainActor
final class CallMonitor: ObservableObject {
    struct ActiveCall: Equatable {
        let bundleID: String
        let name: String
        let since: Date
    }

    @Published private(set) var active: ActiveCall?

    private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var icon: NSImage? {
        guard let active,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: active.bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func poll() {
        guard let app = Self.appUsingMicrophone(), let bundleID = app.bundleIdentifier else {
            if active != nil { active = nil }
            return
        }
        if active?.bundleID != bundleID {
            active = ActiveCall(bundleID: bundleID, name: app.localizedName ?? "App", since: Date())
        }
    }

    // MARK: CoreAudio

    static func appUsingMicrophone() -> NSRunningApplication? {
        guard let input = defaultInputDevice(), isRunningSomewhere(input) else { return nil }
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for processBundleID in inputProcessBundleIDs() where processBundleID != own {
            // Helper processes (e.g. "com.google.Chrome.helper") map back to their app.
            if let app = apps.first(where: { app in
                guard let id = app.bundleIdentifier, id != own else { return false }
                return processBundleID == id || processBundleID.hasPrefix(id + ".")
            }) {
                return app
            }
        }
        return nil
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    /// Bundle IDs of every process currently recording from an input (macOS 14+).
    private static func inputProcessBundleIDs() -> [String] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { process in
            guard uint32(process, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            return string(process, kAudioProcessPropertyBundleID)
        }
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
