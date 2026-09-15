import SwiftUI

struct InformationButton: View {
    let message: String
    /// What this button explains, so its accessible name is not the generic "Details". Nil keeps
    /// the generic name for the handful of standalone uses.
    var subject: String? = nil
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            // 24pt, not 16: this is the control a reader presses when a number is unfamiliar, so a
            // miss costs the explanation. `.secondary` rather than `.tertiary` because tertiary at
            // 10pt over a material is below AA, and this is an affordance, not decoration.
            Image(systemName: "info.circle")
                .hisType(.label, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(message)
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            Text(message)
                .hisType(.body)
                .foregroundStyle(HisingenTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
        // "Details" is generic, and 249 KV rows produce one of these: a VoiceOver reader heard the
        // same name 249 times and could not tell which row they were on. The row's own label is the
        // name; the explanation is the hint, and it is not read twice.
        .accessibilityLabel(subject.map { L10n.format("Details for %@", $0) } ?? L10n.text("Details"))
        .accessibilityHint(message)
    }
}
