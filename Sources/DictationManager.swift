import AppKit
import ApplicationServices
import AVFoundation
import Speech

/// Thread-safe holder for the latest microphone level (written on the audio thread).
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Float = 0

    func set(_ value: Float) {
        lock.lock(); stored = value; lock.unlock()
    }

    var value: Float {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Hold a key, talk, let go: the words are typed wherever your cursor is.
/// Uses Apple's speech recognition (on-device when your Mac supports it).
@MainActor
final class DictationManager: ObservableObject {
    enum Phase { case idle, listening, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var level: Float = 0

    /// Short status messages ("Allow microphone access", …) shown in the notch.
    var onMessage: (@MainActor (String) -> Void)?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let meter = LevelMeter()
    private var meterTimer: Timer?
    private var armWork: DispatchWorkItem?
    private var finishWork: DispatchWorkItem?
    private var keyIsDown = false

    // MARK: Key handling

    /// The dictation key went down or up.
    func keyChanged(down: Bool) {
        if down, !keyIsDown {
            keyIsDown = true
            guard phase == .idle else { return }
            // Wait a moment so quick taps and Fn+key shortcuts don't start dictation.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.begin() }
            }
            armWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else if !down, keyIsDown {
            keyIsDown = false
            armWork?.cancel()
            armWork = nil
            if phase == .listening { finish() }
        }
    }

    /// Any other key was pressed while the dictation key is held: it's a shortcut, not dictation.
    func otherKeyPressed() {
        armWork?.cancel()
        armWork = nil
    }

    // MARK: Recording

    private func begin() {
        armWork = nil
        guard keyIsDown, phase == .idle else { return }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            Permissions.requestSpeech()
            return
        case .authorized:
            break
        default:
            onMessage?("Allow Speech Recognition")
            Permissions.openPrivacyPane("Privacy_SpeechRecognition")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Permissions.requestMicrophone()
            return
        case .authorized:
            break
        default:
            onMessage?("Allow the microphone")
            Permissions.openPrivacyPane("Privacy_Microphone")
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            onMessage?("Dictation unavailable")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onMessage?("No microphone found")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.makeTapBlock(request: request, meter: meter))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onMessage?("Couldn't start the mic")
            return
        }

        self.engine = engine
        self.request = request
        transcript = ""
        phase = .listening
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)

        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler(self))

        meterTimer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = min(1, self.meter.value * 14)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    /// Built outside the main actor because the audio thread calls it.
    nonisolated private static func makeTapBlock(request: SFSpeechAudioBufferRecognitionRequest,
                                                 meter: LevelMeter) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            meter.set((sum / Float(count)).squareRoot())
        }
    }

    /// Speech results arrive on a background thread; hop to the main thread here.
    nonisolated private static func makeResultHandler(_ owner: DictationManager)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    owner?.handleResult(text: text, isFinal: isFinal, failed: failed)
                }
            }
        }
    }

    private func finish() {
        phase = .finishing
        stopAudio()
        request?.endAudio()
        // If the final result is slow, use what we have after 1.5 seconds.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.complete() }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func handleResult(text: String?, isFinal: Bool, failed: Bool) {
        if let text, !text.isEmpty { transcript = text }
        if phase == .finishing, isFinal || failed { complete() }
    }

    private func complete() {
        guard phase != .idle else { return }
        finishWork?.cancel()
        finishWork = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .idle
        transcript = ""
        if !text.isEmpty { insert(text) }
    }

    private func stopAudio() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
    }

    // MARK: Typing the result

    /// Puts the text on the clipboard, presses ⌘V, then puts your old clipboard back.
    private func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }

        pb.clearContents()
        pb.declareTypes([.string, ClipboardManager.transientType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ClipboardManager.transientType)

        guard AXIsProcessTrusted() else {
            onMessage?("Copied, press ⌘V")
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                guard !saved.isEmpty else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let items = saved.map { dict -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in dict { item.setData(data, forType: type) }
                    item.setData(Data(), forType: ClipboardManager.transientType)
                    return item
                }
                pasteboard.writeObjects(items)
            }
        }
    }
}

/// Permission prompts, kept outside the main actor because their callbacks run on background threads.
enum Permissions {
    static func requestSpeech() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    static func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows the macOS "allow Accessibility" prompt.
    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
