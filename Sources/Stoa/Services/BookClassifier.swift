import Foundation
import PDFKit

/// Scores PDFs to separate real books from non-book documents (resumes,
/// invoices, pitch decks, etc.). EPUB and CBZ skip classification entirely.
///
/// All signals are cheap, on-device, no ML needed. The combined score is
/// a simple weighted average (0...1):
///   - >= 0.7 -> auto-added as a book
///   - 0.3...0.7 -> "Needs Review" tray
///   - < 0.3 -> silently skipped
enum BookClassifier {

    // MARK: - Public

    struct Result {
        let score: Double
        let decision: BookClassification.Decision
    }

    /// Classify a PDF file. Returns nil for non-PDF formats (they should
    /// bypass classification entirely).
    static func classify(_ file: DiscoveredFile) -> Result? {
        guard file.format == .pdf else { return nil }

        let score = computeScore(for: file)

        let decision: BookClassification.Decision
        if score >= 0.7 {
            decision = .autoAdded
        } else if score >= 0.3 {
            decision = .needsReview
        } else {
            decision = .autoSkipped
        }

        return Result(score: score, decision: decision)
    }

    // MARK: - Scoring

    private static func computeScore(for file: DiscoveredFile) -> Double {
        guard let document = PDFDocument(url: file.url) else { return 0 }

        var scores: [(value: Double, weight: Double)] = []

        // 1. Page count (strong)
        let pageCountScore = pageCountSignal(pageCount: document.pageCount)
        scores.append((pageCountScore, 0.30))

        // 2. Filename keywords (strong)
        let filenameScore = filenameSignal(fileName: file.url.lastPathComponent)
        scores.append((filenameScore, 0.25))

        // 3. Text density per page (medium)
        let densityScore = textDensitySignal(document: document)
        scores.append((densityScore, 0.20))

        // 4. File size vs page count ratio (medium)
        let sizeRatioScore = sizeRatioSignal(fileSize: file.sizeBytes, pageCount: document.pageCount)
        scores.append((sizeRatioScore, 0.15))

        // 5. Has outline / table of contents (weak)
        let outlineScore = outlineSignal(document: document)
        scores.append((outlineScore, 0.10))

        let totalWeight = scores.reduce(0.0) { $0 + $1.weight }
        let weighted = scores.reduce(0.0) { $0 + $1.value * $1.weight }
        return min(max(weighted / totalWeight, 0), 1)
    }

    // MARK: - Signal 1: Page count

    /// Books are almost always 20+ pages. Resumes, invoices, pitch decks
    /// are typically 1-10 pages.
    private static func pageCountSignal(pageCount: Int) -> Double {
        switch pageCount {
        case 0...1:    return 0.0
        case 2...5:    return 0.1
        case 6...10:   return 0.3
        case 11...19:  return 0.6
        case 20...49:  return 0.8
        case 50...99:  return 0.95
        default:       return 1.0  // 100+ pages = almost certainly a book
        }
    }

    // MARK: - Signal 2: Filename keywords

    /// Non-book PDFs tend to have obvious keywords in their filenames.
    private static let nonBookKeywords: [String] = [
        "resume", "cv", "cover letter",
        "invoice", "receipt",
        "pitch", "proposal", "deck",
        "contract", "agreement",
        "report", "summary",
        "memo", "memorandum",
        "budget", "financial",
        "statement", "statement of work",
        "sow", "nda", "non-disclosure",
        "application", "form",
        "template", "sample",
        "slide", "slides", "presentation",
        "poster", "flyer", "brochure",
        "screenshot", "screen shot",
        "untitled", "scan",
    ]

    private static func filenameSignal(fileName: String) -> Double {
        let lower = fileName.lowercased()
        let matches = nonBookKeywords.filter { lower.contains($0) }

        if matches.isEmpty {
            return 0.9  // No non-book keywords = likely a book
        } else if matches.count == 1 {
            return 0.3
        } else {
            return 0.1  // Multiple matches = very unlikely to be a book
        }
    }

    // MARK: - Signal 3: Text density per page

    /// Sample the first 3 pages. Resumes/CVs have short lines with lots
    /// of whitespace; book pages are dense paragraphs.
    private static func textDensitySignal(document: PDFDocument) -> Double {
        let pagesToSample = min(3, document.pageCount)
        guard pagesToSample > 0 else { return 0 }

        var totalChars = 0
        var totalPages = 0

        for i in 0..<pagesToSample {
            guard let page = document.page(at: i) else { continue }
            if let text = page.string {
                totalChars += text.count
                totalPages += 1
            }
        }

        guard totalPages > 0 else { return 0.5 }  // No text = can't judge, neutral

        let avgCharsPerPage = Double(totalChars) / Double(totalPages)

        // Books: typically 2000-4000 chars per page
        // Resumes/CVs: typically 200-800 chars per page
        // Invoices/pitch decks: 500-1500 chars per page
        switch avgCharsPerPage {
        case 0..<200:    return 0.1   // Very sparse — likely graphic-heavy
        case 200..<600:  return 0.3   // Sparse — likely resume/CV/short doc
        case 600..<1200: return 0.5   // Medium — could be either
        case 1200..<2000: return 0.7  // Dense — likely a book or report
        case 2000..<5000: return 0.9  // Very dense — almost certainly a book
        default:         return 0.95  // Extremely dense — definitely a book
        }
    }

    // MARK: - Signal 4: File size vs page count ratio

    /// Books have consistent density. Single-page graphic-heavy docs
    /// (posters, one-pagers) skew low text/high image relative to pages.
    private static func sizeRatioSignal(fileSize: Int64, pageCount: Int) -> Double {
        guard pageCount > 0 else { return 0 }

        let bytesPerPage = Double(fileSize) / Double(pageCount)

        // Books: ~50KB-2MB per page (text + occasional images)
        // Posters/one-pagers: can be 500KB+ for a single page
        // Resumes: ~10-50KB per page (mostly text, few images)
        switch bytesPerPage {
        case 0..<5_000:        return 0.2   // Suspiciously small per page
        case 5_000..<30_000:   return 0.5   // Sparse — resume-like
        case 30_000..<200_000: return 0.8   // Typical book density
        case 200_000..<1_000_000: return 0.7  // Image-heavy but could be a graphic novel
        default:               return 0.5   // Very large per page — poster/art book
        }
    }

    // MARK: - Signal 5: Outline / table of contents

    /// Books and long reports often have an outline root. Resumes and
    /// short docs almost never do.
    private static func outlineSignal(document: PDFDocument) -> Double {
        if document.outlineRoot != nil {
            return 0.8  // Has outline = likely structured book
        } else {
            return 0.4  // No outline = neutral/slightly against
        }
    }
}
