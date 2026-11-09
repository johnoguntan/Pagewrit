import Foundation
import AppKit

/// App identity, support contact and the privacy summary, in one place so
/// Settings, the Help menu and the docs can never disagree.
enum AppInfo {
    static let name = "Pagewrit"

    /// Where support requests are sent. Set this before release; while it is
    /// empty the "Contact support" buttons are hidden rather than pointing
    /// at nothing.
    static let supportEmail = "oguntankayode@gmail.com"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// Technical details only (no library contents, paths or file names).
    static var diagnostics: String {
        "\(name) \(version) (\(build))\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    static let privacySummary = """
    Your books stay on your Mac. Pagewrit reads only the folders you let it scan, and it never uploads your files, \
    library or reading history. There are no accounts, analytics or ads.

    Pagewrit goes online only when you ask it to: Fix Metadata sends the title you type to Open Library, and \
    Download Books sends your search to Project Gutenberg, the Internet Archive and Open Library. Those services \
    can see your IP address, as any website would.
    """

    static var hasSupportContact: Bool { !supportEmail.isEmpty }

    static var supportURL: URL? {
        guard hasSupportContact else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "\(name) \(version) support"),
            URLQueryItem(name: "body", value: "\n\n\u{2014}\nDiagnostic info (safe to leave in):\n\(diagnostics)")
        ]
        return components.url
    }

    static func contactSupport() {
        if let url = supportURL { NSWorkspace.shared.open(url) }
    }

    static func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }
}
