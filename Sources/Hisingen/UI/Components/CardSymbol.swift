import SwiftUI

/// The symbol on a Now control card, with the one motion its state earns.
///
/// - `spin`: the fan while climate runs.
/// - `breathe`: a slow opacity swell while a charge or an air-cleaning session is live.
/// - `still`: everything else.
///
/// Two motions apply to every card. A symbol that changes (lock to unlock) is replaced rather than
/// swapped, and while a command waits for the car the symbol pulses, so control latency stays
/// visible. Ambient motion stops under Reduce Motion and while the panel is hidden.
struct CardSymbol: View {
    enum Kind: Equatable { case still, spin, breathe }

    let name: String
    var kind: Kind = .still
    var waiting = false
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ambientMotionAllowed) private var ambientMotionAllowed
    @State private var dimmed = false

    private var breathing: Bool { kind == .breathe && !reduceMotion && ambientMotionAllowed }

    var body: some View {
        Group {
            if kind == .spin {
                SpinningFanView(isSpinning: true, size: 12, color: color)
            } else {
                Image(systemName: name)
                    .hisSymbolSize(12)
                    .foregroundStyle(color)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: waiting && !reduceMotion)
                    .opacity(dimmed ? 0.55 : 1)
                    .animation(breathing ? Motion.breath : nil, value: dimmed)
                    .task(id: breathing) { dimmed = breathing }
            }
        }
        .hisAnimation(Motion.stateChange, value: name)
        .accessibilityHidden(true)
    }
}

/// "18 min remaining", counted down from the car's own report and redrawn once a minute, on the
/// minute the count changes. Draws nothing once the count reaches zero.
struct CardCountdown: View {
    let minutes: Int
    let reportedAt: Date
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: reportedAt, by: 60)) { context in
            if let left = ClimateCountdown.minutesRemaining(reported: minutes, at: reportedAt, now: context.date) {
                Text(L10n.format("%d min remaining", left))
                    .hisType(.label)
                    .foregroundStyle(color)
                    .hisTelemetryValue(left, reduceMotion: reduceMotion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
