import Foundation
import AppKit
import CoreGraphics

/// Keeps the reading clock. Time counts toward today while a book is open,
/// Pagewrit is the app in front and you are actually there: after five minutes
/// with no keyboard, mouse or trackpad use it pauses by itself, and you can
/// pause it by hand. It also runs an optional countdown timer for a sitting.
/// Days, the daily goal and the streak live on this Mac only.
@MainActor
final class ReadingTracker: ObservableObject {
    static let shared = ReadingTracker()

    /// Counted every second, but screens only hear about it when the minute
    /// changes. Telling every view each second made the app sluggish.
    private(set) var secondsToday: Double = 0 {
        didSet { if Int(secondsToday / 60) != Int(oldValue / 60) { objectWillChange.send() } }
    }
    @Published private(set) var goalMinutes: Int
    private(set) var days: [String: Double]

    /// What the clock is doing right now, for the timer pill and panel.
    enum ClockState: Equatable {
        case noBookOpen, counting, paused, away, inactive
    }

    @Published private(set) var state: ClockState = .noBookOpen
    /// Reading time since the first book of this sitting was opened.
    private(set) var sessionSeconds: Double = 0 {
        didSet { if Int(sessionSeconds / 60) != Int(oldValue / 60) { objectWillChange.send() } }
    }
    /// You paused the clock yourself.
    @Published private(set) var isPaused = false
    /// An optional countdown: minutes asked for, and reading time spent so far.
    @Published private(set) var timerMinutes: Int?
    @Published private(set) var timerSeconds: Double = 0

    /// No input for this long and the clock assumes you stepped away.
    static let awayAfter: TimeInterval = 5 * 60

    /// Reading time since your last real break (stepping away counts).
    private var sinceBreak: Double = 0

    private var openCount = 0
    private var lastSaved = Date.distantPast

    private func saveDays() {
        UserDefaults.standard.set(days, forKey: daysKey)
        lastSaved = Date()
    }
    private var lastTick: Date?
    private var ticker: Task<Void, Never>?
    private var appActive = true

    private let daysKey = "pagewrit.readingDays"
    private let goalKey = "pagewrit.readingGoalMinutes"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String { dayFormatter.string(from: date) }

