import SwiftUI

/// The energy line: Hisingen's signature since the 2026-11-16 redesign. One horizontal rule
/// whose filled length is the battery's reported state of charge. It appears at three scales:
/// the header mark, the Now rail, and the Log trace. It is the only element that carries the
/// signal colour without being something to press.
///
/// It draws nothing it was not told: with no level, the track is empty, not guessed.
struct EnergyLine: View {
    /// Reported state of charge, 0–100. `nil` draws the track only.
    let level: Double?
    /// The charge target, 0–100, drawn as an ink tick. `nil` draws no tick.
    var target: Double? = nil
    /// While charging, the stretch between `level` and `target` is drawn as a fainter segment:
    /// where the charge is heading, not where it is.
    var isCharging: Bool = false
    var isHistorical: Bool = false
    var thickness: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = Self.fraction(level) * width
            VStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(HisingenTheme.hairline)
                    if isCharging, let target, Self.fraction(target) > Self.fraction(level) {
                        Capsule()
                            .fill(HisingenTheme.accent.opacity(0.28))
                            .frame(width: Self.fraction(target) * width)
                    }
                    if fill > 0 {
                        Capsule()
                            .fill(isHistorical ? HisingenTheme.inkMuted : HisingenTheme.accent)
                            .frame(width: fill)
                    }
                }
                .frame(height: thickness)
                .overlay(alignment: .leading) {
                    if let target {
                        let markerWidth: CGFloat = 2
                        RoundedRectangle(cornerRadius: 1)
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
        .frame(height: thickness + 10)
        .animation(reduceMotion ? nil : Motion.telemetry, value: level)
        .animation(reduceMotion ? nil : Motion.telemetry, value: target)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Battery"))
        .accessibilityValue(accessibilityValue)
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

/// The header mark: the energy line at its smallest, filled to the active car's level. With no
/// car yet it is drawn full, as the wordmark's glyph rather than a reading.
struct EnergyLineMark: View {
    let level: Double?

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(HisingenTheme.hairline)
            Capsule()
                .fill(HisingenTheme.accent)
                .frame(width: max(4, 22 * EnergyLine.fraction(level ?? 100)))
        }
        .frame(width: 22, height: 4)
        .accessibilityHidden(true)
    }
}
