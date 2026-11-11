import SwiftUI
import AppKit

// MARK: - The dog's state

/// The library dog sits in the corner of the sidebar, facing you. He wags,
/// blinks, tilts his head, hops when something good happens and falls asleep
/// when nobody is around. When you reach your reading goal or finish a book he
/// runs off the edge of the screen and comes back with a toy.
@MainActor
final class DogPet: ObservableObject {
    static let shared = DogPet()

    enum Mood { case calm, happy }
    enum Toy: CaseIterable { case ball, bone, ring }

    /// The fetch run, in seconds: out, out of sight, and back.
    static let runOut = 1.2
    static let outOfSight = 0.9
    static let runBack = 1.5
    static var fetchDuration: Double { runOut + outOfSight + runBack }

    @Published private(set) var mood: Mood = .calm
    @Published private(set) var line: String?
    @Published private(set) var hopTick = 0
    @Published private(set) var lastActive = Date()
    /// Set while he is running for a toy.
    @Published private(set) var fetchStart: Date?
    @Published private(set) var fetchingToy: Toy = .ball
    /// The toy in his mouth when he gets back.
    @Published private(set) var carrying: Toy?
    /// The toy resting by his paws afterwards.
    @Published private(set) var toyAside: Toy?

    private var reset: Task<Void, Never>?
    private var fetchRun: Task<Void, Never>?
    private var pendingFetch: String?
    private var pendingToy: Toy?

    var isFetching: Bool { fetchStart != nil }

    // MARK: Fetch on command

    private static let fetchLines = [
        "Got it!", "Again? Again!", "Best game ever.", "Fetched. Back to reading?",
        "I would do this all day.", "Here you go."
    ]

    /// Throw the ball: the dog runs off the edge and brings something back.
    func playFetch() {
        guard fetchRun == nil, fetchStart == nil else { return }
        Haptics.tick()
        pendingToy = nil
        fetchRun = Task { [weak self] in
            await self?.runFetch(Self.fetchLines.randomElement() ?? "Got it!")
            self?.fetchRun = nil
        }
    }

    /// The name you gave him on the welcome screen, or in Settings.
    static let nameKey = "pagewrit.dogName"
    static var name: String {
        (UserDefaults.standard.string(forKey: nameKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// For sentences: the dog's name, or "your dog" if there is none yet.
    static var callName: String { name.isEmpty ? "your dog" : name }

    /// How people want their dog talked about. Chosen when they meet the
    /// dog, and in Settings. "They" until someone picks.
    enum Pronoun: String, CaseIterable, Identifiable {
        case she, he, they
        var id: String { rawValue }

        var label: String {
            switch self {
            case .she: return "She"
            case .he: return "He"
            case .they: return "They"
            }
        }
        /// she / he / they
        var subject: String { rawValue }
        var Subject: String { label }
        /// her / him / them
        var object: String {
            switch self {
            case .she: return "her"
            case .he: return "him"
            case .they: return "them"
            }
        }
        /// "keeps" for she and he, "keep" for they.
        func verb(_ singular: String, _ plural: String) -> String {
            self == .they ? plural : singular
        }
    }

    static let pronounKey = "pagewrit.dogPronoun"
    static var pronoun: Pronoun {
        Pronoun(rawValue: UserDefaults.standard.string(forKey: pronounKey) ?? "") ?? .they
    }

    private static var pokeLines: [String] {
        var lines = [
            "Woof!",
            "On duty.",
            "Found anything good to read?",
            "I would fetch you a book, but I have no hands.",
            "Pat accepted.",
            "Ask me again, I have lots of wags.",
            "Belly rubs are a valid reading break."
        ]
        if !name.isEmpty {
            lines += ["\(name) reporting for reading duty.", "\(name) likes it when you read."]
        }
        return lines
    }

    /// Something nice happened: the dog hops, wags harder and may say a few words.
    func cheer(_ text: String? = nil) {
        lastActive = Date()
        mood = .happy
        line = text
        hopTick += 1
        reset?.cancel()
        reset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            guard !Task.isCancelled else { return }
            self?.mood = .calm
            self?.line = nil
        }
    }

    func touch() { lastActive = Date() }

    /// A click on the dog himself.
    func poke() {
        Haptics.tick()
        cheer(Self.pokeLines.randomElement())
    }

    /// A reading win. If a reader is open he waits, so you see the run when
    /// you come back to the library.
    func celebrate(_ message: String, toy: Toy? = nil) {
        pendingFetch = message
        pendingToy = toy
        if !ReadingTracker.shared.isReaderOpen { playPendingFetch() }
    }

    /// He already fetched it on screen elsewhere: the toy lands by his paws.
    func receive(_ toy: Toy, saying line: String, after delay: Double) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.carrying = nil
            self.toyAside = toy
            self.cheer(line)
        }
    }

    /// Called when the last reader closes.
    func playPendingFetch() {
        guard let message = pendingFetch, fetchRun == nil else { return }
        pendingFetch = nil
        fetchRun = Task { [weak self] in
            // Give the library window a moment to come forward.
            try? await Task.sleep(nanoseconds: 700_000_000)
            await self?.runFetch(message)
            self?.fetchRun = nil
        }
    }

    private func runFetch(_ message: String) async {
        lastActive = Date()
        reset?.cancel()
        mood = .happy
        line = nil
        fetchingToy = pendingToy ?? Toy.allCases.filter { $0 != toyAside }.randomElement() ?? .ball
        pendingToy = nil
        toyAside = nil
        carrying = nil

        if !PWAccessibility.reduceMotion {
            fetchStart = Date()
            try? await Task.sleep(nanoseconds: UInt64(Self.fetchDuration * 1_000_000_000))
            fetchStart = nil
        }
        carrying = fetchingToy
        cheer(message)
        try? await Task.sleep(nanoseconds: 2_800_000_000)
        carrying = nil
        toyAside = fetchingToy
    }
}

// MARK: - Picking a book

/// Chooses what to read next, favouring favourites and high ratings.
@MainActor
enum BookSuggester {
    enum Source: String, CaseIterable, Identifiable {
        case anything, inProgress, unstarted, favourites, loved
        var id: String { rawValue }

        var label: String {
            switch self {
            case .anything: return "Anything"
            case .inProgress: return "In progress"
            case .unstarted: return "Not started"
            case .favourites: return "Favorites"
            case .loved: return "Rated 4 dogs and up"
            }
        }

        var emptyText: String {
            switch self {
            case .anything: return "Add a few books and I will pick one for you."
            case .inProgress: return "Nothing in progress right now. Start something new?"
            case .unstarted: return "You have started everything. Impressive."
            case .favourites: return "No favorites yet. Heart a book and I will remember it."
            case .loved: return "Rate a few books 4 dogs or more and I will suggest them here."
            }
        }
    }

