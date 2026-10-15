import AppKit
import Darwin

// MARK: - Configuration (saved to ~/.notchisland/widgets.json)

enum WidgetKind: String, Codable, CaseIterable {
    case weather, system, stocks, countdown, script

    var menuTitle: String {
        switch self {
        case .weather: return "Weather…"
        case .system: return "System stats"
        case .stocks: return "Stocks & crypto…"
        case .countdown: return "Countdown…"
        case .script: return "Script…"
        }
    }
}

struct WidgetConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WidgetKind
    var title: String?       // countdown and script label
    var place: String?       // weather
    var latitude: Double?    // weather
    var longitude: Double?   // weather
    var symbols: [String]?   // stocks, e.g. ["AAPL", "BTC-USD"]
    var date: Date?          // countdown
    var command: String?     // script
    var interval: Double?    // script refresh, in seconds
}

extension WidgetConfig {
    /// Hand-edited files may leave out the id, so it's optional when reading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(WidgetKind.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        place = try c.decodeIfPresent(String.self, forKey: .place)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        symbols = try c.decodeIfPresent([String].self, forKey: .symbols)
        date = try c.decodeIfPresent(Date.self, forKey: .date)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        interval = try c.decodeIfPresent(Double.self, forKey: .interval)
    }
}

// MARK: - Live data

struct WeatherData: Equatable {
    let temperature: Double
    let high: Double
    let low: Double
    let code: Int
    let isDay: Bool
}

struct Quote: Equatable {
    let symbol: String
    let price: Double
    let changePercent: Double
    let currency: String
    let closes: [Double]
}

struct ScriptResult: Equatable {
    let lines: [String]
    let failed: Bool
}

struct SystemStats: Equatable {
    var cpu: Double = 0       // 0...1
    var memory: Double = 0    // 0...1
    var diskFree: Int64 = 0   // bytes
    var down: Double = 0      // bytes per second
    var up: Double = 0
}

// MARK: - Manager

/// Keeps the widget list and refreshes each widget's data while the Widgets tab is open.
@MainActor
final class WidgetManager: ObservableObject {
    @Published private(set) var configs: [WidgetConfig] = []
    @Published private(set) var weather: [UUID: WeatherData] = [:]
    @Published private(set) var quotes: [UUID: [Quote]] = [:]
    @Published private(set) var scripts: [UUID: ScriptResult] = [:]
    @Published private(set) var system = SystemStats()
    @Published private(set) var failed = Set<UUID>()
    @Published private(set) var fileError: String?
    @Published private(set) var message: String?

