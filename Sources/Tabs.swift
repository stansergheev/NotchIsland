import SwiftUI
import AppKit

// MARK: - Reminders tab

struct RemindersTab: View {
    @EnvironmentObject var rem: RemindersManager
    @EnvironmentObject var vm: IslandViewModel
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if rem.remindersAuthorized {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.white.opacity(0.5))
                    TextField("New reminder", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($fieldFocused)
                        .onSubmit {
                            rem.add(title: draft)
                            draft = ""
                        }
                        .onExitCommand { fieldFocused = false }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if rem.items.isEmpty {
                    Text("No open reminders.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 6)
                } else {
                    // Show up to 5 so the island grows with the list but never gets huge.
                    VStack(spacing: 7) {
                        ForEach(Array(rem.items.prefix(5))) { item in
                            ReminderRow(item: item, compact: false)
                        }
                    }
                    if rem.items.count > 5 {
                        Button("\(rem.items.count - 5) more in Reminders") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .onChange(of: fieldFocused) { _, focused in vm.isPinned = focused }
            .onDisappear { vm.isPinned = false }
        } else {
            VStack(spacing: 8) {
                Text("NotchIsland can't see your reminders")
                    .font(.system(size: 13, weight: .semibold))
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PillStyle(active: true))
            }
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
        }
    }
}

struct ReminderRow: View {
    let item: ReminderItem
    let compact: Bool
    @EnvironmentObject var rem: RemindersManager
    @State private var done = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                withAnimation(.snappy) { done = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    rem.complete(item)
                }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(item.color)
            }
            .buttonStyle(.plain)
            .help("Mark as done")

            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(compact ? 2 : 1)
                .strikethrough(done)
                .foregroundStyle(done ? .white.opacity(0.4) : .white)

            if !compact {
                Spacer(minLength: 8)
                if let due = item.due {
                    Text(dueText(due))
                        .font(.system(size: 11))
                        .foregroundStyle(due < Date() ? Color.red : Color.white.opacity(0.5))
                }
            }
        }
    }

    private func dueText(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Timer tab

struct TimerTab: View {
    @EnvironmentObject var timer: FocusTimer

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: timer.progress)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: timer.progress)
                Text(formatTime(timer.remaining.rounded(.up)))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: 12) {
                Text("Focus timer")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    ForEach([5, 15, 25, 50], id: \.self) { minutes in
                        Button("\(minutes)m") { timer.set(minutes: minutes) }
                            .buttonStyle(PillStyle(active: timer.totalMinutes == minutes))
                    }
                }
                HStack(spacing: 8) {
                    Button { timer.toggle() } label: {
                        Label(timer.isRunning ? "Pause" : "Start",
                              systemImage: timer.isRunning ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(PillStyle(active: true, tint: .orange))

                    Button { timer.reset() } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(PillStyle(active: false))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Button styles

struct PillStyle: ButtonStyle {
    var active: Bool
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(active ? tint.opacity(0.22) : Color.white.opacity(0.08)))
            .foregroundStyle(active ? tint : Color.white.opacity(0.75))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Shelf tab

struct ShelfTab: View {
    @EnvironmentObject var shelf: ShelfManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Shelf").font(.system(size: 13, weight: .semibold))
                if !shelf.items.isEmpty {
                    Text("\(shelf.items.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Button { shelf.airDrop(shelf.items) } label: {
                        Label("AirDrop all", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(PillStyle(active: false))
                    Button("Clear") { shelf.clear() }
                        .buttonStyle(PillStyle(active: false))
                }
            }

            if shelf.items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("Drag files onto the notch to keep them here")
                        .font(.system(size: 12, weight: .medium))
                    Text("New screenshots and downloads show up here too.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item)
                        }
                    }
                }
                .frame(height: 96)
            }
        }
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    @EnvironmentObject var shelf: ShelfManager
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
            Text(item.url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 72)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.12 : 0.06))
        )
        .onHover { hovering = $0 }
        .help("Drag out to use it. Double-click to open.")
        .onTapGesture(count: 2) { shelf.open(item) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            Button("AirDrop") { shelf.airDrop([item]) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .task(id: item.url) {
            thumbnail = await Thumbnails.image(for: item.url)
        }
    }
}

// MARK: - Clipboard tab

struct ClipboardTab: View {
    @EnvironmentObject var clipboard: ClipboardManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clipboard").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !clipboard.items.isEmpty {
                    Button("Clear") { clipboard.clear() }
                        .buttonStyle(PillStyle(active: false))
                }
            }
            if clipboard.items.isEmpty {
                Text("Copy something and it shows up here. Click an item to copy it again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(clipboard.items) { item in
                            ClipRow(item: item)
                        }
                    }
                }
                .frame(height: min(CGFloat(clipboard.items.count) * 34, 170))
            }
        }
    }
}

struct ClipRow: View {
    let item: ClipItem
    @EnvironmentObject var clipboard: ClipboardManager
    @State private var hovering = false

    var body: some View {
        Button {
            clipboard.copy(item)
        } label: {
            HStack(spacing: 10) {
                if case .image(let image) = item.kind {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 20)
                }
                Text(item.preview)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(hovering ? "Copy" : item.date.formatted(.relative(presentation: .numeric)))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.1 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Claude Code tab

struct AgentsTab: View {
    @EnvironmentObject var agents: AgentMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Claude Code").font(.system(size: 13, weight: .semibold))
                Spacer()
                if agents.isConnected {
                    Text("Connected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green.opacity(0.8))
                }
            }

            if !agents.isConnected {
                Text("See when Claude Code is working, done, or waiting for your permission.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                Button("Connect Claude Code") { agents.connect() }
                    .buttonStyle(PillStyle(active: true, tint: .orange))
                Text("This adds small hooks to ~/.claude/settings.json and saves a backup next to it first.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            } else if agents.sessions.isEmpty {
                Text("No active sessions. Run claude in a terminal and it shows up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(agents.sessions.prefix(4))) { session in
                        AgentRow(session: session)
                    }
                }
            }

            if let error = agents.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }
}

struct AgentRow: View {
    let session: AgentMonitor.Session

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            switch session.state {
            case .working, .waiting:
                ElapsedText(since: session.since, tint: .white.opacity(0.5))
            case .done, .idle:
                Text(session.updated.formatted(.relative(presentation: .numeric)))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var color: Color {
        switch session.state {
        case .working: return .purple
        case .waiting: return .orange
        case .done: return .green
        case .idle: return .gray
        }
    }

    private var detail: String {
        switch session.state {
        case .working(let tool?): return "Working · \(tool)"
        case .working(nil): return "Thinking…"
        case .waiting(let message): return message
        case .done: return "Done"
        case .idle: return "Waiting for a prompt"
        }
    }
}
