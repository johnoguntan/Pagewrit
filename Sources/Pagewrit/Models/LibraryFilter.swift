import Foundation

/// A combination of filters the library can apply together: format, status,
/// rating, tag and series. Codable so a combination can be saved as a list.
struct LibraryFilter: Codable, Equatable {
    var format: String?
    var status: String?
    var minRating: Int = 0
    var tag: String?
    var series: String?

    var isEmpty: Bool {
        format == nil && status == nil && minRating == 0 && tag == nil && series == nil
    }

    func matches(_ book: Book) -> Bool {
        if let format, book.formatRaw != format { return false }
        if let status, book.status.rawValue != status { return false }
        if minRating > 0, book.rating < minRating { return false }
        if let tag, !book.tags.contains(tag) { return false }
        if let series, book.seriesName != series { return false }
        return true
    }
}

/// A named filter combination, shown in the sidebar.
struct SavedList: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var filter: LibraryFilter
}
