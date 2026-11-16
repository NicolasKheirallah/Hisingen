import SwiftUI

/// Reported charge on a straight scale. Missing readings leave the track empty.
struct EnergyLine: View {
    /// Reported state of charge, 0–100. `nil` draws the track only.
    let level: Double?
    /// The charge target, 0–100, drawn as an ink tick. `nil` draws no tick.
    var target: Double? = nil
    /// While charging, the stretch between `level` and `target` is drawn as a fainter segment:
    /// where the charge is heading, not where it is.
    var isCharging: Bool = false
    var isHistorical: Bool = false
    var thickness: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 3) {
            scale
                .frame(height: thickness + 10)
            if let target, target.isFinite {
                TargetCaptionLayout(fraction: Self.fraction(target)) {
                    Text(L10n.format("Target %d%%", Int(target.rounded())))
                        .hisType(.label)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                .accessibilityHidden(true)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .animation(reduceMotion ? nil : Motion.telemetry, value: level)
        .animation(reduceMotion ? nil : Motion.telemetry, value: target)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Battery"))
        .accessibilityValue(accessibilityValue)
    }

    private var scale: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = Self.fraction(level) * width
            VStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(HisingenTheme.hairline)
                    if isCharging, let target, Self.fraction(target) > Self.fraction(level) {
                        Rectangle()
                            .fill(HisingenTheme.liveSignal.opacity(0.28))
                            .frame(width: Self.fraction(target) * width)
                    }
                    if fill > 0 {
                        Rectangle()
                            .fill(isHistorical ? HisingenTheme.inkMuted
                                  : (isCharging ? HisingenTheme.liveSignal : HisingenTheme.accent))
                            .frame(width: fill)
                    }
                }
                .frame(height: thickness)
                .overlay(alignment: .leading) {
                    if let target {
                        let markerWidth: CGFloat = 2
                        Rectangle()
                            .fill(HisingenTheme.ink)
                            .frame(width: markerWidth, height: thickness + 6)
                            .offset(x: min(max(Self.fraction(target) * width - markerWidth / 2, 0),
                                           max(width - markerWidth, 0)))
                    }
                }
                .padding(.top, 3)

                Path { ticks in
                    for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                        let x = max(0.5, min(width - 0.5, fraction * width))
                        ticks.move(to: CGPoint(x: x, y: 0))
                        ticks.addLine(to: CGPoint(x: x, y: 3))
                    }
                }
                .stroke(HisingenTheme.inkMuted, lineWidth: 1)
                .frame(height: 3)
            }
        }
    }

    private var accessibilityValue: String {
        let percent = level.map { String(format: "%.0f%%", locale: L10n.displayLocale, $0) }
            ?? L10n.text("Unavailable")
        guard let target else { return percent }
        return L10n.format("%@, target %@", percent,
                           String(format: "%.0f%%", locale: L10n.displayLocale, target))
    }

    nonisolated static func fraction(_ value: Double?) -> CGFloat {
        guard let value, value.isFinite else { return 0 }
        return CGFloat(min(max(value, 0), 100) / 100)
    }
}

private struct TargetCaptionLayout: Layout {
    let fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let caption = subviews.first else { return .zero }
        let size = caption.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let caption = subviews.first else { return }
        let size = caption.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let ideal = bounds.width * fraction - size.width / 2
        let x = min(max(ideal, 0), max(bounds.width - size.width, 0))
        caption.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), anchor: .topLeading,
                      proposal: ProposedViewSize(size))
    }
}
