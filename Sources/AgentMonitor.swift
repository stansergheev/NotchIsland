import AppKit

/// Shows what Claude Code is doing.
///
/// "Connect Claude Code" adds small hooks to ~/.claude/settings.json. Each time
/// Claude Code starts working, asks for permission or finishes, the hook writes the
/// event (as JSON) into ~/.notchisland/events, and this class reads and deletes it.
/// Nothing leaves your Mac.
@MainActor
final class AgentMonitor: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String?) // tool name, if known
        case waiting(String)  // e.g. "Claude needs your permission to use Bash"
        case done
    }

    struct Session: Identifiable, Equatable {
        let id: String
        var project: String
        var state: State
        var since: Date
        var updated: Date
    }

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    var onNeedsYou: (@MainActor (Session) -> Void)?
    var onDone: (@MainActor (Session) -> Void)?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var eventsDir: URL { home.appendingPathComponent(".notchisland/events") }
    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    private var timer: Timer?

    private static let marker = ".notchisland/events"
    private static let hookCommand =
        #"mkdir -p "$HOME/.notchisland/events" && cat > "$HOME/.notchisland/events/$(date +%s)-$$-$RANDOM.json""#
    private static let hookEvents: [(name: String, matcher: String?)] = [
        ("SessionStart", nil), ("UserPromptSubmit", nil), ("PreToolUse", "*"),
        ("PostToolUse", "*"), ("Notification", nil), ("Stop", nil), ("SessionEnd", nil),
    ]

    init() {
        isConnected = (try? String(contentsOf: settingsURL, encoding: .utf8))?.contains(Self.marker) ?? false
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var waitingSession: Session? {
        sessions.first { if case .waiting = $0.state { return true } else { return false } }
    }

    var workingSince: Date? {
        sessions.filter { if case .working = $0.state { return true } else { return false } }
            .map(\.since).min()
    }

    // MARK: Connect / disconnect

    func connect() {
        do {
            var root = try loadSettings()
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in Self.hookEvents {
                var groups = hooks[event.name] as? [[String: Any]] ?? []
                groups.removeAll { Self.isOurs($0) }
                var group: [String: Any] = ["hooks": [["type": "command", "command": Self.hookCommand]]]
                if let matcher = event.matcher { group["matcher"] = matcher }
                groups.append(group)
                hooks[event.name] = groups
            }
            root["hooks"] = hooks
            try write(root)
            isConnected = true
            lastError = nil
        } catch {
            lastError = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        do {
            var root = try loadSettings()
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for (name, value) in hooks {
                guard var groups = value as? [[String: Any]] else { continue }
                groups.removeAll { Self.isOurs($0) }
                hooks[name] = groups.isEmpty ? nil : groups
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
            try write(root)
            isConnected = false
            sessions = []
            lastError = nil
        } catch {
            lastError = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains(marker) == true
        } ?? false
    }

    private func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NotchIsland", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "it isn't a JSON object"])
        }
        return object
    }

    private func write(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("notchisland-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: Events

    private func poll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: eventsDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else {
            prune()
            return
        }
        let now = Date()
        var events: [(url: URL, date: Date)] = []
        for url in files where url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let date: Date = values?.contentModificationDate ?? now
            // Skip files a hook is still writing.
            if now.timeIntervalSince(date) > 0.3 {
                events.append((url: url, date: date))
            }
        }
        events.sort { a, b in
            if a.date != b.date { return a.date < b.date }
            return a.url.lastPathComponent < b.url.lastPathComponent
        }

        for (url, _) in events {
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                apply(json)
            }
            try? fm.removeItem(at: url)
        }
        prune()
    }

    private func apply(_ json: [String: Any]) {
        guard let id = json["session_id"] as? String,
              let event = json["hook_event_name"] as? String else { return }
        let cwd = json["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Claude Code" : URL(fileURLWithPath: cwd).lastPathComponent
        let now = Date()

        if event == "SessionEnd" {
            sessions.removeAll { $0.id == id }
            return
        }

        var session = sessions.first { $0.id == id }
            ?? Session(id: id, project: project, state: .idle, since: now, updated: now)
        let old = session.state
        session.project = project

        switch event {
        case "SessionStart":
            session.state = .idle
            session.since = now
        case "UserPromptSubmit":
            session.state = .working(nil)
            session.since = now
        case "PreToolUse":
            if case .working = old {} else { session.since = now }
            session.state = .working(json["tool_name"] as? String)
        case "PostToolUse":
            if case .working = old {} else { session.since = now }
            if case .working(let tool) = old { session.state = .working(tool) } else { session.state = .working(nil) }
        case "Notification":
            let message = json["message"] as? String ?? "Claude Code needs your attention"
            if message.localizedCaseInsensitiveContains("permission") {
                session.state = .waiting(message)
                session.since = now
            }
        case "Stop":
            session.state = .done
            session.since = now
        default:
            break
        }
        session.updated = now

        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
        sortSessions()

        if case .waiting = session.state, session.state != old { onNeedsYou?(session) }
        if session.state == .done, old != .done, old != .idle { onDone?(session) }
    }

    private func sortSessions() {
        func rank(_ s: Session) -> Int {
            switch s.state {
            case .waiting: return 0
            case .working: return 1
            case .done: return 2
            case .idle: return 3
            }
        }
        sessions.sort { rank($0) == rank($1) ? $0.updated > $1.updated : rank($0) < rank($1) }
    }

    /// Forget finished sessions after 20 minutes and silent ones after 3 hours.
    private func prune() {
        let now = Date()
        let kept = sessions.filter { s in
            switch s.state {
            case .done, .idle: return now.timeIntervalSince(s.updated) < 20 * 60
            default: return now.timeIntervalSince(s.updated) < 3 * 3600
            }
        }
        if kept.count != sessions.count { sessions = kept }
    }
}
