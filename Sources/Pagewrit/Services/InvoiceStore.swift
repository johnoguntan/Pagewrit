import Foundation
import PDFKit
import UserNotifications

// MARK: - Model

/// One invoice Pagewrit found in (or was told about in) the library. Keyed by
/// the book's content hash, so it follows the file wherever it lives.
struct Invoice: Codable, Identifiable, Hashable {
    var id: String
    var vendor: String
    var number: String?
    var amount: Double?
    var currency: String
    var issued: Date?
    var due: Date?
    var paid: Bool = false
    var paidOn: Date?
    var title: String
    var detectedAt: Date = Date()
}

enum InvoiceStatus {
    case overdue, dueSoon, upcoming, noDate, paid
}

extension Invoice {
    /// Whole days from today to the due date. Negative means overdue.
    func daysUntilDue(now: Date = Date()) -> Int? {
        guard let due else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due)).day
    }

    func status(now: Date = Date()) -> InvoiceStatus {
        if paid { return .paid }
        guard let days = daysUntilDue(now: now) else { return .noDate }
        if days < 0 { return .overdue }
        if days <= 7 { return .dueSoon }
        return .upcoming
    }

    /// Plain words for where this invoice stands.
    func dueLabel(now: Date = Date()) -> String {
        if paid {
            if let paidOn { return "Paid \(Self.shortDate.string(from: paidOn))" }
            return "Paid"
        }
        guard let days = daysUntilDue(now: now), let due else { return "No due date" }
        switch days {
        case ..<0: return days == -1 ? "Overdue by 1 day" : "Overdue by \(-days) days"
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        case 2...30: return "Due in \(days) days"
        default: return "Due \(Self.shortDate.string(from: due))"
        }
    }

    var amountText: String? {
        guard let amount else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
        if currency.isEmpty { return number }
        return currency.count > 1 ? "\(currency) \(number)" : "\(currency)\(number)"
    }

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

// MARK: - Store

/// Finds invoices among the library's documents, keeps their details, and
/// reminds you before they fall due. Everything stays on this Mac.
@MainActor
final class InvoiceStore: ObservableObject {
    static let shared = InvoiceStore()

    @Published private(set) var invoices: [Invoice] = []
    private var examined: Set<String> = []
    private var dismissed: Set<String> = []

