import SwiftUI

// MARK: - Widgets tab

struct WidgetsTab: View {
    @EnvironmentObject var widgets: WidgetManager
    @EnvironmentObject var vm: IslandViewModel

    private let columns = 3
    private let cardHeight: CGFloat = 86
    private let spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Widgets").font(.system(size: 13, weight: .semibold))
                if let message = widgets.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    ForEach(WidgetKind.allCases, id: \.self) { kind in
                        Button(kind.menuTitle) { pinned { widgets.add(kind) } }
                    }
                    Divider()
                    Button("Open widgets file…") { widgets.openFile() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a widget")
            }

            if let error = widgets.fileError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            if widgets.configs.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("Add a widget with the + button")
                        .font(.system(size: 12, weight: .medium))
                    Text("Weather, system stats, stocks, countdowns, or your own script.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
            } else {
                let rows = chunked(widgets.configs)
                if rows.count > 3 {
                    ScrollView(showsIndicators: false) { grid(rows) }
                        .frame(height: cardHeight * 3 + spacing * 2)
                } else {
                    grid(rows)
                }
                Text("Right-click a widget to edit, refresh or remove it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func grid(_ rows: [[WidgetConfig]]) -> some View {
        VStack(spacing: spacing) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: spacing) {
                    ForEach(rows[index]) { config in
                        WidgetCard(config: config, height: cardHeight)
                    }
                    ForEach(0..<(columns - rows[index].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: cardHeight)
                    }
                }
            }
        }
    }

    private func chunked(_ list: [WidgetConfig]) -> [[WidgetConfig]] {
        stride(from: 0, to: list.count, by: columns).map { start in
            Array(list[start..<min(start + columns, list.count)])
        }
    }

    /// Keeps the island open while a dialog is showing.
    private func pinned(_ action: () -> Void) {
        vm.isPinned = true
        action()
        vm.isPinned = false
    }
}

struct WidgetCard: View {
    let config: WidgetConfig
    let height: CGFloat
    @EnvironmentObject var widgets: WidgetManager
    @EnvironmentObject var vm: IslandViewModel

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contextMenu {
                if config.kind != .system {
                    Button("Edit…") {
                        vm.isPinned = true
                        widgets.edit(config)
                        vm.isPinned = false
                    }
                }
                if config.kind != .countdown {
                    Button("Refresh") { widgets.refreshNow(config) }
                }
                Divider()
                Button("Remove") { widgets.remove(config) }
            }
    }

    @ViewBuilder private var content: some View {
        switch config.kind {
        case .weather: WeatherWidgetView(config: config)
        case .system: SystemWidgetView()
        case .stocks: StocksWidgetView(config: config)
        case .countdown: CountdownWidgetView(config: config)
        case .script: ScriptWidgetView(config: config)
        }
    }
}

/// Spinner while loading, or a short message if loading failed.
struct WidgetStatus: View {
    let failed: Bool

    var body: some View {
        if failed {
            Text("Couldn't load. Right-click to retry.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 6)
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 8)
        }
    }
}

// MARK: - Weather

struct WeatherWidgetView: View {
    let config: WidgetConfig
    @EnvironmentObject var widgets: WidgetManager

    var body: some View {
        let data = widgets.weather[config.id]
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: data.map { WeatherSymbol.name(code: $0.code, isDay: $0.isDay) } ?? "cloud.sun.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 15))
                Text(config.place ?? "Weather")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            if let data {
                Text("\(Int(data.temperature.rounded()))°")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("H \(Int(data.high.rounded()))°  L \(Int(data.low.rounded()))°")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                WidgetStatus(failed: widgets.failed.contains(config.id))
            }
        }
    }
}

// MARK: - System stats

struct SystemWidgetView: View {
    @EnvironmentObject var widgets: WidgetManager

    var body: some View {
        let s = widgets.system
        VStack(alignment: .leading, spacing: 4) {
            meter("CPU", s.cpu)
            meter("Memory", s.memory)
            row("Disk", ByteCountFormatter.string(fromByteCount: s.diskFree, countStyle: .file) + " free")
            row("Net", "↓ " + Self.rate(s.down) + "  ↑ " + Self.rate(s.up))
        }
        .font(.system(size: 10, weight: .medium))
    }