    let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".notchisland/widgets.json")

    private var fileDate: Date?
    private var lastRun: [UUID: Date] = [:]
    private var running = Set<UUID>()
    private var timer: Timer?
    private var active = false
    private var messageWork: DispatchWorkItem?
    private let sampler = SystemSampler()

    init() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            load()
        } else {
            configs = [WidgetConfig(kind: .system)]
            persist()
        }
    }

    /// Called when the Widgets tab opens or closes.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        timer?.invalidate()
        timer = nil
        guard on else { return }
        reloadIfChanged()
        tick()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Adding, editing, removing

    func add(_ kind: WidgetKind) { prompt(kind, editing: nil) }

    func edit(_ config: WidgetConfig) { prompt(config.kind, editing: config) }

    func remove(_ config: WidgetConfig) {
        configs.removeAll { $0.id == config.id }
        weather[config.id] = nil
        quotes[config.id] = nil
        scripts[config.id] = nil
        failed.remove(config.id)
        persist()
    }

    func refreshNow(_ config: WidgetConfig) {
        lastRun[config.id] = nil
        refresh(config)
    }

    func openFile() {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([fileURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    private func prompt(_ kind: WidgetKind, editing: WidgetConfig?) {
        let button = editing == nil ? "Add" : "Save"
        switch kind {
        case .system:
            upsert(editing ?? WidgetConfig(kind: .system))

        case .weather:
            guard let city = WidgetPrompts.text(title: editing == nil ? "Add weather" : "Edit weather",
                                                message: "Type a city name.",
                                                placeholder: "New York",
                                                value: editing?.place ?? "",
                                                button: button) else { return }
            show("Looking up \(city)…")
            Task {
                guard let found = await WidgetFetch.geocode(city) else {
                    self.show("Couldn't find “\(city)”")
                    return
                }
                var c = editing ?? WidgetConfig(kind: .weather)
                c.place = found.place
                c.latitude = found.latitude
                c.longitude = found.longitude
                self.message = nil
                self.upsert(c)
            }

        case .stocks:
            guard let symbols = WidgetPrompts.stocks(value: editing?.symbols ?? [], button: button) else { return }
            var c = editing ?? WidgetConfig(kind: .stocks)
            c.symbols = symbols
            upsert(c)

        case .countdown:
            let defaultDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
            guard let result = WidgetPrompts.countdown(title: editing?.title ?? "",
                                                       date: editing?.date ?? defaultDate,
                                                       button: button) else { return }
            var c = editing ?? WidgetConfig(kind: .countdown)
            c.title = result.title
            c.date = result.date
            upsert(c)

        case .script:
            guard let result = WidgetPrompts.script(title: editing?.title ?? "",
                                                    command: editing?.command ?? "",
                                                    interval: editing?.interval ?? 60,
                                                    button: button) else { return }
            var c = editing ?? WidgetConfig(kind: .script)
            c.title = result.title
            c.command = result.command
            c.interval = result.interval
            upsert(c)
        }
    }

    private func upsert(_ c: WidgetConfig) {
        if let i = configs.firstIndex(where: { $0.id == c.id }) {
            configs[i] = c
        } else {
            configs.append(c)
        }
        lastRun[c.id] = nil
        failed.remove(c.id)
        persist()
        refresh(c)
    }

    private func show(_ text: String) {
        message = text
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.message = nil }
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: Refreshing

    private func tick() {
        if configs.contains(where: { $0.kind == .system }) {
            system = sampler.sample()
        }
        let now = Date()
        for c in configs {
            let every: TimeInterval
            switch c.kind {
            case .weather: every = 15 * 60
            case .stocks: every = 60
            case .script: every = max(c.interval ?? 60, 5)
            case .system, .countdown: continue
            }
            if let last = lastRun[c.id], now.timeIntervalSince(last) < every { continue }
            refresh(c)
        }
    }

    private func refresh(_ c: WidgetConfig) {
        switch c.kind {
        case .system, .countdown: return
        default: break
        }
        guard !running.contains(c.id) else { return }
        running.insert(c.id)
        lastRun[c.id] = Date()
        let id = c.id

        Task {
            switch c.kind {
            case .weather:
                if let lat = c.latitude, let lon = c.longitude,
                   let data = await WidgetFetch.weather(latitude: lat, longitude: lon) {
                    self.weather[id] = data
                    self.failed.remove(id)
                } else {
                    self.failed.insert(id)
                }
            case .stocks:
                let list = await WidgetFetch.quotes(c.symbols ?? [])
                if list.isEmpty {
                    self.failed.insert(id)
                } else {
                    self.quotes[id] = list
                    self.failed.remove(id)
                }
            case .script:
                self.scripts[id] = await WidgetFetch.script(c.command ?? "")
            case .system, .countdown:
                break
            }
            self.running.remove(id)
        }
    }

    // MARK: File

    private func modificationDate() -> Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func reloadIfChanged() {
        if let date = modificationDate(), date != fileDate { load() }
    }

    private func load() {
        fileDate = modificationDate()
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        do {
            configs = try decoder.decode([WidgetConfig].self, from: data)
            fileError = nil
        } catch {
            fileError = "widgets.json has a mistake in it. Fix it or delete the file to start over."
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(configs).write(to: fileURL, options: .atomic)
            fileDate = modificationDate()
            fileError = nil
        } catch {
            fileError = "Couldn't save widgets: \(error.localizedDescription)"
        }
    }

    /// Accepts "2026-12-18T09:00:00-05:00" or just "2026-12-18".
    nonisolated private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let text = try decoder.singleValueContainer().decode(String.self)
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.dateFormat = "yyyy-MM-dd"
        if let date = dayOnly.date(from: text) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "Use a date like 2026-12-18"))
    }
}

// MARK: - System stats

/// Reads CPU, memory, disk and network usage. Call sample() every couple of seconds.
final class SystemSampler {
    private let host = mach_host_self()
    private var lastTicks: [UInt64]?
    private var lastNet: (down: UInt64, up: UInt64, date: Date)?

    func sample() -> SystemStats {
        var stats = SystemStats()
        stats.cpu = cpu()
        stats.memory = memory()
        stats.diskFree = diskFree()
        let net = network()
        stats.down = net.down
        stats.up = net.up
        return stats
    }

