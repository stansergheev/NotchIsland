import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shape

/// Black notch shape: small outward flares at the top (so it melts into the
/// menu bar) and rounded bottom corners. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct IslandRootView: View {
    @EnvironmentObject var vm: IslandViewModel

    var body: some View {
        let size = vm.isExpanded ? vm.expandedSize : vm.collapsedSize
        let tall = vm.isExpanded || size.height > vm.notchSize.height + 1
        let topR: CGFloat = vm.isExpanded ? 14 : 6
        let bottomR: CGFloat = vm.isExpanded ? 30 : (tall ? 20 : 10)

        ZStack(alignment: .top) {
            NotchShape(topRadius: topR, bottomRadius: bottomR)
                .fill(Color.black)
                .frame(width: size.width + topR * 2, height: size.height)
                .shadow(color: .black.opacity(tall ? 0.5 : 0), radius: 14, y: 6)

            Group {
                if vm.isExpanded {
                    ExpandedView()
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else {
                    CollapsedView()
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: IslandController.canvas.width, height: IslandController.canvas.height, alignment: .top)
        .ignoresSafeArea()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: size)
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            vm.shelf.accept(providers)
            vm.tab = .shelf
            return true
        }
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    @EnvironmentObject var vm: IslandViewModel

    var body: some View {
        let presentation = vm.presentation
        if presentation == .idle {
            Color.clear
        } else {
            let wide = presentation == .dictation || presentation == .notification
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    LeftEar(presentation: presentation)
                        .frame(width: wide ? 56 : vm.earWidth)
                    Spacer(minLength: vm.notchSize.width)
                    RightEar(presentation: presentation)
                        .frame(width: wide ? 56 : vm.earWidth)
                }
                .frame(height: vm.notchSize.height)
                .padding(.horizontal, wide ? 10 : 0)

                switch presentation {
                case .lyricLine: LyricLine()
                case .dictation: DictationTranscript()
                case .notification: NotificationBody()
                default: EmptyView()
                }
            }
            .foregroundStyle(.white)
            .transition(.opacity)
        }
    }
}

struct LeftEar: View {
    let presentation: IslandViewModel.Presentation
    @EnvironmentObject var vm: IslandViewModel
    @EnvironmentObject var music: NowPlayingManager
    @EnvironmentObject var calls: CallMonitor
    @EnvironmentObject var notifications: NotificationMonitor

    var body: some View {
        switch presentation {
        case .dictation:
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
        case .notification:
            AppIcon(image: notifications.current.flatMap { NotificationMonitor.icon(for: $0.appName) },
                    fallback: "bell.fill", size: 20)
        default:
            switch vm.ears {
            case .flash(let flash)?:
                symbol(flash.icon, flash.tint)
            case .agentWaiting?:
                symbol("hand.raised.fill", .orange)
            case .call?:
                AppIcon(image: calls.icon, fallback: "mic.fill", size: 20)
            case .timer?:
                symbol("timer", .orange)
            case .agentWorking?:
                symbol("sparkle", .purple).symbolEffect(.pulse)
            case .music?:
                ArtworkView(image: music.artwork, size: 20, corner: 5)
            case nil:
                EmptyView()
            }
        }
    }

    private func symbol(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
    }
}

struct RightEar: View {
    let presentation: IslandViewModel.Presentation
    @EnvironmentObject var vm: IslandViewModel
    @EnvironmentObject var music: NowPlayingManager
    @EnvironmentObject var timer: FocusTimer
    @EnvironmentObject var calls: CallMonitor
    @EnvironmentObject var dictation: DictationManager

    var body: some View {
        switch presentation {
        case .dictation:
            LevelBars(level: dictation.level)
        case .notification:
            Text("now")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        default:
            switch vm.ears {
            case .flash(let flash)?:
                if let level = flash.level {
                    LevelBar(level: level, tint: flash.tint)
                } else {
                    label(flash.text, flash.tint)
                }
            case .agentWaiting?:
                label("Needs you", .orange)
            case .call?:
                if let since = calls.active?.since { ElapsedText(since: since, tint: .orange) }
            case .timer?:
                label(formatTime(timer.remaining.rounded(.up)), .orange)
            case .agentWorking(let since)?:
                ElapsedText(since: since, tint: .purple)
            case .music?:
                EqualizerBars(color: music.accent)
            case nil:
                EmptyView()
            }
        }
    }

    private func label(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
    }
}

