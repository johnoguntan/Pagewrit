import SwiftUI

/// A short welcome shown before the very first scan. Pagewrit is
/// sandboxed, so the next step is a folder picker. This screen explains
/// that first, plus a few things worth knowing.
/// Also reachable later from Help ▸ Welcome to Pagewrit.
struct OnboardingView: View {
    let onGetStarted: () -> Void

    @AppStorage("pagewrit.showDog") private var showDog = true
    @AppStorage("pagewrit.hasMetDog") private var hasMetDog = false
    @State private var meetingDog = false

    var body: some View {
        Group {
            if meetingDog {
                DogIntroView(onBack: { withAnimation(.smooth(duration: 0.3)) { meetingDog = false } }) {
                    hasMetDog = true
                    onGetStarted()
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                welcome
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: meetingDog)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Image("PagewritMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .padding(.bottom, 16)

            Text("Welcome to Pagewrit")
                .font(DesignTokens.serifFont(size: 24, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 6)

            Text("Books, documents, slide decks and comics in one place.")
                .font(DesignTokens.sansFont(size: 14))
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 18) {
                row("folder",
                    "Finds your books",
                    "Next, allow Documents, Desktop and Downloads. Just click Allow Access each time.")
                row("lock",
                    "Your files stay put",
                    "Pagewrit only reads the folders you pick. Nothing is moved or copied.")
                row("magnifyingglass",
                    "Search inside a book",
                    "Press \u{2318}F, then \u{2191} \u{2193} to move between results.")
                row("gearshape",
                    "Make it yours",
                    "Press \u{2318}, for appearance, fonts and folders.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)

            Button {
                if showDog { meetingDog = true } else { onGetStarted() }
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(InkButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 32)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(DesignTokens.background.ignoresSafeArea())
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DesignTokens.accent)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignTokens.sansFont(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(DesignTokens.sansFont(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Meet the dog

/// Introduces the library dog in two short steps: name him, then pick a daily
/// reading goal. Part of the welcome for new people, and shown once on its own
/// to people who were here before him.
struct DogIntroView: View {
    var onBack: (() -> Void)? = nil
    let onDone: () -> Void

    @AppStorage(DogPet.nameKey) private var dogName = ""
    @AppStorage(DogPet.pronounKey) private var pronounRaw = DogPet.Pronoun.they.rawValue
    private var pronoun: DogPet.Pronoun { DogPet.Pronoun(rawValue: pronounRaw) ?? .they }
    @ObservedObject private var tracker = ReadingTracker.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var step = 0
    @State private var draft = ""
    @State private var hop = 0
    @State private var suggestions = DogIntroView.pickNames()
    @FocusState private var nameFocused: Bool

    private static let names = [
        "Biscuit", "Mochi", "Pages", "Inkwell", "Chapter", "Cloud", "Snowy",
        "Waffles", "Dewey", "Pudding", "Comet", "Noodle", "Maple", "Pip"
    ]
    private static let goals = [10, 20, 30, 45, 60]

    private static func pickNames(excluding current: [String] = []) -> [String] {
        let fresh = names.filter { !current.contains($0) }.shuffled()
        return Array((fresh.count >= 3 ? fresh : names.shuffled()).prefix(3))
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The name if there is one, otherwise She, He or They.
    private var nameOrSubject: String { trimmed.isEmpty ? pronoun.Subject : trimmed }
    /// Verbs agree with "they" only when no name stands in front of them.
    private func agree(_ singular: String, _ plural: String) -> String {
        trimmed.isEmpty ? pronoun.verb(singular, plural) : singular
    }

    private var fieldFill: Color { Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04) }
    private var hairline: Color { Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.09) }

    var body: some View {
        VStack(spacing: 0) {
            hero

            ZStack(alignment: .topLeading) {
                if step == 0 {
                    nameStep
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    goalStep
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .trailing).combined(with: .opacity)))
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .clipped()

            footer
                .padding(.horizontal, 36)
                .padding(.top, 30)
                .padding(.bottom, 26)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(DesignTokens.background.ignoresSafeArea())
        .animation(.smooth(duration: 0.32), value: step)
        .onAppear {
            draft = dogName
            nameFocused = true
        }
        .onChange(of: draft) { old, new in
            if new.count > 24 { draft = String(new.prefix(24)) }
            let wasEmpty = old.trimmingCharacters(in: .whitespaces).isEmpty
            if wasEmpty && !new.trimmingCharacters(in: .whitespaces).isEmpty { hop += 1 }
        }
    }

    // MARK: Hero

    private var bubbleText: String {
        if step == 1 { return "\(readingMinutesText(tracker.goalMinutes)) a day? I will keep time." }
        return trimmed.isEmpty ? "Hi! What is my name?" : "Woof! I am \(trimmed)."
    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.accent.opacity(colorScheme == .dark ? 0.14 : 0.10))

            // His spot on the floor
            Ellipse()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.10))
                .frame(width: 120, height: 14)
                .padding(.bottom, 20)

            DogMascot(mood: trimmed.isEmpty && step == 0 ? .calm : .happy,
                      hopTick: hop, lastActive: Date(), size: 170)
                .padding(.bottom, 26)
                .accessibilityHidden(true)

            bubble
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 292)
                .padding(.top, 38)
        }
        .frame(height: 230)
        .clipped()
    }

    private var bubble: some View {
        Text(bubbleText)
            .font(DesignTokens.sansFont(size: 13.5, weight: .medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 150, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DesignTokens.background)
            )
            .overlay(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(DesignTokens.background)
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees(45))
                    .offset(x: 10, y: 4)
            }
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
            .id(bubbleText)
            .transition(.scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: bubbleText)
            .accessibilityHidden(true)
    }

    // MARK: Step 1, his name

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Name your reading buddy")
                .font(DesignTokens.serifFont(size: 26, weight: .bold))
                .tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            Text("\(pronoun.Subject) \(pronoun.verb("keeps", "keep")) time while you read and \(pronoun.verb("fetches", "fetch")) a toy when you reach your goal.")
                .font(DesignTokens.sansFont(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            TextField("", text: $draft, prompt: Text("Type a name"))
                .textFieldStyle(.plain)
                .font(DesignTokens.serifFont(size: 20, weight: .semibold))
                .focused($nameFocused)
                .focusEffectDisabled()
                .onSubmit(next)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fieldFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(nameFocused ? DesignTokens.accent.opacity(0.75) : hairline,
                                      lineWidth: nameFocused ? 1.5 : 0.5)
                )
                .animation(.easeOut(duration: 0.15), value: nameFocused)
                .accessibilityLabel("Dog's name")
                .padding(.bottom, 12)

            HStack(spacing: 6) {
                Text("Ideas")
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 2)
                ForEach(suggestions, id: \.self) { name in
                    let chosen = trimmed == name
                    Button {
                        draft = name
                        hop += 1
                        Haptics.tick()
                    } label: {
                        Text(name)
                            .font(DesignTokens.sansFont(size: 12.5, weight: .medium))
                            .foregroundStyle(chosen ? DesignTokens.accentInk : Color.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(chosen ? DesignTokens.accent.opacity(0.16) : fieldFill))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    suggestions = Self.pickNames(excluding: suggestions)
                    Haptics.tick()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("More ideas")
                .accessibilityLabel("More name ideas")
                Spacer(minLength: 0)
            }
            .padding(.bottom, 16)

            HStack(spacing: 10) {
                Text("Call your dog")
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                PWSegmented(selection: $pronounRaw,
                            options: DogPet.Pronoun.allCases.map { ($0.label, $0.rawValue) })
                    .accessibilityLabel("Pronoun for your dog")
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Step 2, the goal

    private var goalStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How long will you read each day?")
                .font(DesignTokens.serifFont(size: 26, weight: .bold))
                .tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            Text("\(nameOrSubject) \(agree("keeps", "keep")) time while a book is open. Reach your goal and \(pronoun.subject) \(pronoun.verb("runs", "run")) off to fetch you a toy.")
                .font(DesignTokens.sansFont(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            HStack(spacing: 8) {
                ForEach(Self.goals, id: \.self) { minutes in
                    goalTile(minutes)
                }
            }

            Text("Change it any time by clicking \(trimmed.isEmpty ? "the dog" : trimmed) in the sidebar.")
                .font(DesignTokens.sansFont(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func goalTile(_ minutes: Int) -> some View {
        let selected = tracker.goalMinutes == minutes
        return Button {
            tracker.setGoal(minutes: minutes)
            hop += 1
            Haptics.tick()
        } label: {
            VStack(spacing: 1) {
                Text("\(minutes)")
                    .font(DesignTokens.serifFont(size: 24, weight: .bold))
                    .monospacedDigit()
                Text("min")
                    .font(DesignTokens.sansFont(size: 11.5, weight: .medium))
                    .opacity(selected ? 0.85 : 0.6)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? DesignTokens.accentFill : fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.clear : hairline, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .accessibilityLabel("\(readingMinutesText(minutes)) a day")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? DesignTokens.accent : Color.primary.opacity(0.15))
                        .frame(width: index == step ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
            .accessibilityHidden(true)

            Spacer()

            if step == 0 {
                if let onBack {
                    Button("Back", action: onBack)
                        .buttonStyle(.pw(.ghost, size: .large))
                }
                Button(action: next) {
                    Text(trimmed.isEmpty ? "Skip for now" : "Next")
                        .frame(minWidth: 76)
                }
                .buttonStyle(.pw(trimmed.isEmpty ? .neutral : .primary, size: .large))
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Back") { step = 0 }
                    .buttonStyle(.pw(.ghost, size: .large))
                Button(action: finish) {
                    Text("Start reading")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.pw(.primary, size: .large))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func next() {
        nameFocused = false
        step = 1
    }

    private func finish() {
        dogName = trimmed
        DogPet.shared.cheer(trimmed.isEmpty
            ? "Hello! Click me any time to see your reading."
            : "Hi, I am \(trimmed)! Click me any time to see your reading.")
        onDone()
    }
}

#Preview {
    OnboardingView(onGetStarted: {})
}
