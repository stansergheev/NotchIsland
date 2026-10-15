import SwiftUI
import IOKit
import IOKit.pwr_mgt

enum DictationKey: String, CaseIterable {
    case off, fn, rightOption

    var label: String {
        switch self {
        case .off: return "Off"
        case .fn: return "Hold Fn (🌐)"
        case .rightOption: return "Hold right Option"
        }
    }
}

/// User settings, saved to UserDefaults. Changed from the right-click / menu bar menu.
@MainActor
final class AppSettings: ObservableObject {
    @Published var lyricsUnderNotch: Bool {
        didSet { UserDefaults.standard.set(lyricsUnderNotch, forKey: "lyricsUnderNotch") }
    }
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var hudEnabled: Bool {
        didSet { UserDefaults.standard.set(hudEnabled, forKey: "hudEnabled") }
    }
    @Published var hideInFullscreen: Bool {
        didSet { UserDefaults.standard.set(hideInFullscreen, forKey: "hideInFullscreen") }
    }
    @Published var dictationKey: DictationKey {
        didSet { UserDefaults.standard.set(dictationKey.rawValue, forKey: "dictationKey") }
    }
    /// Not saved on purpose: keep-awake should never silently survive a restart.
    @Published var keepAwake = false {
        didSet { KeepAwake.set(keepAwake) }
    }

    init() {
        let d = UserDefaults.standard
        lyricsUnderNotch = d.object(forKey: "lyricsUnderNotch") as? Bool ?? false
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        hudEnabled = d.object(forKey: "hudEnabled") as? Bool ?? true
        hideInFullscreen = d.object(forKey: "hideInFullscreen") as? Bool ?? true
        dictationKey = DictationKey(rawValue: d.string(forKey: "dictationKey") ?? "") ?? .fn
    }

    /// Accessibility is needed for the HUD, dictation and notifications.
    var needsAccessibility: Bool {
        hudEnabled || notificationsEnabled || dictationKey != .off
    }
}

/// Stops the display from sleeping while turned on.
@MainActor
enum KeepAwake {
    private static var assertion: IOPMAssertionID = 0

    static func set(_ on: Bool) {
        if on, assertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "NotchIsland keep awake" as CFString,
                &id)
            if result == kIOReturnSuccess { assertion = id }
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
