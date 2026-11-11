import Foundation
import AppKit
import MetricKit

/// App identity, support contact and the privacy summary, in one place so
/// Settings, the Help menu and the docs can never disagree.
enum AppInfo {
    static let name = "Pagewrit"

    /// Where support requests are sent. Set this before release; while it is
    /// empty the "Contact support" buttons are hidden rather than pointing
    /// at nothing.
    static let supportEmail = "oguntankayode@gmail.com"

    /// The public privacy policy (hosted from the docs folder with GitHub Pages).
    static let privacyPolicyURL = URL(string: "https://johnoguntan.github.io/Pagewrit/privacy.html")!

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


// MARK: - Crash reports

/// Collects crash reports from macOS (MetricKit) when Pagewrit closes
/// unexpectedly, and on the next launch offers to email them to support.
/// Nothing leaves the Mac unless the person presses Send in their mail app;
/// the reports hold technical details only, never books, paths or notes.
final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReporter()

    private let fm = FileManager.default

    private var folder: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var sentFolder: URL { folder.appendingPathComponent("Sent", isDirectory: true) }

    func start() {
        MXMetricManager.shared.add(self)
        // Reports from a crash usually arrive soon after the next launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.offerToSendIfNeeded()
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashes = payloads.filter { !($0.crashDiagnostics ?? []).isEmpty }
        guard !crashes.isEmpty else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for payload in crashes {
            let name = "crash-\(Int(payload.timeStampEnd.timeIntervalSince1970)).json"
            try? payload.jsonRepresentation().write(to: folder.appendingPathComponent(name))
        }
        DispatchQueue.main.async { [weak self] in self?.offerToSendIfNeeded() }
    }

    var pendingReports: [URL] {
        ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    /// "Pagewrit quit unexpectedly last time": once per batch of reports.
    func offerToSendIfNeeded() {
        let reports = pendingReports
        guard !reports.isEmpty, AppInfo.hasSupportContact else { return }
        let alert = NSAlert()
        alert.messageText = "Pagewrit quit unexpectedly last time"
        alert.informativeText = "A short technical report can help fix it. It holds no books, file names or notes, and your mail app shows it to you before anything is sent."
        alert.addButton(withTitle: "Send Report\u{2026}")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            sendReports(reports)
        }
        markSent(reports)
    }

    /// Help \u{25B8} Report a Problem: any saved crash reports plus the basic
    /// version details, in a new email to support.
    func reportProblem() {
        sendReports(pendingReports)
    }

    private func sendReports(_ reports: [URL]) {
        let body = """
        What happened? (A sentence or two helps a lot.)


        \u{2014}
        \(AppInfo.diagnostics)
        Crash reports attached: \(reports.count)
        """
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [AppInfo.supportEmail]
            service.subject = "\(AppInfo.name) \(AppInfo.version) problem report"
            service.perform(withItems: [body] + reports)
        } else {
            AppInfo.contactSupport()
        }
    }

    private func markSent(_ reports: [URL]) {
        try? fm.createDirectory(at: sentFolder, withIntermediateDirectories: true)
        for url in reports {
            try? fm.moveItem(at: url, to: sentFolder.appendingPathComponent(url.lastPathComponent))
        }
    }
}
