import SwiftUI

/// A row that takes the reader somewhere else: another tab, a section of the car, a map.
///
/// It is drawn exactly like the disclosure rows beside it ("Charger Details", "Charging Details"):
/// the label on the left in medium body, a muted chevron on the right, no box. An outlined box is
/// kept for buttons that act (Charge Now, Pause, Save), so a reader can tell a command from a
/// place to go by its shape. A second line, when there is one, says what is there.
struct NavigationRow: View {
    let title: String
    var detail: String? = nil
    /// The spoken name when the visible title alone would repeat on the same screen. It must
    /// contain the title, so a reader of Voice Control can say what they see.
    var accessibilityName: String? = nil
    var destination: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .hisType(.body, weight: .medium)
                        .foregroundStyle(HisingenTheme.ink)
                    if let detail {
                        Text(detail)
                            .hisType(.label)
                            .foregroundStyle(HisingenTheme.inkMuted)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let destination {
                    ViewThatFits(in: .horizontal) {
                        Text(destination)
                            .hisType(.label)
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .hisType(.label, weight: .semibold)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName ?? title)
        .accessibilityValue(detail ?? "")
        .accessibilityHint(destination ?? "")
    }
}
