import SwiftUI

// MARK: - Home

struct HomeTab: View {
    @EnvironmentObject var vm: IslandViewModel
    @EnvironmentObject var music: NowPlayingManager

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Group {
                if vm.showLyrics { LyricsPanel() } else { NowPlayingPanel() }
            }
            .frame(maxWidth: .infinity)
            .background(AlbumTintBackground(tint: music.hasTrack ? music.tint : nil))

            Rectangle().fill(.white.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity)

            DayCard().frame(width: 160)
        }
    }
}

/// The album's main color behind the player and lyrics, fading slightly toward the bottom.
struct AlbumTintBackground: View {
    let tint: Color?

    var body: some View {
        ZStack {
            if let tint {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.75)],
                                         startPoint: .top, endPoint: .bottom))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, -12)
        .padding(.vertical, -9)
        .animation(.easeInOut(duration: 0.6), value: tint)
    }
}

// MARK: - Now Playing

struct NowPlayingPanel: View {
    @EnvironmentObject var vm: IslandViewModel
    @EnvironmentObject var music: NowPlayingManager

    var body: some View {
        if music.hasTrack {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button { music.openPlayer() } label: {
                        ArtworkView(image: music.artwork, size: 60, corner: 13)
                    }
                    .buttonStyle(.plain)
                    .shadow(color: music.accent.opacity(0.45), radius: 12)
                    .help("Open \(music.player?.rawValue ?? "player")")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(music.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(music.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if music.isPlaying { EqualizerBars(color: music.accent) }
                }

                Scrubber()

                HStack(spacing: 0) {
                    toggle("shuffle", active: music.shuffle, help: "Shuffle") { music.toggleShuffle() }
                    Spacer()
                    control("backward.fill") { music.previous() }
                    Spacer()
                    control(music.isPlaying ? "pause.fill" : "play.fill", size: 22) { music.playPause() }
                    Spacer()
                    control("forward.fill") { music.next() }
                    Spacer()
                    toggle(music.repeatMode == .one ? "repeat.1" : "repeat",
                           active: music.repeatMode != .off, help: "Repeat") { music.cycleRepeat() }
                    Spacer()
                    toggle("quote.bubble", active: vm.showLyrics, help: "Lyrics") {
                        withAnimation(.snappy) { vm.showLyrics.toggle() }
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                Text("Play something in Spotify or Music")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, minHeight: 110)
        }
    }

    private func control(_ icon: String, size: CGFloat = 16, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func toggle(_ icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? music.accent : Color.white.opacity(0.45))
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

/// Progress bar you can drag to seek. It thickens under the pointer.
struct Scrubber: View {
    @EnvironmentObject var music: NowPlayingManager
    @State private var hovering = false
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration: Double = music.duration
            let livePosition: Double = music.position(at: context.date)
            let fraction: Double = dragFraction ?? Self.fraction(livePosition, of: duration)
            let shown: Double = dragFraction.map { $0 * duration } ?? livePosition
            let thick: Bool = hovering || dragFraction != nil

            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white.opacity(thick ? 1 : 0.85))
                            .frame(width: geo.size.width * CGFloat(fraction))
                    }
                    .frame(height: thick ? 8 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = Self.fraction(Double(value.location.x), of: Double(geo.size.width))
                            }
                            .onEnded { value in
                                let f: Double = Self.fraction(Double(value.location.x), of: Double(geo.size.width))
                                if duration > 0 { music.seek(to: f * duration) }
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 14)
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.2), value: thick)

                HStack {
                    Text(formatTime(shown))
                    Spacer()
                    Text("-" + formatTime(max(duration - shown, 0)))
                }
                .font(.system(size: 10, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// value / total, kept between 0 and 1.
    static func fraction(_ value: Double, of total: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }
}

// MARK: - Lyrics

struct LyricsPanel: View {
    @EnvironmentObject var vm: IslandViewModel
    @EnvironmentObject var music: NowPlayingManager
    @EnvironmentObject var lyrics: LyricsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ArtworkView(image: music.artwork, size: 32, corner: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(music.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(music.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { vm.showLyrics = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Back to player")
            }
            content.frame(height: 130)
        }
    }

    @ViewBuilder private var content: some View {
        switch lyrics.status {
        case .synced:
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                SyncedLyricsList(lines: lyrics.lines, current: lyrics.index(at: music.position(at: context.date)))
            }
        case .plainOnly:
            ScrollView(showsIndicators: false) {
                Text(lyrics.plainText ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .idle, .notFound:
            Text(music.hasTrack ? "No lyrics found for this song" : "Play a song to see its lyrics")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SyncedLyricsList: View {
    let lines: [LyricsManager.Line]
    let current: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(lines) { line in
                        let isCurrent = line.id == current
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: isCurrent ? 15 : 13, weight: isCurrent ? .bold : .medium))
                            .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 50)
            }
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
            .onChange(of: current) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }
}

// MARK: - Day

struct DayCard: View {
    @EnvironmentObject var rem: RemindersManager

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 0) {
                Text(context.date.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                Text(context.date.formatted(.dateTime.day()))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(dayLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))

                if let event = rem.nextEvent {
                    HStack(spacing: 7) {
                        Capsule().fill(event.color).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(eventTimeText(event, now: context.date))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 10)
                } else if !rem.calendarAuthorized {
                    Text("Allow Calendar access in Privacy & Security to see events.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 10)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dayLine: String {
        switch rem.todayCount {
        case 0: return "No events today"
        case 1: return "1 event today"
        default: return "\(rem.todayCount) events today"
        }
    }
}
