import AppKit
import CoreAudio
import AudioToolbox
import ApplicationServices

// MARK: - Keyboard event tap
//
// One event tap handles three things:
//  - the volume / brightness keys (so we can replace the macOS HUD with ours)
//  - modifier changes (to detect holding Fn or right Option for dictation)
//  - other key presses (so Fn+key combos don't trigger dictation)
// It needs Accessibility access. Without it, start() returns false and we retry later.

enum MediaKey {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
}

private func keyboardTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyboardTap>.fromOpaque(refcon).takeUnretainedValue()
    // The tap is added to the main run loop, so this always runs on the main thread.
    let swallow = MainActor.assumeIsolated { tap.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class KeyboardTap {
    /// Called on key down. Return true if handled (the system then never sees the key).
    var onMediaKey: (@MainActor (MediaKey) -> Bool)?
    var onFlagsChanged: (@MainActor (CGEvent) -> Void)?
    var onKeyDown: (@MainActor () -> Void)?

    private var machPort: CFMachPort?
    private var swallowedKeyCodes = Set<Int>() // so the matching key-up is swallowed too

    var isRunning: Bool { machPort != nil }

    @discardableResult
    func start() -> Bool {
        if machPort != nil { return true }
        guard AXIsProcessTrusted() else { return false }

        let systemDefined: CGEventMask = 1 << 14 // NX_SYSDEFINED: media and brightness keys
        let flagsChanged: CGEventMask = 1 << CGEventMask(CGEventType.flagsChanged.rawValue)
        let keyDown: CGEventMask = 1 << CGEventMask(CGEventType.keyDown.rawValue)
        let mask: CGEventMask = systemDefined | flagsChanged | keyDown
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: keyboardTapCallback,
                                           userInfo: refcon) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        machPort = port
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return false
        case .flagsChanged:
            onFlagsChanged?(event)
            return false
        case .keyDown:
            onKeyDown?()
            return false
        default:
            break
        }

        guard type.rawValue == 14,
              let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == 8 else { return false } // 8 = aux control buttons

        let data1 = ns.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyState = (data1 & 0xFF00) >> 8
        let isDown = keyState == 0xA

        let key: MediaKey
        switch keyCode {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        case 7: key = .mute
        default: return false
        }

        if isDown {
            let handled = onMediaKey?(key) ?? false
            if handled { swallowedKeyCodes.insert(keyCode) } else { swallowedKeyCodes.remove(keyCode) }
            return handled
        }
        return swallowedKeyCodes.contains(keyCode)
    }
}

// MARK: - System volume (CoreAudio)

enum SystemAudio {
    static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func volume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func setVolume(_ newValue: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return false }
        var value = Float32(max(0, min(1, newValue)))
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    static func isMuted() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var addr = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var addr = address(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}

// MARK: - Built-in display brightness
//
// Apple has no public API for this, so we load DisplayServices (a private framework
// that ships with macOS) at runtime. If it's ever missing, we let macOS handle the key.

enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    private static let getFunction: GetFunction? = {
        guard let handle, let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetFunction.self)
    }()

    private static let setFunction: SetFunction? = {
        guard let handle, let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetFunction.self)
    }()

    private static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get() -> Float? {
        guard let getFunction, let display = builtInDisplay else { return nil }
        var value: Float = 0
        return getFunction(display, &value) == 0 ? value : nil
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let setFunction, let display = builtInDisplay else { return false }
        return setFunction(display, max(0, min(1, value))) == 0
    }
}
