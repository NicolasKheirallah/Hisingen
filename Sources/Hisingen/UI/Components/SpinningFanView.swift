import SwiftUI

struct SpinningFanView: View {
    let isSpinning: Bool
    var size: CGFloat = 13
    var color: Color = HisingenTheme.semanticWarning

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ambientMotionAllowed) private var ambientMotionAllowed
    @State private var angle: Double = 0

    private var shouldSpin: Bool { isSpinning && !reduceMotion && ambientMotionAllowed }

    var body: some View {
        Image(systemName: "fan.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
            .rotationEffect(.degrees(angle))
            .task(id: shouldSpin) {
                guard shouldSpin else { return }
                while !Task.isCancelled {
                    withAnimation(.linear(duration: Motion.spinCycle)) {
                        angle += 360
                    }
                    try? await Task.sleep(for: .seconds(Motion.spinCycle))
                }
            }
            .accessibilityHidden(true)
    }
}
