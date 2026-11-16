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
    var thickness: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = Self.fraction(level) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(HisingenTheme.hairline)
                if isCharging, let target, Self.fraction(target) > Self.fraction(level) {
                    Capsule()
                        .fill(HisingenTheme.accent.opacity(0.28))
                        .frame(width: Self.fraction(target) * width)
                }
                if level != nil {
                    Capsule()
                        .fill(HisingenTheme.accent)
                        .frame(width: max(fill, thickness))
                }
                if let target {
                    // 2.5 pt and taller than the rail, so the target reads as a mark, not a seam.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(HisingenTheme.ink)
                        .frame(width: 2.5, height: thickness + 10)
                        .offset(x: min(max(Self.fraction(target) * width - 1.25, 0), width - 2.5))
                }
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: thickness + 10)
        .animation(reduceMotion ? nil : Motion.telemetry, value: level)
        .animation(reduceMotion ? nil : Motion.telemetry, value: target)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Battery"))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let level else { return L10n.text("Unavailable") }
        let percent = String(format: "%.0f%%", locale: L10n.displayLocale, level)
        guard let target else { return percent }
        return L10n.format("%@, target %@", percent,
                           String(format: "%.0f%%", locale: L10n.displayLocale, target))
    }

    static func fraction(_ value: Double?) -> CGFloat {
        guard let value else { return 0 }
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
