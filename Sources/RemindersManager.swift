import EventKit
import SwiftUI

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?
    let color: Color
}

struct EventItem: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
}

/// Reads your Reminders and Calendar (the same data as the Apple apps, incl. iCloud).
@MainActor
final class RemindersManager: ObservableObject {
    @Published var items: [ReminderItem] = []
    @Published var nextEvent: EventItem?
    @Published var todayCount = 0
    @Published var remindersAuthorized = false
    @Published var calendarAuthorized = false

    /// Fired once when a calendar event is about 5 minutes away.
    var onUpcomingEvent: (@MainActor (EventItem) -> Void)?

    private let store = EKEventStore()
    private var cache: [String: EKReminder] = [:]
    private var notifiedEvents = Set<String>()
    private var ticker: Timer?

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUpcoming() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        Task { await requestAccess() }
    }

    func requestAccess() async {
        remindersAuthorized = (try? await store.requestFullAccessToReminders()) ?? false
        calendarAuthorized = (try? await store.requestFullAccessToEvents()) ?? false
        refresh()
    }

    func refresh() {
        if remindersAuthorized {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { [weak self] reminders in
                let list = reminders ?? []
                Task { @MainActor in self?.apply(list) }
            }
        }
        if calendarAuthorized { loadNextEvent() }
    }

    // MARK: Reminders

    private func dueDate(_ r: EKReminder) -> Date? {
        r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    }

    private func apply(_ reminders: [EKReminder]) {
        let sorted = reminders.sorted { a, b in
            switch (dueDate(a), dueDate(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true          // dated reminders first
            case (nil, _?): return false
            default: return (a.creationDate ?? .distantPast) > (b.creationDate ?? .distantPast)
            }
        }
        cache = Dictionary(sorted.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        items = sorted.prefix(25).map {
            ReminderItem(id: $0.calendarItemIdentifier,
                         title: $0.title ?? "Untitled",
                         due: dueDate($0),
                         color: Color(nsColor: $0.calendar?.color ?? .systemBlue))
        }
    }

    func complete(_ item: ReminderItem) {
        guard let reminder = cache[item.id] else { return }
        reminder.isCompleted = true
        do { try store.save(reminder, commit: true) } catch { print("Couldn't complete reminder:", error) }
        withAnimation(.snappy) { items.removeAll { $0.id == item.id } }
    }

    func add(title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, remindersAuthorized,
              let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = list
        do { try store.save(reminder, commit: true) } catch { print("Couldn't add reminder:", error) }
        refresh()
    }

    // MARK: Calendar

    private func loadNextEvent() {
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        // Look up to two weeks ahead for the next event.
        let predicate = store.predicateForEvents(withStart: startOfToday,
                                                 end: now.addingTimeInterval(14 * 24 * 3600),
                                                 calendars: nil)
        let events = store.events(matching: predicate)
        let endOfToday = startOfToday.addingTimeInterval(24 * 3600)
        let count = events.filter { $0.startDate < endOfToday && $0.endDate > startOfToday }.count
        if count != todayCount { todayCount = count }
        let event = events
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first

        let newEvent = event.map {
            EventItem(id: "\($0.eventIdentifier ?? "")-\($0.startDate.timeIntervalSince1970)",
                      title: $0.title ?? "Event",
                      start: $0.startDate,
                      end: $0.endDate,
                      color: Color(nsColor: $0.calendar?.color ?? .systemBlue))
        }
        if newEvent != nextEvent { nextEvent = newEvent }
    }

    private func checkUpcoming() {
        guard calendarAuthorized else { return }
        loadNextEvent()
        guard let e = nextEvent, !notifiedEvents.contains(e.id) else { return }
        let lead = e.start.timeIntervalSinceNow
        if lead > 0 && lead <= 5 * 60 {
            notifiedEvents.insert(e.id)
            onUpcomingEvent?(e)
        }
    }
}