    private func delta(_ new: UInt64, _ old: UInt64) -> Double {
        new >= old ? Double(new - old) : 0
    }

    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { raw in
                host_statistics(host, HOST_CPU_LOAD_INFO, raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        // user, system, idle, nice
        let ticks: [UInt64] = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1),
                               UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return 0 }
        let user = delta(ticks[0], last[0])
        let sys = delta(ticks[1], last[1])
        let idle = delta(ticks[2], last[2])
        let nice = delta(ticks[3], last[3])
        let busy = user + sys + nice
        let total = busy + idle
        return total > 0 ? busy / total : 0
    }

    private func memory() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { raw in
                host_statistics64(host, HOST_VM_INFO64, raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        // Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
        let page = Double(vm_kernel_page_size)
        let appPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let usedPages = appPages + Double(stats.wire_count) + Double(stats.compressor_page_count)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        return min(max(usedPages * page / total, 0), 1)
    }

    private func diskFree() -> Int64 {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private func network() -> (down: Double, up: Double) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (0, 0) }
        defer { freeifaddrs(list) }

        var down: UInt64 = 0
        var up: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            if let address = entry.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               String(cString: entry.ifa_name).hasPrefix("en"),
               let raw = entry.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                down += UInt64(data.ifi_ibytes)
                up += UInt64(data.ifi_obytes)
            }
            cursor = entry.ifa_next
        }

        let now = Date()
        defer { lastNet = (down: down, up: up, date: now) }
        guard let last = lastNet else { return (0, 0) }
        let seconds = now.timeIntervalSince(last.date)
        guard seconds > 0 else { return (0, 0) }
        return (delta(down, last.down) / seconds, delta(up, last.up) / seconds)
    }
}

// MARK: - Network and scripts

enum WidgetFetch {
    static let usesFahrenheit = Locale.current.measurementSystem == .us

    static func geocode(_ name: String) async -> (place: String, latitude: Double, longitude: Double)? {
        // The search only understands the city name, so drop anything after a comma.
        let city = name.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? name
        guard var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "name", value: city),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        struct Response: Decodable {
            struct Place: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
            }
            let results: [Place]?
        }
        let response: Response? = await get(comps.url)
        guard let place = response?.results?.first else { return nil }
        return (place.name, place.latitude, place.longitude)
    }

    static func weather(latitude: Double, longitude: Double) async -> WeatherData? {
        guard var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "temperature_unit", value: usesFahrenheit ? "fahrenheit" : "celsius"),
        ]
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let weather_code: Int
                let is_day: Int
            }
            struct Daily: Decodable {
                let temperature_2m_max: [Double?]
                let temperature_2m_min: [Double?]
            }
            let current: Current
            let daily: Daily
        }
        let response: Response? = await get(comps.url)
        guard let r = response else { return nil }
        let now = r.current.temperature_2m
        let high: Double = (r.daily.temperature_2m_max.first ?? nil) ?? now
        let low: Double = (r.daily.temperature_2m_min.first ?? nil) ?? now
        return WeatherData(temperature: now, high: high, low: low,
                           code: r.current.weather_code, isDay: r.current.is_day == 1)
    }

    static func quotes(_ symbols: [String]) async -> [Quote] {
        var list: [Quote] = []
        for symbol in symbols.prefix(3) {
            if let quote = await quote(symbol) { list.append(quote) }
        }
        return list
    }

    /// Prices from Yahoo Finance's public chart data (no account needed).
    static func quote(_ symbol: String) async -> Quote? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-.="))
        let path = symbol.uppercased().addingPercentEncoding(withAllowedCharacters: allowed) ?? symbol
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(path)?range=1d&interval=15m")
        struct Response: Decodable {
            struct Chart: Decodable { let result: [ChartResult]? }
            struct ChartResult: Decodable {
                let meta: Meta
                let indicators: Indicators?
            }
            struct Meta: Decodable {
                let symbol: String
                let regularMarketPrice: Double?
                let chartPreviousClose: Double?
                let previousClose: Double?
                let currency: String?
            }
            struct Indicators: Decodable { let quote: [Series]? }
            struct Series: Decodable { let close: [Double?]? }
            let chart: Chart
        }
        let response: Response? = await get(url, browserAgent: true)
        guard let result = response?.chart.result?.first,
              let price = result.meta.regularMarketPrice else { return nil }
        let previous: Double = result.meta.chartPreviousClose ?? result.meta.previousClose ?? price
        let change: Double = previous > 0 ? (price - previous) / previous * 100 : 0
        let closes: [Double] = (result.indicators?.quote?.first?.close ?? []).compactMap { $0 }
        return Quote(symbol: result.meta.symbol, price: price, changePercent: change,
                     currency: result.meta.currency ?? "USD", closes: closes)
    }

    /// Runs a command in zsh (with your login PATH) and returns its output. Stops it after 15 seconds.
    static func script(_ command: String) async -> ScriptResult {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ScriptResult(lines: ["No command set"], failed: true)
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ScriptResult(lines: ["Couldn't run the command"], failed: true))
                    return
                }
                let stopper = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: stopper)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stopper.cancel()

                let text = String(decoding: data, as: UTF8.self)
                var lines = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let failed = process.terminationStatus != 0
                if lines.isEmpty {
                    lines = [failed ? "Exited with code \(process.terminationStatus)" : "No output"]
                }
                continuation.resume(returning: ScriptResult(lines: Array(lines.prefix(4)), failed: failed))
            }
        }
    }

    static func get<T: Decodable>(_ url: URL?, browserAgent: Bool = false) async -> T? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let agent = browserAgent
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            : "NotchIsland/2.1"
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let response = try? await URLSession.shared.data(for: request),
              (response.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: response.0)
    }
}

