import SwiftUI
import AppKit

/// Five dogs instead of five stars. A reusable control so the same
/// little character can show up wherever the app asks "how was it?".
struct DogRating: View {
    let rating: Int
    var size: CGFloat = 18
    var interactive = true
    let onChange: (Int) -> Void

    @State private var hovered: Int?
    @State private var bounced: Int?
    @State private var bursts = [Int](repeating: 0, count: 6)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { index in
                // Pointing at the last filled dog previews taking it away.
                let shown = (hovered != nil && hovered == rating) ? rating - 1 : (hovered ?? rating)
                let filled = index <= shown
                Image(systemName: filled ? "dog.fill" : "dog")
                    .font(.system(size: size, weight: .regular))
                    .foregroundStyle(filled ? DesignTokens.accentSecondary : Color.secondary.opacity(0.55))
                    .scaleEffect(bounced == index ? 1.3 : (hovered == index ? 1.12 : 1))
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: bounced)
                    .animation(.easeOut(duration: 0.12), value: hovered)
                    .overlay { ConfettiBurst(trigger: bursts[index], count: 10 + index * 4, spread: 38 + CGFloat(index) * 8) }
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard interactive else { return }
                        hovered = inside ? index : (hovered == index ? nil : hovered)
                    }
                    .onTapGesture {
                        guard interactive else { return }
                        // Tap a dog to rate that many. Tap the last filled dog
                        // again to take just that one away.
                        let removing = rating == index
                        onChange(removing ? index - 1 : index)
                        if !removing {
                            bursts[index] += 1
                            DogPet.shared.cheer(index >= 4 ? "\(index) dogs! I am honoured." : nil)
                        }
                        bounced = index
                        Task {
                            try? await Task.sleep(nanoseconds: 220_000_000)
                            bounced = nil
                        }
                    }
                    .help(interactive ? (rating == index ? "Remove this dog" : "\(index) of 5") : "")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) of 5")
        .accessibilityAdjustableAction { direction in
            guard interactive else { return }
            switch direction {
            case .increment: onChange(min(rating + 1, 5))
            case .decrement: onChange(max(rating - 1, 0))
            @unknown default: break
            }
        }
        // Keyboard: focus the rating, then arrows or 0 to 5 set it.
        .focusable(interactive)
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { guard interactive else { return .ignored }; onChange(min(rating + 1, 5)); return .handled }
        .onKeyPress(.leftArrow) { guard interactive else { return .ignored }; onChange(max(rating - 1, 0)); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "012345")) { press in
            guard interactive, let digit = Int(String(press.characters)) else { return .ignored }
            onChange(digit)
            return .handled
        }
    }
}


/// A small shower of confetti from a point. Bump `trigger` to fire it.
/// Used when you favorite a book or give it dogs.
struct ConfettiBurst: View {
    let trigger: Int
    var count = 24
    var spread: CGFloat = 70

    private struct Piece: Identifiable {
        let id: Int
        let angle: Double
        let distance: CGFloat
        let spin: Double
        let size: CGFloat
        let color: Color
        let round: Bool
    }

    @State private var pieces: [Piece] = []
    @State private var progress: CGFloat = 0
    @Environment(\.pagewritReduceMotion) private var reduceMotion

    private static let palette: [Color] = [
        DesignTokens.accentSecondary,
        DesignTokens.accent,
        Color(red: 1.0, green: 0.80, blue: 0.25),
        Color(red: 1.0, green: 0.35, blue: 0.50),
        Color(red: 0.30, green: 0.80, blue: 0.55)
    ]

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                Group {
                    if piece.round {
                        Circle().fill(piece.color)
                    } else {
                        RoundedRectangle(cornerRadius: 1).fill(piece.color)
                    }
                }
                .frame(width: piece.size, height: piece.round ? piece.size : piece.size * 0.5)
                .rotationEffect(.degrees(piece.spin * Double(progress)))
                .offset(
                    x: CGFloat(cos(piece.angle)) * piece.distance * progress,
                    y: CGFloat(sin(piece.angle)) * piece.distance * progress + 34 * progress * progress
                )
                .opacity(progress == 0 ? 0 : Double(max(0, 1 - progress * progress * progress)))
            }
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, new in
            guard new > 0, !reduceMotion else { return }
            pieces = (0..<count).map { i in
                Piece(
                    id: i,
                    angle: Double.random(in: -Double.pi * 1.1 ... Double.pi * 0.1),
                    distance: CGFloat.random(in: spread * 0.45 ... spread),
                    spin: Double.random(in: -420 ... 420),
                    size: CGFloat.random(in: 4...7),
                    color: Self.palette[i % Self.palette.count],
                    round: i % 3 == 0
                )
            }
            progress = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                withAnimation(.easeOut(duration: 0.95)) { progress = 1 }
            }
        }
    }
}


// MARK: - Window level celebration

/// Confetti that belongs to the window, not to one button. A tile can be
/// rebuilt the instant a book is favourited (the list refreshes), which used to
/// cut the burst short. This layer lives above the library and fires where the
/// pointer is.
final class CelebrationCenter: ObservableObject {
    static let shared = CelebrationCenter()

    @Published private(set) var count = 0
    /// Window coordinates, top left origin.
    @Published private(set) var point: CGPoint = .zero

    func celebrateAtPointer() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView else { return }
        let location = window.mouseLocationOutsideOfEventStream
        point = CGPoint(x: location.x, y: content.bounds.height - location.y)
        count += 1
    }
}

struct CelebrationLayer: View {
    @ObservedObject private var center = CelebrationCenter.shared

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ConfettiBurst(trigger: center.count, count: 34, spread: 110)
                .position(x: center.point.x - origin.x, y: center.point.y - origin.y)
        }
        .allowsHitTesting(false)
    }
}