/// The current lyric line, just under the notch.
struct LyricLine: View {
    @EnvironmentObject var music: NowPlayingManager
    @EnvironmentObject var lyrics: LyricsManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let line = lyrics.line(at: music.position(at: context.date)) ?? "♪"
            Text(line)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .id(line)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: line)
        }
    }
}

struct DictationTranscript: View {
    @EnvironmentObject var dictation: DictationManager

    var body: some View {
        let text = dictation.transcript.isEmpty
            ? (dictation.phase == .finishing ? "Typing…" : "Listening…")
            : dictation.transcript
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(dictation.transcript.isEmpty ? 0.5 : 0.95))
            .lineLimit(2)
            .truncationMode(.head) // keep the newest words visible
            .multilineTextAlignment(.center)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
    }
}

struct NotificationBody: View {
    @EnvironmentObject var notifications: NotificationMonitor

    var body: some View {
        if let banner = notifications.current {
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !banner.body.isEmpty {
                    Text(banner.body)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .frame(height: 56, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { notifications.open(banner) }
        }
    }
}

// MARK: - Small pieces

struct ElapsedText: View {
    let since: Date
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatTime(context.date.timeIntervalSince(since)))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
        }
    }
}

struct LevelBar: View {
    let level: Double
    let tint: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.2))
            Capsule().fill(tint).frame(width: 64 * CGFloat(min(max(level, 0), 1)))
        }
        .frame(width: 64, height: 5)
        .animation(.snappy(duration: 0.15), value: level)
    }
}

/// Live microphone bars while dictating.
struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let weights: [CGFloat] = [0.5, 0.8, 1, 0.8, 0.5]
                let height: CGFloat = 3 + 12 * CGFloat(level) * weights[i]
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2.5, height: height)
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

struct EqualizerBars: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (3.2 + Double(i) * 0.9) + Double(i) * 1.3
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: 4 + 9 * abs(sin(phase)))
                }
            }
            .frame(height: 14)
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct AppIcon: View {
    let image: NSImage?
    let fallback: String
    let size: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.6, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @EnvironmentObject var vm: IslandViewModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar().frame(height: vm.notchSize.height)
            Group {
                switch vm.tab {
                case .home: HomeTab()
                case .widgets: WidgetsTab()
                case .reminders: RemindersTab()
                case .shelf: ShelfTab()
                case .clipboard: ClipboardTab()
                case .timer: TimerTab()
                case .agents: AgentsTab()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Use the tab's natural height instead of filling the island.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 18)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                }
            )
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .onPreferenceChange(ContentHeightKey.self) { height in
            if abs(vm.contentHeight - height) > 0.5 {
                vm.contentHeight = height
            }
        }
    }
}

struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The strip beside the camera: tabs on the left, keep-awake, clock and battery on the right.
struct TopBar: View {
    @EnvironmentObject var vm: IslandViewModel
    @EnvironmentObject var battery: BatteryManager
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(IslandViewModel.Tab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.snappy) { vm.tab = tab }
                    } label: {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(vm.tab == tab ? Color.white : Color.white.opacity(0.4))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: vm.notchSize.width + 16)

            HStack(spacing: 10) {
                Button {
                    settings.keepAwake.toggle()
                } label: {
                    Image(systemName: settings.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(settings.keepAwake ? Color.orange : Color.white.opacity(0.45))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(settings.keepAwake ? "Keeping your Mac awake" : "Keep Mac awake")

                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                }
                if battery.hasBattery {
                    HStack(spacing: 4) {
                        Text("\(battery.percent)%")
                        Image(systemName: battery.symbolName)
                            .foregroundStyle(battery.isPluggedIn ? .green : (battery.percent <= 20 ? .red : .white))
                    }
                }
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 24)
    }
}

func eventTimeText(_ e: EventItem, now: Date) -> String {
    let cal = Calendar.current
    let time = e.start.formatted(date: .omitted, time: .shortened)
    if e.start <= now {
        return "Now, until \(e.end.formatted(date: .omitted, time: .shortened))"
    }
    if cal.isDateInToday(e.start) {
        let minutes = Int(e.start.timeIntervalSince(now) / 60)
        return minutes < 60 ? "In \(max(minutes, 1)) min" : "Today, \(time)"
    }
    if cal.isDateInTomorrow(e.start) { return "Tomorrow, \(time)" }
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: e.start)).day ?? 0
    let day = days < 7
        ? e.start.formatted(.dateTime.weekday(.wide))
        : e.start.formatted(.dateTime.month(.abbreviated).day())
    return "\(day), \(time)"
}