enum WeatherSymbol {
    /// SF Symbol for a WMO weather code (what Open-Meteo returns).
    static func name(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

// MARK: - Add / edit dialogs

@MainActor
enum WidgetPrompts {
    static func text(title: String, message: String, placeholder: String, value: String, button: String) -> String? {
        let field = textField(placeholder, value)
        let alert = makeAlert(title, message, rows: [("City", field)])
        guard run(alert, button: button, focus: field) else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static func stocks(value: [String], button: String) -> [String]? {
        let field = textField("AAPL, NVDA, BTC-USD", value.joined(separator: ", "))
        let alert = makeAlert(button == "Add" ? "Add stocks & crypto" : "Edit stocks & crypto",
                              "Up to 3 ticker symbols, separated by commas. For crypto, add -USD (BTC-USD, ETH-USD).",
                              rows: [("Symbols", field)])
        guard run(alert, button: button, focus: field) else { return nil }
        let symbols = field.stringValue
            .components(separatedBy: CharacterSet(charactersIn: ", "))
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        return symbols.isEmpty ? nil : Array(symbols.prefix(3))
    }

    static func countdown(title: String, date: Date, button: String) -> (title: String, date: Date)? {
        let name = textField("Finals, Trip, Birthday…", title)
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = date
        let alert = makeAlert(button == "Add" ? "Add countdown" : "Edit countdown",
                              "Counts down to a date and time.",
                              rows: [("Name", name), ("Date", picker)])
        guard run(alert, button: button, focus: name) else { return nil }
        let text = name.stringValue.trimmingCharacters(in: .whitespaces)
        return (text.isEmpty ? "Countdown" : text, picker.dateValue)
    }

    static func script(title: String, command: String, interval: Double, button: String)
        -> (title: String, command: String, interval: Double)? {
        let name = textField("Battery health, Unread mail…", title)
        let commandField = textField("curl -s wttr.in/?format=3", command)
        let intervalField = textField("60", String(Int(interval)))
        let alert = makeAlert(button == "Add" ? "Add script widget" : "Edit script widget",
                              "Runs a command in zsh while the Widgets tab is open. The first line of output is shown big, the next lines small. Only add commands you trust.",
                              rows: [("Name", name), ("Command", commandField), ("Refresh every (seconds)", intervalField)])
        guard run(alert, button: button, focus: name) else { return nil }
        let cmd = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return nil }
        let text = name.stringValue.trimmingCharacters(in: .whitespaces)
        let seconds = max(Double(intervalField.stringValue) ?? 60, 5)
        return (text.isEmpty ? "Script" : text, cmd, seconds)
    }

    // MARK: Helpers

    private static func textField(_ placeholder: String, _ value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        return field
    }

    /// An alert with a label above each control.
    private static func makeAlert(_ title: String, _ message: String, rows: [(String, NSView)]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let rowHeight: CGFloat = 46
        let height = CGFloat(rows.count) * rowHeight
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: height))
        for (index, row) in rows.enumerated() {
            let top = height - CGFloat(index) * rowHeight
            let label = NSTextField(labelWithString: row.0)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 0, y: top - 16, width: 280, height: 16)
            row.1.frame = NSRect(x: 0, y: top - 42, width: 280, height: 24)
            container.addSubview(label)
            container.addSubview(row.1)
        }
        alert.accessoryView = container
        return alert
    }

    private static func run(_ alert: NSAlert, button: String, focus: NSView) -> Bool {
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true) // the dialog needs the app in front to take typing
        alert.window.initialFirstResponder = focus
        return alert.runModal() == .alertFirstButtonReturn
    }
}
