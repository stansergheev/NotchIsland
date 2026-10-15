import Foundation

/// Fetches time-synced lyrics from LRCLIB (a free, open lyrics database).
/// Only the song title, artist, album and length are sent.
@MainActor
final class LyricsManager: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id: Int
        let time: Double
        let text: String
    }

    enum Status: Equatable {
        case idle, loading, synced, plainOnly, notFound
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var plainText: String?
    @Published private(set) var status: Status = .idle

    var hasSynced: Bool { status == .synced && !lines.isEmpty }

    private var task: Task<Void, Never>?
    private var cache: [String: ([Line], String?)] = [:]

    func load(_ track: TrackInfo?) {
        task?.cancel()
        guard let track, !track.title.isEmpty else {
            apply(([], nil), status: .idle)
            return
        }
        let key = "\(track.artist)|\(track.title)"
        if let hit = cache[key] {
            apply(hit)
            return
        }
        lines = []
        plainText = nil
        status = .loading
        task = Task { [weak self] in
            let result = await Self.fetch(track)
            guard !Task.isCancelled, let self else { return }
            self.cache[key] = result
            self.apply(result)
        }
    }

    /// Index of the line being sung at `position` seconds.
    func index(at position: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        return lines.lastIndex { $0.time <= position + 0.3 }
    }

    func line(at position: Double) -> String? {
        guard let i = index(at: position) else { return nil }
        let text = lines[i].text
        return text.isEmpty ? "♪" : text
    }

    private func apply(_ result: ([Line], String?), status forced: Status? = nil) {
        lines = result.0
        plainText = result.1
        if let forced {
            status = forced
        } else if !lines.isEmpty {
            status = .synced
        } else if plainText != nil {
            status = .plainOnly
        } else {
            status = .notFound
        }
    }

    // MARK: Network

    private struct LRCLibTrack: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    nonisolated private static func fetch(_ t: TrackInfo) async -> ([Line], String?) {
        // 1. Exact match (needs all four fields).
        if t.duration > 0, var comps = URLComponents(string: "https://lrclib.net/api/get") {
            comps.queryItems = [
                URLQueryItem(name: "track_name", value: t.title),
                URLQueryItem(name: "artist_name", value: t.artist),
                URLQueryItem(name: "album_name", value: t.album),
                URLQueryItem(name: "duration", value: String(Int(t.duration.rounded()))),
            ]
            let exact: LRCLibTrack? = await get(comps.url)
            if let exact, let result = convert(exact) { return result }
        }

        // 2. Looser search by title and artist.
        if var comps = URLComponents(string: "https://lrclib.net/api/search") {
            comps.queryItems = [
                URLQueryItem(name: "track_name", value: t.title),
                URLQueryItem(name: "artist_name", value: t.artist),
            ]
            let results: [LRCLibTrack]? = await get(comps.url)
            if let results {
                let best = results.first { !($0.syncedLyrics ?? "").isEmpty } ?? results.first
                if let best, let result = convert(best) { return result }
            }
        }
        return ([], nil)
    }

    nonisolated private static func convert(_ track: LRCLibTrack) -> ([Line], String?)? {
        let synced = parse(track.syncedLyrics ?? "")
        let plain = track.plainLyrics.flatMap { $0.isEmpty ? nil : $0 }
        if synced.isEmpty && plain == nil { return nil }
        return (synced, plain)
    }

    nonisolated private static func get<T: Decodable>(_ url: URL?) async -> T? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("NotchIsland/1.0 (personal project)", forHTTPHeaderField: "User-Agent")
        guard let response = try? await URLSession.shared.data(for: request),
              (response.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: response.0)
    }

    /// Parses LRC text like "[01:23.45] some words" (a line may have several time tags).
    nonisolated static func parse(_ lrc: String) -> [Line] {
        var entries: [(Double, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    times.append(minutes * 60 + seconds)
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for time in times { entries.append((time, text)) }
        }
        return entries
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
