import SwiftUI

struct VehicleCommandButton: View {
    let title: String
    let symbol: String
    let command: RemoteCommand
    let gate: ControlsCommandGate
    var isPrimary = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    var body: some View {
        let button = Button {
            gate.send(command)
        } label: {
            VStack(spacing: 4) {
                Label {
                    Text(title)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .hisType(.body, weight: isPrimary ? .semibold : .regular)
                gate.sendingOverlay(command)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 40)
            .overlay(alignment: .bottom) {
                if isFocused {
                    PanelDatum(color: isPrimary ? HisingenTheme.canvas : HisingenTheme.focusIndicator)
                }
            }
        }
        Group {
            if isPrimary {
                button.buttonStyle(.hisProminent(HisingenTheme.ink))
            } else {
                button.buttonStyle(.hisSecondary)
            }
        }
        .controlSize(.small)
        .disabled(gate.isDisabled(command))
        .focused($isFocused)
        .accessibilityLabel(title)
        .accessibilityValue(gate.isSending(command) ? L10n.text("Sending…") : "")
    }
}

struct VehicleCommandRow: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, width: proposal.width)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat?) -> [CGRect] {
        guard let widest = subviews.map({ $0.sizeThatFits(.unspecified).width }).max() else { return [] }
        let count = CGFloat(subviews.count)
        let totalGap = (count - 1) * spacing
        let idealWidth = widest * count + totalGap
        let available = width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        let fitsInRow = available >= idealWidth
        let cellWidth = fitsInRow ? (available - totalGap) / count : available
        var origin = CGPoint.zero
        return subviews.map { subview in
            let height = subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
            let frame = CGRect(origin: origin, size: CGSize(width: cellWidth, height: height))
            origin = fitsInRow
                ? CGPoint(x: origin.x + cellWidth + spacing, y: 0)
                : CGPoint(x: 0, y: origin.y + height + spacing)
            return frame
        }
    }
}