    private func meter(_ label: String, _ value: Double) -> some View {
        let clamped: Double = min(max(value, 0), 1)
        let tint: Color = clamped > 0.85 ? .red : (clamped > 0.6 ? .orange : .green)
        return HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(tint).frame(width: geo.size.width * CGFloat(clamped))
                }
            }
            .frame(height: 4)
            Text("\(Int((clamped * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

// MARK: - Stocks & crypto

struct StocksWidgetView: View {
    let config: WidgetConfig
    @EnvironmentObject var widgets: WidgetManager

    var body: some View {
        let list = widgets.quotes[config.id] ?? []
        if list.count == 1, let q = list.first {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(q.symbol).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(Self.change(q))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Self.color(q))
                }
                Text(Self.price(q))
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Sparkline(values: q.closes, color: Self.color(q))
                    .frame(height: 18)
            }
        } else if !list.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(list.prefix(3), id: \.symbol) { q in
                    HStack(spacing: 4) {
                        Text(q.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.price(q))
                            .font(.system(size: 10).monospacedDigit())
                            .lineLimit(1)
                        Text(Self.change(q))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Self.color(q))
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text((config.symbols ?? []).joined(separator: ", "))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                WidgetStatus(failed: widgets.failed.contains(config.id))
            }
        }
    }

    static func price(_ q: Quote) -> String {
        let digits = q.price < 1 ? 4 : 2
        return q.price.formatted(.currency(code: q.currency).precision(.fractionLength(digits)))
    }

    static func change(_ q: Quote) -> String {
        String(format: "%+.2f%%", q.changePercent)
    }

    static func color(_ q: Quote) -> Color {
        q.changePercent >= 0 ? .green : .red
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1, let low = values.min(), let high = values.max() else { return }
                let range: Double = max(high - low, 0.000_001)
                let width: CGFloat = geo.size.width
                let height: CGFloat = geo.size.height
                let lastIndex: CGFloat = CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let x: CGFloat = width * CGFloat(index) / lastIndex
                    let y: CGFloat = height * CGFloat(1 - (value - low) / range)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Countdown

struct CountdownWidgetView: View {
    let config: WidgetConfig

    struct Remaining {
        let value: String
        let unit: String
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let target = config.date ?? context.date
            let left = Self.remaining(to: target, now: context.date)
            VStack(alignment: .leading, spacing: 0) {
                Text(config.title ?? "Countdown")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(left.value)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(left.unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(target.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    static func remaining(to date: Date, now: Date) -> Remaining {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 {
            let days = Int(-seconds / 86_400)
            if days == 0 { return Remaining(value: "Now", unit: "") }
            return Remaining(value: "\(days)", unit: days == 1 ? "day ago" : "days ago")
        }
        if seconds < 3_600 {
            let minutes = Int((seconds / 60).rounded(.up))
            return Remaining(value: "\(minutes)", unit: minutes == 1 ? "minute" : "minutes")
        }
        if seconds < 48 * 3_600 {
            let hours = Int(seconds / 3_600)
            return Remaining(value: "\(hours)", unit: hours == 1 ? "hour" : "hours")
        }
        return Remaining(value: "\(Int(seconds / 86_400))", unit: "days")
    }
}

// MARK: - Script

struct ScriptWidgetView: View {
    let config: WidgetConfig
    @EnvironmentObject var widgets: WidgetManager

    var body: some View {
        let result = widgets.scripts[config.id]
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "terminal").font(.system(size: 9, weight: .semibold))
                Text(config.title ?? "Script").font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.55))

            if let result {
                Text(result.lines.first ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(result.failed ? Color.red : Color.white)
                    .lineLimit(result.lines.count > 1 ? 1 : 2)
                    .minimumScaleFactor(0.8)
                ForEach(Array(result.lines.dropFirst().prefix(2).enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            } else {
                WidgetStatus(failed: false)
            }
        }
    }
}
