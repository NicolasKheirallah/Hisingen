import AppKit
import Foundation
import UniformTypeIdentifiers

/// The save-panel half every export shares: ask where, write the bytes atomically, report the
/// outcome. What a success or a failure looks like to the reader stays with the caller.
@MainActor
enum FileExport {
    /// Nothing is reported when the reader cancels the panel. `modal` blocks on the panel
    /// (`runModal`) for callers that need it; otherwise it is presented without blocking.
    static func save(_ data: Data, type: UTType, filename: String, modal: Bool = false,
                     completion: @escaping @MainActor (_ url: URL, _ error: (any Error)?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = filename
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ExportFileWriter.write(data, to: url)
                completion(url, nil)
            } catch {
                completion(url, error)
            }
        }
        if modal {
            finish(panel.runModal())
        } else {
            panel.begin { response in MainActor.assumeIsolated { finish(response) } }
        }
    }

    static func save(_ text: String, type: UTType, filename: String, modal: Bool = false,
                     completion: @escaping @MainActor (_ url: URL, _ error: (any Error)?) -> Void) {
        save(Data(text.utf8), type: type, filename: filename, modal: modal, completion: completion)
    }
}
