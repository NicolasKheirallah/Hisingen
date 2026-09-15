import SwiftUI

extension HeatingLevel {
    /// The ladder both heating controls step along: an explicit Off stop at the bottom, then three
    /// levels. `unspecified` is deliberately not on it — it means the vehicle has not reported,
    /// which is not a setting the reader can choose.
    static let steps: [HeatingLevel] = [.off, .level1, .level2, .level3]

    var isHeatingActive: Bool { self == .level1 || self == .level2 || self == .level3 }

    /// One step up or down the ladder, clamped at both ends rather than wrapping.
    static func stepping(from level: HeatingLevel, by delta: Int) -> HeatingLevel {
        guard let index = steps.firstIndex(of: level) else {
            // Nothing reported yet: stepping up turns it on, stepping down stays where it is.
            return delta > 0 ? .level1 : .unspecified
        }
        let next = index + delta
        guard steps.indices.contains(next) else { return level }
        return steps[next]
    }
}

private extension HeatingLevel {
    /// Spoken value for the heating controls, reusing the level names the climate controls
    /// already ship rather than inventing a second vocabulary for the same setting.
    var spokenLevel: String {
        switch self {
        case .unspecified: return L10n.text("Unavailable")
        case .off: return L10n.text("Off")
        case .level1: return L10n.text("Level 1")
        case .level2: return L10n.text("Level 2")
        case .level3: return L10n.text("Level 3")
        }
    }
}

/// One heating level control, shared by every heated surface in the car.
///
/// The seat and the steering wheel were two different interaction models for the same setting, both
/// presented through the same `.bordered` `.small` button so nothing told the reader which behaviour
/// they were about to get: the seat cycled one way (off → 1 → 2 → 3 → off) with no way to step down,
/// and the steering wheel jumped straight to level 3, destroying an existing level 1 or 2. The label
/// then collapsed all of it to ON/OFF while three levels were active.
///
/// This is one stepper for both. Down and up are separate controls, Off is a real stop on the ladder
/// rather than a by-product of cycling past the top, and the readout names the level instead of
/// reducing it to a boolean.
@MainActor
struct HeatingLevelControl: View {
    let title: String
    let symbol: String
    @Binding var level: HeatingLevel
    let onChange: @MainActor (HeatingLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .hisType(.caption, weight: .medium)
                .foregroundStyle(.secondary)

            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .hisType(.body)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                stepButton(symbol: "minus", label: L10n.text("Lower"), delta: -1)

                Text(level.spokenLevel)
                    .hisType(.caption, weight: .semibold)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .hisAnimation(Motion.stateChange, value: level)

                stepButton(symbol: "plus", label: L10n.text("Raise"), delta: 1)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        // One element, because it is one setting: a VoiceOver reader hears the surface and its
        // level, and adjusts it with the standard gesture rather than hunting three buttons.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(level.spokenLevel)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private var tint: Color {
        level.isHeatingActive ? .orange : .secondary
    }

    private func stepButton(symbol: String, label: String, delta: Int) -> some View {
        Button {
            step(delta)
        } label: {
            Image(systemName: symbol)
                .hisType(.micro, weight: .bold)
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .foregroundStyle(tint)
        .accessibilityLabel(label)
        .accessibilityHidden(true)
    }

    private func step(_ delta: Int) {
        let next = HeatingLevel.stepping(from: level, by: delta)
        guard next != level else { return }
        level = next
        onChange(next)
    }
}