    private let invoicesKey = "pagewrit.invoices"
    private let examinedKey = "pagewrit.invoices.examined"
    private let dismissedKey = "pagewrit.invoices.dismissed"
    private let askedKey = "pagewrit.invoices.askedNotifications"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: invoicesKey),
           let decoded = try? JSONDecoder().decode([Invoice].self, from: data) {
            invoices = decoded
        }
        examined = Set(defaults.stringArray(forKey: examinedKey) ?? [])
        dismissed = Set(defaults.stringArray(forKey: dismissedKey) ?? [])
    }

    // MARK: Counts

    var overdueCount: Int { invoices.filter { $0.status() == .overdue }.count }
    var dueSoonCount: Int { invoices.filter { $0.status() == .dueSoon }.count }

    func contains(_ id: String) -> Bool { invoices.contains { $0.id == id } }

    // MARK: Editing

    func update(_ invoice: Invoice) {
        guard let index = invoices.firstIndex(where: { $0.id == invoice.id }) else { return }
        invoices[index] = invoice
        save()
        schedule(invoice)
    }

    func setPaid(_ id: String, _ paid: Bool) {
        guard let index = invoices.firstIndex(where: { $0.id == id }) else { return }
        invoices[index].paid = paid
        invoices[index].paidOn = paid ? Date() : nil
        save()
        schedule(invoices[index])
    }

    /// Takes a file out of the invoices and stops Pagewrit from suggesting it again.
    func remove(_ id: String) {
        invoices.removeAll { $0.id == id }
        dismissed.insert(id)
        examined.insert(id)
        cancelReminders(for: id)
        save()
    }

    /// For a book the detector missed: the reader says it is an invoice.
    func addManually(hash: String, title: String, author: String?, url: URL, format: BookFormat) {
        guard !contains(hash) else { return }
        dismissed.remove(hash)
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                Self.leadingText(url: url, format: format)
            }.value
            var invoice = Self.parse(text: text, fallbackTitle: title, id: hash, strict: false)
                ?? Invoice(id: hash, vendor: author ?? title, currency: "", title: title)
            if invoice.vendor.isEmpty { invoice.vendor = author ?? title }
            invoices.append(invoice)
            examined.insert(hash)
            save()
            schedule(invoice)
        }
    }

    // MARK: Finding invoices

    private struct Candidate: Sendable {
        let id: String
        let title: String
        let url: URL
        let format: BookFormat
    }

    /// Looks inside books Pagewrit has not looked at yet. Quiet and slow on
    /// purpose; each file is read once, ever.
    func scan(books: [Book]) async {
        let candidates: [Candidate] = books.compactMap { book in
            guard [BookFormat.pdf, BookFormat.docx, BookFormat.text].contains(book.format),
                  book.sizeBytes < 12_000_000,
                  !examined.contains(book.contentHash),
                  !dismissed.contains(book.contentHash) else { return nil }
            return Candidate(id: book.contentHash, title: book.title, url: book.sourceURL, format: book.format)
        }
        guard !candidates.isEmpty else { return }

        for batch in stride(from: 0, to: candidates.count, by: 20).map({ Array(candidates[$0..<min($0 + 20, candidates.count)]) }) {
            let found: [(String, Invoice?)] = await Task.detached(priority: .utility) {
                batch.map { candidate in
                    let text = Self.leadingText(url: candidate.url, format: candidate.format)
                    return (candidate.id, Self.parse(text: text, fallbackTitle: candidate.title, id: candidate.id, strict: true))
                }
            }.value
            for (id, invoice) in found {
                examined.insert(id)
                if let invoice, !contains(id) {
                    invoices.append(invoice)
                    schedule(invoice)
                }
            }
            save()
        }
    }

    // MARK: Reading text

    /// The first few pages of a document, enough to recognise an invoice.
    nonisolated static func leadingText(url: URL, format: BookFormat) -> String {
        switch format {
        case .pdf:
            guard let doc = PDFDocument(url: url) else { return "" }
            var text = ""
            for index in 0..<min(doc.pageCount, 4) {
                text += (doc.page(at: index)?.string ?? "") + "\n"
            }
            return text
        case .docx, .text:
            let plain = TextDocumentLoader.load(url: url, format: format)?.plain ?? ""
            return String(plain.prefix(20_000))
        default:
            return ""
        }
    }

    // MARK: Parsing

    nonisolated private static let dueKeys = ["due date", "payment due", "date due", "due on", "pay by", "pay before", "due by", "due:"]
    nonisolated private static let issueKeys = ["invoice date", "date of issue", "issue date", "issued on", "issued", "date:"]
    nonisolated private static let amountKeys = ["amount due", "balance due", "total due", "amount payable", "grand total", "total amount", "total"]

    nonisolated static func parse(text: String, fallbackTitle: String, id: String, strict: Bool) -> Invoice? {
        let cleaned = text.replacingOccurrences(of: "\r", with: "\n")
        let lines = cleaned
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let head = String(cleaned.prefix(4000)).lowercased()

        let amount = findAmount(in: lines)
        let due = findDate(in: lines, keys: dueKeys, skipping: nil)
        let issued = findDate(in: lines, keys: issueKeys, skipping: "due")
        let number = findNumber(in: cleaned)

        if strict {
            // A book that mentions the word once is not an invoice: it has to
            // be short, say "invoice" near the top, and show money, a due date
            // or an invoice number, at least two of the four signals.
            guard head.contains("invoice"), cleaned.count < 80_000 else { return nil }
            let signals = [
                amount != nil,
                due != nil,
                number != nil,
                head.contains("bill to") || head.contains("amount due") || head.contains("balance due")
            ].filter { $0 }.count
            guard signals >= 2 else { return nil }
        }

        let vendor = lines.first { line in
            let lower = line.lowercased()
            return line.count > 2 && line.count < 60
                && !lower.contains("invoice") && !lower.contains("bill to")
                && !(line.first?.isNumber ?? true)
        } ?? fallbackTitle

        return Invoice(
            id: id, vendor: vendor, number: number, amount: amount?.value,
            currency: amount?.currency ?? "", issued: issued, due: due, title: fallbackTitle)
    }

    nonisolated private static let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    nonisolated private static func date(in text: String) -> Date? {
        guard let detector = dateDetector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let found = detector.firstMatch(in: text, options: [], range: range)?.date else { return nil }
        let year = Calendar.current.component(.year, from: found)
        return (2000...2100).contains(year) ? found : nil
    }

    nonisolated private static func findDate(in lines: [String], keys: [String], skipping: String?) -> Date? {
        for key in keys {
            for index in lines.indices {
                let line = lines[index]
                if let skipping, line.lowercased().contains(skipping) { continue }
                guard let range = line.range(of: key, options: .caseInsensitive) else { continue }
                let tail = String(line[range.upperBound...])
                if let found = date(in: tail) { return found }
                if index + 1 < lines.count, let found = date(in: lines[index + 1]) { return found }
            }
        }
        return nil
    }

    nonisolated private static func findNumber(in text: String) -> String? {
        let pattern = #"(?i)\binvoice\s*(?:number|no\.?|num\.?|#)?\s*[:#]?\s*([A-Z0-9][A-Z0-9\-/]{2,19})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
            let candidate = ns.substring(with: match.range(at: 1))
            if candidate.contains(where: { $0.isNumber }) { return candidate }
        }
        return nil
    }

    nonisolated private static func findAmount(in lines: [String]) -> (value: Double, currency: String)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"([$€£₦]|USD|NGN|EUR|GBP|CAD|AUD)?\s?(\d{1,3}(?:[, ]\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)"#) else { return nil }

        func amounts(in line: String) -> [(Double, String)] {
            let ns = line as NSString
            var out: [(Double, String)] = []
            for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let currency = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : ""
                let raw = ns.substring(with: match.range(at: 2))
                let hasDecimal = raw.contains(".")
                let hasGrouping = raw.contains(",") || raw.contains(" ")
                // Plain whole numbers (page counts, quantities) are not prices.
                guard !currency.isEmpty || hasDecimal || hasGrouping else { continue }
                let digits = raw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
                if let value = Double(digits) { out.append((value, currency)) }
            }
            return out
        }

        for key in amountKeys {
            var best: (Double, String)?
            for index in lines.indices {
                let lower = lines[index].lowercased()
                guard lower.contains(key), !(key == "total" && lower.contains("subtotal")) else { continue }
                var found = amounts(in: lines[index])
                if found.isEmpty, index + 1 < lines.count { found = amounts(in: lines[index + 1]) }
                if let top = found.max(by: { $0.0 < $1.0 }), top.0 > (best?.0 ?? 0) { best = top }
            }
            if let best { return (best.0, best.1) }
        }
        return nil
    }

    // MARK: Reminders

    /// Asks for permission the first time there is something to remind about.
    func requestNotificationsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: askedKey), invoices.contains(where: { !$0.paid && $0.due != nil }) else { return }
        defaults.set(true, forKey: askedKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func reminderIDs(for id: String) -> [String] { ["invoice-\(id)-eve", "invoice-\(id)-day"] }

    private func cancelReminders(for id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: reminderIDs(for: id))
    }

    /// One reminder the morning before, one on the day, at 9:00.
    private func schedule(_ invoice: Invoice) {
        cancelReminders(for: invoice.id)
        guard !invoice.paid, let due = invoice.due else { return }
        let cal = Calendar.current
        guard let dueMorning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: due),
              let eveMorning = cal.date(byAdding: .day, value: -1, to: dueMorning) else { return }

        let amount = invoice.amountText.map { " (\($0))" } ?? ""
        let center = UNUserNotificationCenter.current()

        func fire(_ date: Date, id: String, body: String) {
            guard date > Date() else { return }
            let content = UNMutableNotificationContent()
            content.title = invoice.vendor
            content.body = body
            content.sound = .default
            let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            center.add(UNNotificationRequest(
                identifier: id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
        fire(eveMorning, id: reminderIDs(for: invoice.id)[0], body: "An invoice\(amount) is due tomorrow.")
        fire(dueMorning, id: reminderIDs(for: invoice.id)[1], body: "An invoice\(amount) is due today.")
    }

    // MARK: Saving

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(invoices) { defaults.set(data, forKey: invoicesKey) }
        defaults.set(Array(examined), forKey: examinedKey)
        defaults.set(Array(dismissed), forKey: dismissedKey)
    }
}