    struct Pick {
        let book: Book
        let reason: String
    }

    static func suggest(from books: [Book], source: Source = .anything, avoiding: String?) -> Pick? {
        let readable = books.filter { book in
            book.format != .pptx
                && !book.isFinished
                && !InvoiceStore.shared.contains(book.contentHash)
        }
        func progress(_ book: Book) -> Double { book.readingProgress ?? 0 }
        func mostRecent(_ list: [Book]) -> Book? {
            list.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
        }

        var pool: [Book]
        switch source {
        case .anything:
            // First idea: pick up where you left off.
            if avoiding == nil, let current = mostRecent(readable.filter { progress($0) > 0 }) {
                return Pick(book: current, reason: reason(for: current))
            }
            let unstarted = readable.filter { progress($0) == 0 }
            pool = unstarted.isEmpty ? readable : unstarted
        case .inProgress:
            pool = readable.filter { progress($0) > 0 }
            if avoiding == nil, let latest = mostRecent(pool) {
                return Pick(book: latest, reason: reason(for: latest))
            }
        case .unstarted:
            pool = readable.filter { progress($0) == 0 }
        case .favourites:
            pool = readable.filter { $0.isFavorite }
        case .loved:
            pool = readable.filter { $0.rating >= 4 }
        }

        let fresh = pool.filter { $0.contentHash != avoiding }
        if !fresh.isEmpty { pool = fresh }
        guard !pool.isEmpty else { return nil }

        let weighted = pool.flatMap { book -> [Book] in
            let weight = 1 + (book.isFavorite ? 3 : 0) + max(book.rating - 2, 0) * 2
            return Array(repeating: book, count: weight)
        }
        guard let chosen = weighted.randomElement() else { return nil }
        return Pick(book: chosen, reason: reason(for: chosen))
    }

    private static func reason(for book: Book) -> String {
        let progress = book.readingProgress ?? 0
        if progress > 0 { return "You are \(max(Int(progress * 100), 1))% through. Pick it back up." }
        if book.isFavorite { return "One of your favorites, still waiting for you." }
        if book.rating >= 4 { return "You rated this highly. Worth a read." }
        return "Still unread. Today could be the day."
    }
}

// MARK: - The drawing

/// A fluffy white dog drawn from shapes, so he stays sharp at any size and every
/// part can move on its own. He sits facing you, and turns side on to run.
struct DogMascot: View {
    var mood: DogPet.Mood = .calm
    var hopTick: Int = 0
    var lastActive: Date = Date()
    var fetchStart: Date?
    var fetchingToy: DogPet.Toy = .ball
    var carrying: DogPet.Toy?
    var toyAside: DogPet.Toy?
    /// How far he runs, in points, to leave the screen.
    var travel: CGFloat = 240
    var size: CGFloat = 72

