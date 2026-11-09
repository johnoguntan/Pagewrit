import SwiftUI
import AppKit

/// Renders slides off the main thread and remembers the results.
final class SlideImageCache {
    static let shared = SlideImageCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() { cache.countLimit = 300 }

    private func key(_ deck: SlideDeck, _ index: Int, _ width: Int) -> NSString {
        "\(ObjectIdentifier(deck).hashValue)-\(index)-\(width)" as NSString
    }

    func cached(deck: SlideDeck, index: Int, pixelWidth: CGFloat) -> NSImage? {
        cache.object(forKey: key(deck, index, Int(pixelWidth)))
    }

    func image(deck: SlideDeck, index: Int, pixelWidth: CGFloat) async -> NSImage {
        let w = Int(pixelWidth)
        let k = key(deck, index, w)
        if let hit = cache.object(forKey: k) { return hit }
        let img = await Task.detached(priority: .userInitiated) {
            SlideRenderer.image(deck: deck, index: index, pixelWidth: CGFloat(w))
        }.value
        cache.setObject(img, forKey: k)
        return img
    }
}

/// One slide, drawn to fit its container.
struct SlideImageView: View {
    let deck: SlideDeck
    let index: Int
    var pixelWidth: CGFloat = 1600

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(deck.aspect, contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color(nsColor: deck.defaultBackground))
                    .aspectRatio(deck.aspect, contentMode: .fit)
            }
        }
        .task(id: "\(ObjectIdentifier(deck).hashValue)-\(index)-\(Int(pixelWidth))") {
            if let hit = SlideImageCache.shared.cached(deck: deck, index: index, pixelWidth: pixelWidth) {
                image = hit
                return
            }
            image = await SlideImageCache.shared.image(deck: deck, index: index, pixelWidth: pixelWidth)
        }
    }
}

func formatElapsed(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}
