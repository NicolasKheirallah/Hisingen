import SwiftUI

struct SpinningFanView: View {
    let isSpinning: Bool
    var size: CGFloat = 13
    var color: Color = .orange

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    private var shouldSpin: Bool { isSpinning && !reduceMotion }

    var body: some View {
        Image(systemName: "fan.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
            .rotationEffect(.degrees(angle))
            .onAppear { if shouldSpin { startSpinning() } }
            .onChange(of: shouldSpin) { _, spinning in
                if spinning {
                    startSpinning()
                } else {
                    // Snap to rest without re-animation: an animated reset
                    // from a multi-turn angle visibly spins the fan backwards.
                    var reset = Transaction()
                    reset.animation = nil
                    withTransaction(reset) { angle = 0 }
                }
            }
            .accessibilityHidden(true)
    }

    private func startSpinning() {
        withAnimation(Motion.spin) {
            angle = 360
        }
    }
}