    @Environment(\.pagewritReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hopStart = Date.distantPast

    private var windowIsActive: Bool { controlActiveState != .inactive }

    private var frameInterval: Double {
        let busy = fetchStart != nil || mood == .happy
            || Date().timeIntervalSince(hopStart) < 1
        return busy ? 1.0 / 30.0 : 1.0 / 12.0
    }

    private var fur: Color { Color(red: 0.985, green: 0.985, blue: 0.99) }
    private var shade: Color { Color(red: 0.86, green: 0.88, blue: 0.92) }
    private var cream: Color { Color(red: 1.0, green: 0.975, blue: 0.95) }
    private var ink: Color { Color(red: 0.14, green: 0.12, blue: 0.14) }
    private var tongue: Color { Color(red: 0.95, green: 0.50, blue: 0.55) }
    private var boneColor: Color { Color(red: 0.93, green: 0.84, blue: 0.66) }

    private struct RunFrame {
        let x: CGFloat
        let facingRight: Bool
        let holding: Bool
    }

    var body: some View {
        // Smooth only when it matters: 30 frames a second while he runs or
        // celebrates, a relaxed 12 otherwise, and none at all when the window
        // is in the background. He used to redraw at 30 nonstop, which made
        // the whole app feel heavy.
        TimelineView(.animation(minimumInterval: frameInterval, paused: reduceMotion || !windowIsActive)) { context in
            let now = context.date
            let t = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate
            let elapsed = fetchStart.map { now.timeIntervalSince($0) } ?? -1
            let running = elapsed >= 0 && elapsed < DogPet.fetchDuration

            ZStack {
                if running {
                    let run = runPath(elapsed)
                    runner(t: t, carrying: run.holding ? fetchingToy : nil)
                        .frame(width: 100, height: 80)
                        .scaleEffect(x: run.facingRight ? 1 : -1, y: 1)
                        .offset(x: run.x * 100 / size)
                } else {
                    sitter(t: t, now: now)
                }
            }
            .frame(width: 100, height: 80)
            // A soft edge so a white dog still reads on a light sidebar.
            // Flattened into one image on the GPU before the shadow, instead
            // of shading a hundred little shapes one by one.
            .drawingGroup()
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.28), radius: 0.9)
            .offset(y: hopOffset(at: now))
            .scaleEffect(size / 100, anchor: .topLeading)
            .frame(width: size, height: size * 0.8, alignment: .topLeading)
        }
        .onChange(of: hopTick) { _, _ in hopStart = Date() }
        .accessibilityLabel(DogPet.name.isEmpty ? "Your library dog" : "\(DogPet.name), your library dog")
    }

    // MARK: Sitting, facing you

    private func sitter(t: Double, now: Date, pawUp: CGFloat = 0, deadEyes: Bool = false,
                        forceHappy: Bool = false, still: Bool = false) -> some View {
        let asleep = !forceHappy && !deadEyes
            && now.timeIntervalSince(lastActive) > 120 && mood == .calm && carrying == nil
        let happy = mood == .happy || forceHappy
        let breathe = 1 + 0.02 * sin(t * (asleep ? 1.2 : 2.2))
        let wag = (asleep || still) ? 0.0 : sin(t * (happy ? 15.0 : 5.0)) * (happy ? 26.0 : 10.0)
        let blinking = !asleep && t.truncatingRemainder(dividingBy: 4.6) < 0.13
        let earTwitch = t.truncatingRemainder(dividingBy: 7.3) < 0.25 ? 8.0 : 0.0
        let tiltPhase = t.truncatingRemainder(dividingBy: 9.7)
        let tilt = asleep ? 0.0 : (tiltPhase < 1.6 ? 9 * sin(tiltPhase / 1.6 * .pi) : 0)
        let glance = asleep ? 0 : CGFloat(sin(t * 0.6)) * 0.7

        return ZStack {
            // Tail, sweeping behind him on the right
            plume()
                .scaleEffect(0.9, anchor: .bottom)
                .rotationEffect(.degrees(30 + wag * 0.7), anchor: .bottom)
                .position(x: 66, y: 58)

            // Haunches and body
            fluff(rx: 13, ry: 11, tufts: 10, r: 3.6, color: shade, phase: t)
                .position(x: 34, y: 66)
            fluff(rx: 13, ry: 11, tufts: 10, r: 3.6, color: shade, phase: t + 0.5)
                .position(x: 66, y: 66)
            fluff(rx: 17, ry: 19, tufts: 14, r: 4.2, color: fur, phase: t + 1)
                .scaleEffect(breathe, anchor: .bottom)
                .position(x: 50, y: 55)

            // Front legs and paws
            ForEach([43.0, 57.0], id: \.self) { x in
                // His right paw lifts for a high five.
                let lift = x > 50 ? pawUp : 0
                ZStack(alignment: .bottom) {
                    Capsule().fill(fur).frame(width: 9, height: 20)
                    Ellipse().fill(fur).frame(width: 12, height: 7).offset(y: 3)
                    HStack(spacing: 2.8) {
                        Capsule().fill(shade).frame(width: 1.1, height: 3)
                        Capsule().fill(shade).frame(width: 1.1, height: 3)
                    }
                    .offset(y: 3.5)
                }
                .frame(width: 12, height: 23)
                .rotationEffect(.degrees(-150 * Double(lift)), anchor: .top)
                .position(x: x, y: 67.5)
            }

            // Chest bib and collar
            fluff(rx: 10, ry: 11, tufts: 9, r: 3, color: cream, phase: t + 2)
                .position(x: 50, y: 50)
            Capsule().fill(DesignTokens.accentSecondary)
                .frame(width: 28, height: 5)
                .position(x: 50, y: 40)
            Circle().fill(DesignTokens.accent)
                .frame(width: 6, height: 6)
                .position(x: 50, y: 44.5)

            if let toyAside {
                toyView(toyAside)
                    .position(x: 82, y: 74)
                    .transition(.scale.combined(with: .opacity))
            }

            frontHead(t: t, asleep: asleep, happy: happy, blinking: blinking,
                      earTwitch: earTwitch, glance: glance, deadEyes: deadEyes)
                .rotationEffect(.degrees(tilt), anchor: .center)
                .offset(y: asleep ? 4 : 0)

            if asleep { sleepingZs(t: t) }
        }
        .frame(width: 100, height: 80)
    }

    private func frontHead(t: Double, asleep: Bool, happy: Bool, blinking: Bool,
                           earTwitch: Double, glance: CGFloat, deadEyes: Bool = false) -> some View {
        ZStack {
            fluff(rx: 17, ry: 15.5, tufts: 15, r: 4.2, color: fur, phase: t + 3)
                .position(x: 50, y: 24)

            // Fringe over the eyes
            ForEach(0..<5, id: \.self) { i in
                Circle().fill(fur)
                    .frame(width: 7, height: 7)
                    .position(x: 40 + CGFloat(i) * 5, y: 10 + (i == 2 ? -1.5 : (i % 2 == 1 ? -0.5 : 0.8)))
            }

            // Eyes, looking at you
            ForEach([43.0, 57.0], id: \.self) { x in
                if deadEyes {
                    Capsule().fill(ink).frame(width: 6, height: 1.5).rotationEffect(.degrees(45)).position(x: x, y: 22.5)
                    Capsule().fill(ink).frame(width: 6, height: 1.5).rotationEffect(.degrees(-45)).position(x: x, y: 22.5)
                } else if asleep {
                    eyeArc(x: x, y: 22.5, up: false)
                } else if blinking {
                    Capsule().fill(ink).frame(width: 6, height: 1.6).position(x: x, y: 23)
                } else if happy && carrying == nil {
                    eyeArc(x: x, y: 23.5, up: true)
                } else {
                    Circle().fill(ink).frame(width: 6, height: 6).position(x: x + glance, y: 22.5)
                    Circle().fill(Color.white).frame(width: 2, height: 2).position(x: x + 1.2 + glance, y: 21.3)
                }
            }

            // Muzzle, nose and mouth
            fluff(rx: 8.5, ry: 6.5, tufts: 8, r: 2.6, color: cream, phase: t + 4)
                .position(x: 50, y: 31)
            Ellipse().fill(ink).frame(width: 7, height: 5).position(x: 50, y: 28)
            Ellipse().fill(Color.white.opacity(0.7)).frame(width: 2.2, height: 1.2).position(x: 48.8, y: 27.1)
            Capsule().fill(ink.opacity(0.6)).frame(width: 1.1, height: 3).position(x: 50, y: 31.8)

            if let carrying {
                toyView(carrying).position(x: 50, y: 36)
            } else if happy {
                Capsule().fill(tongue).frame(width: 5, height: 7).position(x: 50, y: 36)
            }

            // Long silky ears
            fluff(rx: 5.5, ry: 11.5, tufts: 9, r: 3, color: shade, phase: t + 5)
                .rotationEffect(.degrees(12 + earTwitch), anchor: .top)
                .position(x: 31, y: 27)
            fluff(rx: 5.5, ry: 11.5, tufts: 9, r: 3, color: shade, phase: t + 6)
                .rotationEffect(.degrees(-12 - earTwitch * 0.5), anchor: .top)
                .position(x: 69, y: 27)
        }
        .frame(width: 100, height: 80)
    }

    /// A closed eye: an arch when he is happy, a soft dip when he sleeps.
    private func eyeArc(x: CGFloat, y: CGFloat, up: Bool) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x - 3, y: y))
            path.addQuadCurve(to: CGPoint(x: x + 3, y: y),
                              control: CGPoint(x: x, y: up ? y - 3.5 : y + 3))
        }
        .stroke(ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }

    // MARK: Running, side on

    private func runPath(_ elapsed: Double) -> RunFrame {
        let out = DogPet.runOut, away = DogPet.outOfSight, back = DogPet.runBack
        if elapsed < out {
            let p = elapsed / out
            return RunFrame(x: travel * CGFloat(p * p), facingRight: true, holding: false)
        } else if elapsed < out + away {
            return RunFrame(x: travel, facingRight: false, holding: true)
        } else {
            let p = min((elapsed - out - away) / back, 1)
            let eased = 1 - (1 - p) * (1 - p)
            return RunFrame(x: travel * CGFloat(1 - eased), facingRight: false, holding: true)
        }
    }

    private func runner(t: Double, carrying: DogPet.Toy?) -> some View {
        let stride = t * 22
        let bob = -CGFloat(abs(sin(stride / 2))) * 3.5
        let legs: [(x: Double, phase: Double)] = [(30, 0), (40, 0.7), (58, .pi), (68, .pi + 0.7)]

        return ZStack {
            plume()
                .rotationEffect(.degrees(-66 + sin(t * 14) * 8), anchor: .bottom)
                .position(x: 18, y: 42)

            ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                ZStack(alignment: .bottom) {
                    Capsule().fill(leg.x < 50 ? shade : fur).frame(width: 10, height: 20)
                    Ellipse().fill(leg.x < 50 ? shade : fur).frame(width: 12, height: 7).offset(y: 2)
                }
                .frame(width: 12, height: 22)
                .rotationEffect(.degrees(sin(stride + leg.phase) * 38), anchor: .top)
                .position(x: leg.x, y: 64)
            }

            fluff(rx: 29, ry: 15, tufts: 16, r: 5, color: fur, phase: t)
                .position(x: 44, y: 50)
            fluff(rx: 11, ry: 9, tufts: 9, r: 3.5, color: fur, phase: t + 1)
                .position(x: 62, y: 55)
            Capsule().fill(DesignTokens.accentSecondary)
                .frame(width: 8, height: 28)
                .rotationEffect(.degrees(-12))
                .position(x: 63, y: 43)

            // Back ear streaming behind
            fluff(rx: 6, ry: 12, tufts: 9, r: 3.2, color: shade, phase: t + 2)
                .rotationEffect(.degrees(55), anchor: .top)
                .position(x: 64, y: 28)

            fluff(rx: 18, ry: 17, tufts: 15, r: 4.2, color: fur, phase: t + 3)
                .position(x: 74, y: 32)
            fluff(rx: 9, ry: 6.5, tufts: 8, r: 2.6, color: cream, phase: t + 4)
                .position(x: 86, y: 38)
            Ellipse().fill(ink).frame(width: 7.5, height: 6).position(x: 93.5, y: 34)
            Circle().fill(ink).frame(width: 5.8, height: 5.8).position(x: 79, y: 28.5)
            Circle().fill(Color.white).frame(width: 1.9, height: 1.9).position(x: 80.2, y: 27.3)
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(fur)
                    .frame(width: 6, height: 6)
                    .position(x: 72 + CGFloat(i) * 5, y: 21 + CGFloat(i == 1 ? -1 : 1))
            }

            if let carrying {
                toyView(carrying).position(x: 90, y: 45)
            } else {
                Capsule().fill(tongue)
                    .frame(width: 5, height: 9)
                    .rotationEffect(.degrees(25 + sin(stride) * 10), anchor: .top)
                    .position(x: 86, y: 47)
            }

            // Front ear flying back
            fluff(rx: 5.5, ry: 11, tufts: 9, r: 3, color: shade, phase: t + 5)
                .rotationEffect(.degrees(48 + sin(stride) * 6), anchor: .top)
                .position(x: 70, y: 26)
        }
        .frame(width: 100, height: 80)
        .offset(y: bob)
    }

    // MARK: Parts

    /// An ellipse ringed with small tufts, so it reads as hair.
    private func fluff(rx: CGFloat, ry: CGFloat, tufts: Int, r: CGFloat,
                       color: Color, phase: Double) -> some View {
        ZStack {
            Ellipse().fill(color).frame(width: rx * 2, height: ry * 2)
            ForEach(0..<tufts, id: \.self) { i in
                let angle = Double(i) / Double(tufts) * .pi * 2
                let ruffle = reduceMotion ? 1.0 : 1 + 0.08 * sin(phase * 2.4 + Double(i) * 1.7)
                Circle().fill(color)
                    .frame(width: r * 2 * CGFloat(ruffle), height: r * 2 * CGFloat(ruffle))
                    .offset(x: CGFloat(cos(angle)) * rx, y: CGFloat(sin(angle)) * ry)
            }
        }
        .frame(width: rx * 2 + r * 2, height: ry * 2 + r * 2)
    }

    /// A feathery tail of overlapping puffs, rooted at the bottom.
    private func plume() -> some View {
        ZStack {
            ForEach(Array([(0.0, 6.5), (-8.0, 8.5), (-16.0, 9.5), (-24.0, 8.0), (-30.0, 5.5)].enumerated()), id: \.offset) { _, puff in
                Circle().fill(puff.0 < -12 ? fur : shade)
                    .frame(width: puff.1 * 2, height: puff.1 * 2)
                    .offset(y: CGFloat(puff.0))
            }
        }
        .frame(width: 24, height: 44, alignment: .bottom)
    }

    @ViewBuilder
    private func toyView(_ toy: DogPet.Toy) -> some View {
        switch toy {
        case .ball:
            ZStack {
                Circle().fill(DesignTokens.accent)
                Capsule().fill(Color.white.opacity(0.85))
                    .frame(width: 14, height: 2)
                    .rotationEffect(.degrees(-30))
            }
            .frame(width: 11, height: 11)
            .clipShape(Circle())
        case .bone:
            ZStack {
                Capsule().fill(boneColor).frame(width: 14, height: 4.5)
                ForEach([-6.5, 6.5], id: \.self) { x in
                    Circle().fill(boneColor).frame(width: 5, height: 5).offset(x: x, y: -2)
                    Circle().fill(boneColor).frame(width: 5, height: 5).offset(x: x, y: 2)
                }
            }
            .frame(width: 20, height: 10)
        case .ring:
            Circle()
                .stroke(DesignTokens.accentSecondary, lineWidth: 3)
                .frame(width: 11, height: 11)
        }
    }

    private func sleepingZs(t: TimeInterval) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let phase = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: 10 + CGFloat(i) * 3, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.secondary.opacity(1 - phase))
                    .position(x: 74 + CGFloat(phase) * 8, y: 12 - CGFloat(phase) * 12)
            }
        }
        .frame(width: 100, height: 80)
    }

    private func hopOffset(at date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSince(hopStart)
        guard !reduceMotion, elapsed >= 0, elapsed < 0.7 else { return 0 }
        return -14 * CGFloat(abs(sin(elapsed / 0.7 * .pi * 2)) * (1 - elapsed / 0.7))
    }
}

