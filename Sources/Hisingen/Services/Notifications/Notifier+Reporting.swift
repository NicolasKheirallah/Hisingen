import Foundation

/// The recurring report posts through the same notice path as every other informational banner,
/// so it respects mute, quiet hours and the notification permission the reader granted. A report is
/// not a command outcome, so it says so in its own copy rather than borrowing "Command sent".
extension Notifier: RecurringReportNotifying {
    func notifyReport(title: String, body: String) {
        notifyCommandNotice(title: title, body: body, subtitle: nil)
    }
}
