import SwiftUI

/// The close mark on a notice, banner or receipt. One size, weight and target everywhere, so a
/// reader meets the same control on every message the panel shows.
struct DismissButton: View {
    var label: String = L10n.text("Dismiss")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .hisType(.caption, weight: .semibold)
                .foregroundStyle(HisingenTheme.inkMuted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .help(label)
    }
}