// MARK: - In the sidebar

/// The dog in the sidebar's bottom corner. Click him to open your reading panel.
struct DogCompanion: View {
    @ObservedObject private var pet = DogPet.shared
    @ObservedObject private var tracker = ReadingTracker.shared
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("pagewrit.showDog") private var showDog = true
    @AppStorage("pagewrit.dogNudgeDay") private var nudgeDay = ""
    @AppStorage("pagewrit.tip.dogPanel") private var seenPanelTip = false
    @State private var showPanel = false

    var body: some View {
        if showDog {
            HStack(alignment: .bottom, spacing: 4) {
                DogMascot(mood: pet.mood, hopTick: pet.hopTick, lastActive: pet.lastActive,
                          fetchStart: pet.fetchStart, fetchingToy: pet.fetchingToy,
                          carrying: pet.carrying, toyAside: pet.toyAside,
                          travel: DesignTokens.Sidebar.width, size: 70)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        pet.poke()
                        showPanel.toggle()
                        seenPanelTip = true
                    }
                    .help(DogPet.name.isEmpty ? "Your reading dog" : DogPet.name)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { pet.poke(); showPanel.toggle() }
                    .contextMenu {
                        Button("Play Fetch", systemImage: "tennisball") { pet.playFetch() }
                        Button("Reading Panel", systemImage: "book") { showPanel = true }
                    }
                    .popover(isPresented: $showPanel, arrowEdge: .trailing) {
                        ReadingPanel()
                            .environmentObject(library)
                    }

                Group {
                    if !seenPanelTip && pet.line == nil && !pet.isFetching {
                        // Shown until the first click on the dog, then never again.
                        HStack(alignment: .top, spacing: 6) {
                            Text("Click me for your reading goal, a timer and book ideas.")
                                .font(DesignTokens.sansFont(size: 12, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                seenPanelTip = true
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, height: 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss tip")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DesignTokens.accent.opacity(0.14))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(DesignTokens.accent.opacity(0.35), lineWidth: 0.75)
                        )
                        .transition(.opacity)
                    } else if let line = pet.line {
                        Text(line)
                            .font(DesignTokens.sansFont(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                            .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tracker.timerMinutes != nil ? "Timer" : "Reading today")
                                .font(DesignTokens.sansFont(size: 11.5))
                                .foregroundStyle(.tertiary)
                            Text(companionStatus)
                                .font(DesignTokens.sansFont(size: 12.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(tracker.progressToday >= 1 && tracker.timerMinutes == nil
                                                 ? DesignTokens.accentInk : Color.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 12)
                .opacity(pet.isFetching ? 0 : 1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Sidebar.outerMargin + 4)
            .padding(.top, 4)
            .padding(.bottom, 6)
            // He runs off the side edge and comes back.
            .mask(Rectangle().padding(.vertical, -30))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pet.line)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: pet.toyAside)
            .task { eveningNudge() }
        }
    }

    private var companionStatus: String {
        if tracker.timerMinutes != nil { return "\(clockText(tracker.timerRemaining)) left" }
        if tracker.progressToday >= 1 { return "\(readingMinutesText(tracker.minutesToday, short: true)), goal met" }
        return "\(tracker.minutesToday) of \(readingMinutesText(tracker.goalMinutes, short: true))"
    }

    /// Once a day, in the evening, if the goal is still open.
    private func eveningNudge() {
        let today = ReadingTracker.key(Date())
        guard nudgeDay != today,
              !Wellbeing.isQuietNow(),
              Calendar.current.component(.hour, from: Date()) >= 18,
              tracker.progressToday < 1 else { return }
        nudgeDay = today
        pet.cheer("Evening. A few pages before bed?")
    }
}

// MARK: - Reading clock, shared pieces

/// Plain words for minutes: "1 minute", "20 minutes", "1 h 5 min".
func readingMinutesText(_ minutes: Int, short: Bool = false) -> String {
    if minutes >= 60 {
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
    if short { return "\(minutes) min" }
    return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
}

/// "12:05" for a countdown.
func clockText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.up))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// What the clock is doing, in a few words.
func clockStateText(_ state: ReadingTracker.ClockState) -> String {
    switch state {
    case .noBookOpen: return "Counts while a book is open"
    case .counting: return "Counting"
    case .paused: return "Paused"
    case .away: return "Paused while you are away"
    case .inactive: return "Paused while Pagewrit is in the background"
    }
}

/// The countdown timer: pick a length, or watch it run with pause and stop.
struct ReadingTimerControls: View {
    @ObservedObject private var tracker = ReadingTracker.shared
    private static let lengths = [10, 15, 20, 30, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let minutes = tracker.timerMinutes {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(clockText(tracker.timerRemaining))
                        .font(DesignTokens.serifFont(size: 24, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text("left of \(readingMinutesText(minutes, short: true))")
                        .font(DesignTokens.sansFont(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                ProgressView(value: tracker.timerProgress)
                    .progressViewStyle(.linear)
                    .tint(DesignTokens.accentFill)
                HStack(spacing: 8) {
                    Button { tracker.togglePause() } label: {
                        Label(tracker.isPaused ? "Resume" : "Pause",
                              systemImage: tracker.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.pw(.soft, size: .small))
                    .disabled(tracker.state == .noBookOpen)
                    Button { tracker.stopTimer() } label: {
                        Label("Stop timer", systemImage: "stop.fill")
                    }
                    .buttonStyle(.pw(.ghost, size: .small))
                    Spacer(minLength: 0)
                }
                if tracker.state != .counting {
                    Text(tracker.state == .noBookOpen ? "Starts running when you open a book." : clockStateText(tracker.state) + ".")
                        .font(DesignTokens.sansFont(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Set a timer for this sitting")
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Self.lengths, id: \.self) { minutes in
                        Button {
                            tracker.startTimer(minutes: minutes)
                        } label: {
                            Text(readingMinutesText(minutes, short: true))
                                .lineLimit(1)
                                .fixedSize()
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.pw(.neutral, size: .small))
                        .accessibilityLabel("Start a \(minutes) minute timer")
                    }
                }
            }
        }
    }
}

/// The small clock in every reader's toolbar: today's minutes against your
/// goal, or the countdown when a timer runs. Click it for pause and timers.
struct ReadingTimerPill: View {
    let tint: Color
    let accent: Color

    @ObservedObject private var tracker = ReadingTracker.shared
    @State private var showControls = false
    @Environment(\.readerToolbarCompact) private var compact
    @AppStorage("pagewrit.tip.readerClock") private var seenClockTip = false
    @State private var showTip = false
    @State private var hovering = false

    private var ringValue: Double {
        tracker.timerMinutes != nil ? tracker.timerProgress : tracker.progressToday
    }

    private var label: String {
        if tracker.timerMinutes != nil { return clockText(tracker.timerRemaining) }
        if tracker.progressToday >= 1 { return "\(tracker.minutesToday) min" }
        return "\(tracker.minutesToday) of \(tracker.goalMinutes) min"
    }

    private var stopped: Bool { tracker.state != .counting }

    var body: some View {
        Button {
            showControls.toggle()
            seenClockTip = true
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(ringValue, 0.001))
                        .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if stopped {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 5.5, weight: .bold))
                            .foregroundStyle(tint)
                    } else if tracker.timerMinutes == nil && tracker.progressToday >= 1 {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .heavy))
                            .foregroundStyle(accent)
                    }
                }
                .frame(width: 13, height: 13)
                if !compact {
                    Text(label)
                        .font(.system(size: 12, weight: .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(showControls ? accent : tint)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((showControls ? accent : tint).opacity(showControls ? 0.16 : (hovering ? 0.14 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Reading time today. Click for pause and a timer.")
        .accessibilityLabel("Reading timer")
        .accessibilityValue(tracker.timerMinutes != nil
            ? "\(clockText(tracker.timerRemaining)) left"
            : "\(tracker.minutesToday) of \(readingMinutesText(tracker.goalMinutes)) today, \(clockStateText(tracker.state))")
        .popover(isPresented: $showControls, arrowEdge: .bottom) {
            ReadingClockPopover()
        }
        // The first time any book opens, a small note says what this is.
        .background(
            Color.clear
                .popover(isPresented: $showTip, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your reading clock")
                            .font(DesignTokens.sansFont(size: 13, weight: .semibold))
                        Text("It counts today's reading toward your goal and pauses when you step away. Click it to pause or set a timer.")
                            .font(DesignTokens.sansFont(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("Got it") {
                                seenClockTip = true
                                showTip = false
                            }
                            .buttonStyle(.pw(.primary, size: .small))
                        }
                    }
                    .padding(16)
                    .frame(width: 260)
                }
        )
        .task {
            guard !seenClockTip else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !seenClockTip { showTip = true }
        }
        .onChange(of: showTip) { _, open in
            if !open { seenClockTip = true }
        }
    }
}

/// What the reader's clock opens: today, this sitting, pause, and the timer.
private struct ReadingClockPopover: View {
    @ObservedObject private var tracker = ReadingTracker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today")
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(.secondary)
                    Text(readingMinutesText(tracker.minutesToday, short: true))
                        .font(DesignTokens.serifFont(size: 18, weight: .bold))
                        .monospacedDigit()
                    Text(tracker.progressToday >= 1
                         ? "Goal of \(readingMinutesText(tracker.goalMinutes, short: true)) reached"
                         : "of your \(readingMinutesText(tracker.goalMinutes, short: true)) goal")
                        .font(DesignTokens.sansFont(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("This sitting")
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(.secondary)
                    Text(readingMinutesText(Int(tracker.sessionSeconds / 60), short: true))
                        .font(DesignTokens.serifFont(size: 18, weight: .bold))
                        .monospacedDigit()
                }
            }

            HStack(spacing: 8) {
                Image(systemName: tracker.state == .counting ? "circle.fill" : "pause.circle")
                    .font(.system(size: tracker.state == .counting ? 7 : 12))
                    .foregroundStyle(tracker.state == .counting ? DesignTokens.accent : Color.secondary)
                Text(clockStateText(tracker.state))
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if tracker.state != .noBookOpen {
                    Button { tracker.togglePause() } label: {
                        Label(tracker.isPaused ? "Resume" : "Pause",
                              systemImage: tracker.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.pw(.soft, size: .small))
                }
            }

            Divider().opacity(0.5)
            ReadingTimerControls()
            Divider().opacity(0.5)

            Text("The clock pauses by itself after 5 minutes without any typing, clicking or scrolling.")
                .font(DesignTokens.sansFont(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .tint(DesignTokens.accentFill)
    }
}

// MARK: - Reading panel

private struct ReadingPanel: View {
    @ObservedObject private var tracker = ReadingTracker.shared
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("pagewrit.suggestFrom") private var sourceRaw = BookSuggester.Source.anything.rawValue
    @State private var pick: BookSuggester.Pick?
    @State private var looked = false
    @State private var customGoal = false
    @State private var goalText = ""
    @FocusState private var goalFieldFocused: Bool

    private static let goalChoices = [5, 10, 15, 20, 30, 45, 60, 90, 120]

    private var source: BookSuggester.Source {
        BookSuggester.Source(rawValue: sourceRaw) ?? .anything
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            todayRow
            weekBars
            badgesRow
            goalRow
            Divider().opacity(0.5)
            ReadingTimerControls()
            Divider().opacity(0.5)
            suggestion
            Divider().opacity(0.5)
            fetchRow
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .tint(DesignTokens.accentFill)
        .onAppear {
            tracker.refreshDay()
            if !looked {
                looked = true
                refresh(avoiding: nil)
            }
        }
        .onChange(of: sourceRaw) { _, _ in refresh(avoiding: nil) }
    }

    private func refresh(avoiding: String?) {
        pick = BookSuggester.suggest(from: library.books, source: source, avoiding: avoiding)
    }

    // Today: a ring with the minutes, and the plain words beside it.
    private var todayRow: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.09), lineWidth: 7)
                if tracker.progressToday > 0 {
                    Circle()
                        .trim(from: 0, to: tracker.progressToday)
                        .stroke(DesignTokens.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth(duration: 0.4), value: tracker.progressToday)
                }
                VStack(spacing: -2) {
                    Text("\(tracker.minutesToday)")
                        .font(DesignTokens.serifFont(size: 22, weight: .bold))
                        .monospacedDigit()
                    Text("min")
                        .font(DesignTokens.sansFont(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 70, height: 70)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Read today")
            .accessibilityValue("\(tracker.minutesToday) of \(readingMinutesText(tracker.goalMinutes))")

            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(DesignTokens.sansFont(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(streakText)
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: String {
        if tracker.progressToday >= 1 { return "Goal reached for today" }
        let left = max(tracker.goalMinutes - tracker.minutesToday, 1)
        return "\(readingMinutesText(left)) to go today"
    }

    private var streakText: String {
        let streak = tracker.streak
        guard streak > 0 else { return "Reach your goal today to start a streak." }
        let days = "\(streak) \(streak == 1 ? "day" : "days") in a row"
        return tracker.progressToday >= 1 ? days + "." : days + ". Keep it going."
    }

    /// Streak badges: earned ones in colour, the rest waiting.
    private var badgesRow: some View {
        let earned = tracker.earnedBadges
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Streak badges")
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if let next = tracker.nextBadge {
                    Text("\(countText(next.daysToGo, "day")) to \(next.badge.title)")
                        .font(DesignTokens.sansFont(size: 11.5))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Every badge earned")
                        .font(DesignTokens.sansFont(size: 11.5))
                        .foregroundStyle(DesignTokens.accentInk)
                }
            }
            HStack(spacing: 0) {
                ForEach(ReadingTracker.badges) { badge in
                    let date = earned[badge.days]
                    BadgeMedal(days: badge.days, earned: date != nil, size: 36)
                        .frame(maxWidth: .infinity)
                        .help(date.map { "\(badge.title): earned \($0.formatted(date: .abbreviated, time: .omitted))" }
                              ?? "\(badge.title): reach your goal \(badge.days) days in a row")
                        .accessibilityLabel(badge.title)
                        .accessibilityValue(date == nil ? "Not earned yet" : "Earned")
                }
            }
            if tracker.perfectWeeks > 0 {
                Text("\(countText(tracker.perfectWeeks, "perfect week")) so far")
                    .font(DesignTokens.sansFont(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var weekBars: some View {
        let week = tracker.lastWeek
        let goal = Double(tracker.goalMinutes) * 60
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 5) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                            .frame(width: 26, height: 40)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(day.seconds >= goal ? DesignTokens.accent : DesignTokens.accent.opacity(0.45))
                            .frame(width: 26, height: max(day.seconds > 0 ? 4 : 0, 40 * CGFloat(min(day.seconds / goal, 1))))
                    }
                    Text(day.label)
                        .font(DesignTokens.sansFont(size: 11, weight: day.isToday ? .semibold : .regular))
                        .foregroundStyle(day.isToday ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)
                .help(readingMinutesText(Int(day.seconds / 60)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading this week")
        .accessibilityValue("\(week.filter { $0.seconds >= goal }.count) of 7 days reached the goal")
    }

    // Goal: one menu with sensible lengths, or type your own.
    private var goalRow: some View {
        HStack(spacing: 8) {
            Text("Daily goal")
                .font(DesignTokens.sansFont(size: 13))
            Spacer(minLength: 8)
            if customGoal {
                TextField("", text: $goalText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 56)
                    .focused($goalFieldFocused)
                    .onSubmit(commitGoal)
                    .onChange(of: goalFieldFocused) { _, focused in
                        if !focused { commitGoal() }
                    }
                Text("min")
                    .font(DesignTokens.sansFont(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(Self.goalChoices, id: \.self) { minutes in
                        Button {
                            tracker.setGoal(minutes: minutes)
                        } label: {
                            if minutes == tracker.goalMinutes {
                                Label(readingMinutesText(minutes, short: true), systemImage: "checkmark")
                            } else {
                                Text(readingMinutesText(minutes, short: true))
                            }
                        }
                    }
                    Divider()
                    Button("Custom\u{2026}") {
                        goalText = "\(tracker.goalMinutes)"
                        customGoal = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { goalFieldFocused = true }
                    }
                } label: {
                    Text(readingMinutesText(tracker.goalMinutes, short: true))
                        .monospacedDigit()
                }
                .menuStyle(.button)
                .buttonStyle(.pw(.soft, size: .small))
                .fixedSize()
                .accessibilityLabel("Daily goal")
                .accessibilityValue(readingMinutesText(tracker.goalMinutes))
            }
        }
    }

    private func commitGoal() {
        if let minutes = Int(goalText.trimmingCharacters(in: .whitespaces)) {
            tracker.setGoal(minutes: minutes)
        }
        customGoal = false
    }

    private var fetchRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Need a break?")
                    .font(DesignTokens.sansFont(size: 13, weight: .medium))
                Text("Throw the ball and watch \(DogPet.name.isEmpty ? "the dog" : DogPet.name) run for it.")
                    .font(DesignTokens.sansFont(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                DogPet.shared.playFetch()
            } label: {
                Label("Play fetch", systemImage: "tennisball.fill")
            }
            .buttonStyle(.pw(.soft, size: .small))
            .disabled(DogPet.shared.isFetching)
        }
    }

    private var suggestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("What to read next")
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 8)
                Picker("Suggest from", selection: $sourceRaw) {
                    ForEach(BookSuggester.Source.allCases) { source in
                        Text(source.label).tag(source.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            if let pick {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pick.book.title)
                        .font(DesignTokens.serifFont(size: 17, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let author = pick.book.author, !author.isEmpty {
                        Text(author)
                            .font(DesignTokens.sansFont(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(pick.reason)
                        .font(DesignTokens.sansFont(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button {
                        DogPet.shared.cheer("Enjoy it. I will keep time.")
                        openWindow(id: "reader", value: pick.book.contentHash)
                    } label: {
                        Label("Read it", systemImage: "book")
                    }
                    .buttonStyle(.pw(.primary, size: .small))

                    Button {
                        refresh(avoiding: pick.book.contentHash)
                    } label: {
                        Label("Another idea", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.pw(.soft, size: .small))
                }
            } else {
                Text(source.emptyText)
                    .font(DesignTokens.sansFont(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Celebration

/// Sits over every Pagewrit window, readers included. When you reach your goal
/// or finish a book, a card rises from the bottom: confetti bursts, the ring
/// fills, and the dog dashes off the edge and comes back with a toy for you.
struct CelebrationOverlay: View {
    @ObservedObject private var tracker = ReadingTracker.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            if let moment = tracker.celebration {
                CelebrationCard(moment: moment) { tracker.dismissCelebration() }
                    .id(moment.id)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: tracker.celebration?.id)
        // Never in the way of the page underneath: no selecting, scrolling
        // or clicking is taken unless a card is actually on screen.
        .allowsHitTesting(tracker.celebration != nil)
    }
}

private struct CelebrationCard: View {
    let moment: ReadingTracker.Celebration
    let onClose: () -> Void

    @Environment(\.pagewritReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("pagewrit.showDog") private var showDog = true
    @AppStorage("pagewrit.celebrationSound") private var playSound = true
    @State private var start = Date()
    @State private var back = false
    @State private var hop = 0
    @State private var ring: CGFloat = 0

    /// Breaks and wind down are calm: no confetti, no sound, no running.
    private var isGentle: Bool {
        switch moment.kind {
        case .rest, .windDown: return true
        default: return false
        }
    }

    private var toyName: String {
        switch moment.toy {
        case .ball: return "ball"
        case .bone: return "bone"
        case .ring: return "ring"
        }
    }

    private var dogName: String {
        DogPet.name.isEmpty ? "Your dog" : DogPet.name
    }

    private var title: String {
        switch moment.kind {
        case .goal(let minutes, _): return "\(minutes) \(minutes == 1 ? "minute" : "minutes"). Goal reached!"
        case .finished: return "You finished it!"
        case .timer(let minutes): return "\(readingMinutesText(minutes)), done!"
        case .streak(_, let title): return "\(title) streak!"
        case .rest: return "Time for a short break"
        case .windDown: return "It is getting late"
        }
    }

    private var subtitle: String {
        switch moment.kind {
        case .goal(_, let streak):
            let fetched = showDog ? "\(dogName) ran off to fetch you a \(toyName)." : "That is a good day of reading."
            return streak > 1 ? "\(streak) days in a row. \(fetched)" : fetched
        case .finished(let title):
            return showDog ? "\(title). \(dogName) brought you a \(toyName) to celebrate." : title
        case .streak(let days, let title):
            let weeks = ReadingTracker.shared.perfectWeeks
            let extra = weeks > 1 ? " That makes \(weeks) perfect weeks." : ""
            return "You reached your goal \(days) days in a row and earned the \(title) badge.\(extra)"
        case .timer:
            return showDog ? "Your timer is up. \(dogName) fetched you a \(toyName). Keep going or take a break." : "Your timer is up. Keep going or take a break."
        case .rest(let minutes):
            return "You have read for \(readingMinutesText(minutes)). Look at something far away for 20 seconds, stretch, and have some water."
        case .windDown:
            return "Your quiet hours have started. Maybe finish this page, then rest your eyes."
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: ring)
                    .stroke(DesignTokens.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if case .streak(let days, _) = moment.kind {
                    // The badge itself, landing with a little bounce.
                    BadgeMedal(days: days, earned: true, size: 84)
                        .scaleEffect(ring > 0.5 ? 1 : 0.4)
                        .rotationEffect(.degrees(ring > 0.5 ? 0 : -25))
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.55).delay(0.2), value: ring)
                } else if showDog {
                    DogMascot(mood: back ? .happy : .calm, hopTick: hop, lastActive: Date(),
                              fetchStart: reduceMotion || isGentle ? nil : start, fetchingToy: moment.toy,
                              carrying: back && !isGentle ? moment.toy : nil, travel: 520, size: 86)
                        .offset(x: 2, y: 8)
                } else {
                    Image(systemName: "star.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(DesignTokens.accent)
                }
            }
            .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(DesignTokens.serifFont(size: 22, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(DesignTokens.sansFont(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.pw(.ghost, size: .small))
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(18)
        .frame(maxWidth: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        // He runs off this edge and comes back.
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 26, y: 10)
        .background(alignment: .center) {
            if !isGentle { DogConfettiBurst(start: start) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(subtitle)")
        .task {
            start = Date()
            PWAccessibility.announce("\(title) \(subtitle)")
            if !isGentle { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            if playSound, !isGentle, !Wellbeing.isQuietNow(), let sound = NSSound(named: NSSound.Name("Glass")) {
                sound.volume = 0.35
                sound.play()
            }
            withAnimation(.easeOut(duration: 1.3)) { ring = 1 }
            let wait = reduceMotion || isGentle ? 0.3 : DogPet.fetchDuration
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            back = true
            hop += 1
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}

/// A short burst of confetti, paw prints and stars that falls away.
private struct DogConfettiBurst: View {
    let start: Date

    @Environment(\.pagewritReduceMotion) private var reduceMotion
    @State private var done = false

    private struct Bit {
        let angle: Double
        let speed: Double
        let spin: Double
        let size: CGFloat
        let kind: Int
        let color: Int
        let delay: Double
    }

    @State private var bits: [Bit] = (0..<46).map { _ in
        Bit(angle: Double.random(in: (-Double.pi * 0.95)...(-Double.pi * 0.05)),
            speed: Double.random(in: 170...360),
            spin: Double.random(in: -420...420),
            size: CGFloat.random(in: 6...12),
            kind: Int.random(in: 0..<4),
            color: Int.random(in: 0..<3),
            delay: Double.random(in: 0...0.25))
    }

    private let colors: [Color] = [DesignTokens.accent, DesignTokens.accentSecondary,
                                   Color(red: 0.98, green: 0.78, blue: 0.30)]

    var body: some View {
        if !reduceMotion && !done {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                ZStack {
                    ForEach(bits.indices, id: \.self) { i in
                        let bit = bits[i]
                        let t = max(elapsed - bit.delay, 0)
                        let x = cos(bit.angle) * bit.speed * t
                        let y = sin(bit.angle) * bit.speed * t + 260 * t * t
                        piece(bit)
                            .rotationEffect(.degrees(bit.spin * t))
                            .offset(x: x, y: y)
                            .opacity(t > 0 ? max(0, 1 - t / 2.2) : 0)
                    }
                }
            }
            .frame(width: 10, height: 10)
            .allowsHitTesting(false)
            .task {
                try? await Task.sleep(nanoseconds: 2_700_000_000)
                done = true
            }
        }
    }

    @ViewBuilder
    private func piece(_ bit: Bit) -> some View {
        let color = colors[bit.color]
        switch bit.kind {
        case 0:
            Circle().fill(color).frame(width: bit.size, height: bit.size)
        case 1:
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: bit.size, height: bit.size * 0.45)
        case 2:
            Image(systemName: "pawprint.fill").font(.system(size: bit.size + 2)).foregroundStyle(color)
        default:
            Image(systemName: "star.fill").font(.system(size: bit.size)).foregroundStyle(color)
        }
    }
}


// MARK: - Badge

/// A streak badge: a rosette with the number of days on it. Teal for the
/// first weeks, coral from a month, gold from 100 days. Not yet earned, it is
/// a faint outline of itself.
struct BadgeMedal: View {
    let days: Int
    let earned: Bool
    var size: CGFloat = 64

    private var fill: Color {
        guard earned else { return Color.primary.opacity(0.08) }
        if days >= 100 { return Color(red: 0.83, green: 0.64, blue: 0.24) }
        if days >= 30 { return DesignTokens.accentSecondary }
        return DesignTokens.accentFill
    }

    var body: some View {
        ZStack {
            // The scalloped edge of a rosette
            ForEach(0..<12, id: \.self) { i in
                Circle()
                    .fill(fill)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .offset(y: -size * 0.355)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            Circle().fill(fill).frame(width: size * 0.8, height: size * 0.8)
            Circle()
                .strokeBorder(Color.white.opacity(earned ? 0.5 : 0.12), lineWidth: max(size * 0.025, 0.75))
                .frame(width: size * 0.62, height: size * 0.62)
            VStack(spacing: -size * 0.02) {
                Text("\(days)")
                    .font(.system(size: size * 0.25, weight: .bold, design: .serif))
                    .minimumScaleFactor(0.6)
                if size >= 30 {
                    Text(days == 1 ? "day" : "days")
                        .font(.system(size: max(size * 0.1, 6), weight: .semibold))
                }
            }
            .foregroundStyle(earned ? Color.white : Color.secondary)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(earned ? 0.18 : 0), radius: size * 0.06, y: size * 0.03)
    }
}
