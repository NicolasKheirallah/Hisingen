import SwiftUI

struct InformationButton: View {
    let message: String
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(message)
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(HisingenTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
        .accessibilityLabel(L10n.text("Details"))
        .accessibilityHint(message)
    }
}