    private init() {
        let defaults = UserDefaults.standard
        days = (defaults.dictionary(forKey: daysKey) as? [String: Double]) ?? [:]
        let saved = defaults.integer(forKey: goalKey)
        goalMinutes = saved > 0 ? saved : 20
        secondsToday = days[Self.key(Date())] ?? 0

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.accrue()
                self?.saveDays()
                self?.lastTick = nil
                self?.appActive = false
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveDays() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appActive = true
                if self.openCount > 0 { self.lastTick = Date() }
            }
        }
    }

    /// After a restore: pick up the goal and history that were just written.
    func reloadFromDefaults() {
        objectWillChange.send()
        let defaults = UserDefaults.standard
        days = (defaults.dictionary(forKey: daysKey) as? [String: Double]) ?? [:]
        let saved = defaults.integer(forKey: goalKey)
        goalMinutes = saved > 0 ? saved : 20
        secondsToday = days[Self.key(Date())] ?? 0
    }

    // MARK: Clock

    /// A reader opened.
    func begin() {
        openCount += 1
        guard ticker == nil else { return }
        lastTick = appActive ? Date() : nil
        updateState()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.accrue()
            }
        }
    }

    func togglePause() {
        accrue()
        isPaused.toggle()
        lastTick = isPaused ? nil : Date()
        updateState()
    }

    /// Starts a countdown. It runs on reading time, so it waits while no book
    /// is open, while paused and while you are away.
    func startTimer(minutes: Int) {
        timerMinutes = min(max(minutes, 1), 300)
        timerSeconds = 0
        if isPaused { togglePause() }
    }

    func stopTimer() {
        timerMinutes = nil
        timerSeconds = 0
    }

    var timerRemaining: Double {
        guard let timerMinutes else { return 0 }
        return max(Double(timerMinutes) * 60 - timerSeconds, 0)
    }

    var timerProgress: Double {
        guard let timerMinutes, timerMinutes > 0 else { return 0 }
        return min(timerSeconds / (Double(timerMinutes) * 60), 1)
    }

    /// Seconds since the last keyboard, mouse or trackpad input anywhere.
    private static var secondsSinceInput: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    private func updateState() {
        let next: ClockState
        if openCount == 0 { next = .noBookOpen }
        else if isPaused { next = .paused }
        else if !appActive { next = .inactive }
        else if Self.secondsSinceInput > Self.awayAfter { next = .away }
        else { next = .counting }
        if next != state {
            // Stepping away, pausing or closing the book is a break.
            if next != .counting && next != .inactive { sinceBreak = 0 }
            state = next
        }
    }

    /// The date rolled over while Pagewrit stayed open.
    func refreshDay() {
        let today = days[Self.key(Date())] ?? 0
        if today != secondsToday { secondsToday = today }
    }

    /// A reader closed.
    func end() {
        openCount = max(openCount - 1, 0)
        guard openCount == 0 else { return }
        accrue()
        ticker?.cancel()
        ticker = nil
        lastTick = nil
        saveDays()
        sessionSeconds = 0
        isPaused = false
        updateState()
        DogPet.shared.playPendingFetch()
    }

    var isReading: Bool { openCount > 0 && appActive }

    var isReaderOpen: Bool { openCount > 0 }

    private func accrue() {
        updateState()
        refreshDay()
        guard let last = lastTick else { return }
        let now = Date()
        // A sleeping Mac or a long pause must not count as reading.
        let elapsed = min(now.timeIntervalSince(last), 15)
        lastTick = now
        guard elapsed > 0, state == .counting else { return }

        sessionSeconds += elapsed
        sinceBreak += elapsed
        let breakEvery = Wellbeing.breakEveryMinutes
        if breakEvery > 0, sinceBreak >= Double(breakEvery) * 60 {
            sinceBreak = 0
            celebrate(.rest(minutes: breakEvery))
        }
        if Wellbeing.isQuietNow(now) {
            let today = Self.key(now)
            if UserDefaults.standard.string(forKey: Wellbeing.windDownDayKey) != today {
                UserDefaults.standard.set(today, forKey: Wellbeing.windDownDayKey)
                celebrate(.windDown)
            }
        }
        if let timerMinutes {
            let before = timerSeconds
            timerSeconds += elapsed
            let target = Double(timerMinutes) * 60
            if before < target, timerSeconds >= target {
                self.timerMinutes = nil
                timerSeconds = 0
                celebrate(.timer(minutes: timerMinutes))
            }
        }

        let key = Self.key(now)
        let before = days[key] ?? 0
        let after = before + elapsed
        days[key] = after
        secondsToday = after
        // The clock ticks every second; the disk only needs it now and then.
        if now.timeIntervalSince(lastSaved) > 10 { saveDays() }

        let goal = Double(goalMinutes) * 60
        if before < goal, after >= goal {
            celebrate(.goal(minutes: goalMinutes, streak: streak))
        }
    }

    // MARK: Rewards

    /// A moment worth marking. Every Pagewrit window shows it the instant it
    /// happens, readers included.
    struct Celebration: Identifiable, Equatable {
        enum Kind: Equatable {
            case goal(minutes: Int, streak: Int)
            case finished(title: String)
            case timer(minutes: Int)
            /// Wellbeing: time to rest your eyes. No confetti, no sound.
            case rest(minutes: Int)
            /// Wellbeing: quiet hours have started. Shown once a night.
            case windDown
        }
        let id = UUID()
        let kind: Kind
        let toy: DogPet.Toy
    }

    @Published private(set) var celebration: Celebration?

    func celebrate(_ kind: Celebration.Kind) {
        let toy = DogPet.Toy.allCases.randomElement() ?? .ball
        let moment = Celebration(kind: kind, toy: toy)
        celebration = moment

        let line: String
        switch kind {
        case .goal(let minutes, _): line = "\(minutes) minutes today. I brought you this!"
        case .finished: line = "You finished a book! This is for you."
        case .timer(let minutes): line = "\(minutes) minutes, done. Nicely read."
        case .rest, .windDown:
            // Gentle moments: no fetch, no toy, just the card.
            celebration = Celebration(kind: kind, toy: toy)
            let id = celebration?.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                if self?.celebration?.id == id { self?.celebration = nil }
            }
            return
        }
        if isReaderOpen {
            // He also runs it over in the library when you get back.
            DogPet.shared.celebrate(line, toy: toy)
        } else {
            DogPet.shared.receive(toy, saying: line, after: DogPet.fetchDuration + 0.8)
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_500_000_000)
            if self?.celebration?.id == moment.id { self?.celebration = nil }
        }
    }

    func dismissCelebration() { celebration = nil }

    // MARK: Goal and streak

    static let goalRange = 1...300

    func setGoal(minutes: Int) {
        let wasMet = secondsToday >= Double(goalMinutes) * 60
        goalMinutes = min(max(minutes, Self.goalRange.lowerBound), Self.goalRange.upperBound)
        UserDefaults.standard.set(goalMinutes, forKey: goalKey)
        // Lowering the goal below what you have already read still counts.
        if !wasMet, secondsToday >= Double(goalMinutes) * 60 {
            celebrate(.goal(minutes: goalMinutes, streak: streak))
        }
    }

    var minutesToday: Int { Int(secondsToday / 60) }

    var progressToday: Double { min(secondsToday / (Double(goalMinutes) * 60), 1) }

    /// Days in a row that met the goal. Today counts once it is met, and an
    /// unfinished today does not break the run.
    var streak: Int {
        let cal = Calendar.current
        let goal = Double(goalMinutes) * 60
        var count = 0
        var day = Date()
        if (days[Self.key(day)] ?? 0) < goal {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        while (days[Self.key(day)] ?? 0) >= goal {
            count += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// Reading time over the last seven days, today included.
    var weekSeconds: Double { lastWeek.reduce(0) { $0 + $1.seconds } }

    /// Days with any reading at all.
    var daysRead: Int { days.values.filter { $0 >= 60 }.count }

    /// The longest run of days that met today's goal.
    var longestStreak: Int {
        let goal = Double(goalMinutes) * 60
        let met = days.filter { $0.value >= goal }.keys.compactMap { Self.dayFormatter.date(from: $0) }.sorted()
        var best = 0, run = 0
        var previous: Date?
        let cal = Calendar.current
        for day in met {
            if let previous, let next = cal.date(byAdding: .day, value: 1, to: previous),
               cal.isDate(next, inSameDayAs: day) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }

    /// The last seven days, oldest first, for the little bar chart.
    var lastWeek: [(label: String, seconds: Double, isToday: Bool)] {
        let cal = Calendar.current
        let letters = DateFormatter()
        letters.dateFormat = "EEEEE"
        return (0..<7).reversed().compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return (letters.string(from: date), days[Self.key(date)] ?? 0, offset == 0)
        }
    }
}


// MARK: - Wellbeing

/// Settings that look after the reader: break reminders and quiet hours.
enum Wellbeing {
    static let breakEveryKey = "pagewrit.breakEvery"
    static let quietDaysKey = "pagewrit.quietDays"
    static let quietStartKey = "pagewrit.quietStart"
    static let quietEndKey = "pagewrit.quietEnd"
    static let windDownDayKey = "pagewrit.windDownDay"
    static let easyReadingKey = "pagewrit.easyReading"

    /// 0 means off.
    static var breakEveryMinutes: Int { UserDefaults.standard.integer(forKey: breakEveryKey) }

    /// Weekdays as Calendar numbers, 1 = Sunday ... 7 = Saturday.
    static var quietDays: Set<Int> {
        Set((UserDefaults.standard.string(forKey: quietDaysKey) ?? "").compactMap { Int(String($0)) })
    }

    /// Minutes after midnight.
    static var quietStart: Int {
        UserDefaults.standard.object(forKey: quietStartKey) as? Int ?? 22 * 60
    }
    static var quietEnd: Int {
        UserDefaults.standard.object(forKey: quietEndKey) as? Int ?? 7 * 60
    }

    /// True inside quiet hours. Hours that run past midnight belong to the
    /// day they started on.
    static func isQuietNow(_ date: Date = Date()) -> Bool {
        let days = quietDays
        guard !days.isEmpty else { return false }
        let cal = Calendar.current
        let minute = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        let start = quietStart, end = quietEnd
        let weekday = cal.component(.weekday, from: date)
        if start <= end {
            return days.contains(weekday) && minute >= start && minute < end
        }
        if minute >= start { return days.contains(weekday) }
        if minute < end {
            let yesterday = weekday == 1 ? 7 : weekday - 1
            return days.contains(yesterday)
        }
        return false
    }
}
