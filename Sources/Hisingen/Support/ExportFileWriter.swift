import Foundation

/// The one place an export's bytes reach disk. `FileExport` calls it with the URL the save panel
/// returned; tests call it with a temporary URL, which is what keeps a test from writing into a
/// reader's folder.
enum ExportFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
